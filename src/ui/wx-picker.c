/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-picker.c - WxPicker implementation. Behaviour is specified in
 * wx-picker.h.
 *
 * Structure:
 *  - WxPickerItem: one row of the results list (a validated copy of the
 *    place, its key and its label).
 *  - Rows are built by a GtkSignalListItemFactory. The rows currently bound
 *    are tracked in a set so a change of the places list can update their
 *    "Added" marker in place.
 *  - A search request carries a weak reference to the picker and its own
 *    GCancellable; it is applied only while that cancellable is still the
 *    picker's current one.
 */
#include "wx-picker.h"

#include <string.h>

#include "wx-geo.h"
#include "wx-text.h"

/* ------------------------------------------------------------------------ */
/* Suggestions                                                              */
/* ------------------------------------------------------------------------ */

/* The first-run suggestions: name, latitude, longitude. Every one is in Florida, United States. */
static const struct {
  const char *name;
  double lat;
  double lon;
} suggestions[] = {
  { "Miami", 25.7743, -80.1937 },        { "Orlando", 28.5383, -81.3792 },
  { "Tampa", 27.9475, -82.4584 },        { "Jacksonville", 30.3322, -81.6557 },
  { "Key West", 24.5551, -81.7800 },
};

/* Documented in wx-picker.h. */
GPtrArray *
wx_suggested_places_new(void)
{
  GPtrArray *places = g_ptr_array_new_with_free_func((GDestroyNotify)wx_place_free);
  for (guint i = 0; i < G_N_ELEMENTS(suggestions); i++) {
    WxPlace *place = wx_place_new(suggestions[i].name, "Florida", "United States", "US",
                                  suggestions[i].lat, suggestions[i].lon, "America/New_York",
                                  NULL);
    /* The constants above are valid (the tests list all five); a NULL would only mean a bug. */
    if (place != NULL)
      g_ptr_array_add(places, place);
  }
  return places;
}

/* ------------------------------------------------------------------------ */
/* Item                                                                     */
/* ------------------------------------------------------------------------ */

#define WX_TYPE_PICKER_ITEM (wx_picker_item_get_type())
G_DECLARE_FINAL_TYPE(WxPickerItem, wx_picker_item, WX, PICKER_ITEM, GObject)

struct _WxPickerItem {
  GObject parent_instance;
  WxPlace *place; /* validated private copy */
  char *key;      /* wx_place_key(place) */
  char *label;    /* wx_place_label(place) */
};

/*
 * G_DEFINE_TYPE() below generates wx_picker_item_get_type() (registers the type once;
 * thread-safe, any thread) and the static instance/class trampolines
 * (wx_picker_item_class_intern_init() and the parent-class/private-offset bookkeeping), which
 * call wx_picker_item_class_init() and wx_picker_item_init(). They own nothing; the documented
 * functions that follow are the only hand-written parts of the type.
 */
G_DEFINE_TYPE(WxPickerItem, wx_picker_item, G_TYPE_OBJECT)

/**
 * wx_picker_item_finalize:
 * @object: (not nullable): the WxPickerItem being finalized; the GObject machinery passes an
 *   instance of this type.
 *
 * GObject finalize: frees the place, the key and the label of the item and chains up.
 *
 * Preconditions:
 *  - called once by GObject when the last reference is dropped (never called directly); the
 *    three fields are either NULL or owned by the item (item_new() sets all three).
 * Postconditions:
 *  - place, key and label are freed; the parent finalize has run.
 * Thread affinity: main thread only (items are created, referenced and dropped by the picker
 *   and by GTK list widgets on the main thread).
 * Ownership: @object is owned by GObject; the item owns its place, key and label.
 */
static void
wx_picker_item_finalize(GObject *object)
{
  WxPickerItem *self = WX_PICKER_ITEM(object);
  wx_place_free(self->place);
  g_free(self->key);
  g_free(self->label);
  G_OBJECT_CLASS(wx_picker_item_parent_class)->finalize(object);
}

/**
 * wx_picker_item_class_init:
 * @klass: (not nullable): the class structure being initialised, passed by GObject.
 *
 * GObject class initialiser: installs wx_picker_item_finalize().
 *
 * Preconditions:
 *  - called once by GObject during type registration (never called directly).
 * Postconditions:
 *  - the class' finalize vfunc is wx_picker_item_finalize().
 * Thread affinity: main thread only (runs once, when the type is first used).
 * Ownership: @klass is owned by the type system; nothing is allocated.
 */
static void
wx_picker_item_class_init(WxPickerItemClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_picker_item_finalize;
}

/**
 * wx_picker_item_init:
 * @self: (not nullable): the new instance, zero-initialised by GObject.
 *
 * GObject instance initialiser. Nothing to do: the fields stay NULL until item_new() fills them.
 *
 * Preconditions:
 *  - called once by GObject while the instance is created (never directly).
 * Postconditions:
 *  - @self is unchanged.
 * Thread affinity: main thread only (items are created by the picker).
 * Ownership: @self is owned by GObject; nothing is allocated.
 */
static void
wx_picker_item_init(WxPickerItem *self)
{
  (void)self;
}

/**
 * item_new:
 * @place: (transfer full) (not nullable): a place that passed wx_place_copy(); adopted.
 *
 * Creates one row item of the results list.
 *
 * Preconditions:
 *  - @place is a valid place (wx_place_new() rules) owned by the caller, which gives up its
 *    ownership; main thread.
 * Postconditions:
 *  - the item owns @place; its key is wx_place_key(@place) and its label wx_place_label(@place),
 *    both non-NULL.
 * Thread affinity: main thread only.
 * Ownership: @place is consumed; the caller owns the returned item.
 *
 * Returns: (transfer full): the new item; never NULL.
 */
static WxPickerItem *
item_new(WxPlace *place)
{
  WxPickerItem *item = g_object_new(WX_TYPE_PICKER_ITEM, NULL);
  item->place = place;
  item->key = wx_place_key(place);
  item->label = wx_place_label(place);
  return item;
}

/* ------------------------------------------------------------------------ */
/* Picker                                                                   */
/* ------------------------------------------------------------------------ */

struct _WxPicker {
  GtkWindow parent_instance;

  WxPlaces *places;   /* strong; NULL after dispose */
  gulong places_handler;
  WxService *service; /* strong; NULL after dispose */

  GListModel *toplevels; /* GTK's list of toplevel windows; strong */
  gulong toplevels_handler;
  gboolean destroyed; /* gtk_window_destroy() or dispose ran; the object may still be alive */

  GtkWidget *search_entry;
  GtkWidget *status;

  GListStore *results_store; /* WxPickerItem */
  GHashTable *bound_rows;    /* set of Row* currently bound to an item */

  guint debounce_id;
  GCancellable *search_cancellable; /* the in-flight request, or NULL */
  char *last_query;                 /* the query of the latest search started and not cancelled or
                                     * edited away since (see repeats_latest_search()), or NULL */
  gint64 answered_us;               /* monotonic time that search was answered (valid while
                                     * last_query is set and no request is in flight) */
};

/*
 * G_DEFINE_TYPE() below generates wx_picker_get_type() (registers the type once; thread-safe,
 * any thread) and the static instance/class trampolines that call wx_picker_class_init() and
 * wx_picker_init(). They own nothing; the documented functions that follow are the only
 * hand-written parts of the type.
 */
G_DEFINE_TYPE(WxPicker, wx_picker, GTK_TYPE_WINDOW)

enum { SIGNAL_PLACE_ADDED, N_SIGNALS };
static guint signals[N_SIGNALS];

/**
 * set_status:
 * @self: (not nullable): the picker; the status label must exist (the picker is constructed).
 * @message: (nullable): text for the status line; NULL or "" hides the line. Copied by GTK.
 * @is_error: whether the message is an error (CSS class "error" instead of "dim-label").
 *
 * Shows or hides the inline status line.
 *
 * Preconditions:
 *  - @self is a live WxPicker whose widgets exist (it is not yet finalized); @message is NULL
 *    or NUL-terminated; main thread.
 * Postconditions:
 *  - the label shows @message (or "" and is hidden); it has the CSS class "error" and not
 *    "dim-label" iff @is_error, else "dim-label" and not "error".
 * Thread affinity: main thread only.
 * Ownership: @self and @message are only read; nothing is retained.
 */
static void
set_status(WxPicker *self, const char *message, gboolean is_error)
{
  gboolean show = message != NULL && message[0] != '\0';
  gtk_label_set_text(GTK_LABEL(self->status), show ? message : "");
  gtk_widget_set_visible(self->status, show);
  if (is_error) {
    gtk_widget_add_css_class(self->status, "error");
    gtk_widget_remove_css_class(self->status, "dim-label");
  } else {
    gtk_widget_remove_css_class(self->status, "error");
    gtk_widget_add_css_class(self->status, "dim-label");
  }
}

/**
 * entry_query:
 * @self: (not nullable): the picker.
 *
 * Copies the text of the search entry as the query that is searched: the forbidden characters of
 * wx_sanitize_text() (control characters, line and paragraph separators, bidirectional
 * formatting marks such as the U+200F that text pasted from right-to-left pages carries) are
 * removed, then the surrounding ASCII whitespace (g_strstrip()). The geocoder refuses a text that
 * contains one of these characters, so the picker never passes it on.
 *
 * Preconditions:
 *  - @self is a live picker whose entry exists; main thread.
 * Postconditions:
 *  - no state is changed; the entry's own text is not modified.
 * Thread affinity: main thread only.
 * Ownership: @self is only read; the caller owns the returned string.
 *
 * Returns: (transfer full): the newly allocated query: valid UTF-8, at most
 *   WX_PICKER_MAX_QUERY_BYTES bytes while the entry holds at most that many (see
 *   on_insert_text()); never NULL (may be "").
 */
static char *
entry_query(WxPicker *self)
{
  const char *entry_text = gtk_editable_get_text(GTK_EDITABLE(self->search_entry));
  char *clean = wx_sanitize_text(entry_text, strlen(entry_text));
  return g_strstrip(clean);
}

/**
 * query_is_searchable:
 * @text: (not nullable): a query made by entry_query().
 *
 * Whether the search is started for @text: at least WX_PICKER_MIN_QUERY_BYTES bytes long and
 * accepted by wx_text_is_usable_name() with WX_PICKER_MAX_QUERY_BYTES, the rule of the
 * geocoder (so the search can only fail for a reason that is not about the text). After
 * entry_query() the only text of that length that the rule refuses is one made of white space
 * that is not ASCII (for example no-break spaces).
 *
 * Preconditions:
 *  - @text is NUL-terminated.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff a search for @text may start.
 */
static gboolean
query_is_searchable(const char *text)
{
  return strlen(text) >= WX_PICKER_MIN_QUERY_BYTES &&
         wx_text_is_usable_name(text, WX_PICKER_MAX_QUERY_BYTES);
}

/* ------------------------------------------------------------------------ */
/* Rows                                                                     */
/* ------------------------------------------------------------------------ */

/* Row: the widgets of one list row plus the item it shows. It is owned by the row's root box
 * (g_object_set_data_full() with row_free()), i.e. it lives exactly as long as that box. */
#define ROW_KEY "wx-picker-row"

typedef struct {
  WxPicker *picker;       /* raw: widgets are descendants of the picker; see factory_setup() */
  GHashTable *bound_rows; /* strong; the picker's set of bound rows, so row_free() can leave it */
  GtkWidget *label;
  GtkWidget *added;
  WxPickerItem *item;     /* strong while bound, else NULL */
  GtkListItem *list_item; /* raw; only while bound (between factory_bind() and factory_unbind()) */
} Row;

/**
 * row_free:
 * @data: (not nullable): the Row* stored on the row's root box.
 *
 * GDestroyNotify of the box's ROW_KEY data: runs when the box is finalized. If GTK called
 * factory_unbind() before the widget went away, that already removed the row from the set of
 * bound rows; if it did not, this removes the row from the set so that the picker never
 * iterates a freed Row. The set is kept alive by the reference the row holds, independent of the
 * picker's own lifetime.
 *
 * Preconditions:
 *  - @data is a Row created by factory_setup() and not yet freed; called once.
 * Postconditions:
 *  - the row is not in the set of bound rows, its item reference is dropped and it is freed.
 * Thread affinity: main thread only.
 * Ownership: @data is owned by this call (freed here).
 */
static void
row_free(gpointer data)
{
  Row *row = data;
  g_hash_table_remove(row->bound_rows, row);
  g_hash_table_unref(row->bound_rows);
  g_clear_object(&row->item);
  g_free(row);
}

/**
 * row_sync:
 * @row: (not nullable): a row created by factory_setup(), alive and bound.
 *
 * Makes the "Added" marker and the accessible description of a bound row show whether the
 * place is in the places list.
 *
 * Preconditions:
 *  - @row is a live Row that is bound (factory_bind() ran and factory_unbind() did not since:
 *    it holds its item and its list item; both callers, factory_bind() and on_places_changed()
 *    over the set of bound rows, guarantee it), whose picker is alive (not finalized) and holds
 *    its places list (the picker releases it only in dispose, after which no row is bound);
 *    main thread.
 * Postconditions:
 *  - the marker is visible iff wx_places_index_of() of the item's key is not negative, and the
 *    list item's accessible description is "Added" or "".
 * Thread affinity: main thread only.
 * Ownership: @row is only used; nothing is retained.
 */
static void
row_sync(Row *row)
{
  gboolean added = wx_places_index_of(row->picker->places, row->item->key) >= 0;
  gtk_widget_set_visible(row->added, added);
  gtk_list_item_set_accessible_description(row->list_item, added ? "Added" : "");
}

/**
 * factory_setup:
 * @factory: (not nullable): the list's GtkSignalListItemFactory (unused).
 * @list_item: (not nullable): the GtkListItem GTK created; receives the row's widgets.
 * @user_data: (not nullable): the WxPicker passed to g_signal_connect() in wx_picker_init().
 *
 * "setup" handler: builds the widgets of one row, creates its Row and stores it on the root
 * box; the list item takes the box as its child.
 *
 * Preconditions:
 *  - emitted on the main thread by GTK; @user_data is the picker. That raw pointer is safe
 *    because the factory is owned by the list view (gtk_list_view_new() takes it), the list view
 *    is a descendant of the picker, and the picker's dispose destroys its child widgets (and
 *    with them the list view) before it is finalized.
 *  - the picker's bound_rows exists (wx_picker_init() creates it before building the list).
 * Postconditions:
 *  - @list_item has a child box carrying the Row under ROW_KEY (freed by row_free() with the
 *    box); the row holds its own reference on the picker's set of bound rows.
 * Thread affinity: main thread only.
 * Ownership: @user_data is not referenced; the Row is owned by the box; @list_item owns the box.
 */
static void
factory_setup(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer user_data)
{
  (void)factory;
  Row *row = g_new0(Row, 1);
  row->picker = user_data;
  row->bound_rows = g_hash_table_ref(row->picker->bound_rows);

  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_margin_start(box, 6);
  gtk_widget_set_margin_end(box, 6);
  gtk_widget_set_margin_top(box, 6);
  gtk_widget_set_margin_bottom(box, 6);

  row->label = gtk_label_new(NULL);
  gtk_widget_set_name(row->label, "wx-picker-label");
  gtk_widget_add_css_class(row->label, "wx-picker-label");
  gtk_widget_set_hexpand(row->label, TRUE);
  gtk_label_set_xalign(GTK_LABEL(row->label), 0.0f);
  gtk_label_set_ellipsize(GTK_LABEL(row->label), PANGO_ELLIPSIZE_END);
  gtk_box_append(GTK_BOX(box), row->label);

  row->added = gtk_label_new("Added");
  gtk_widget_set_name(row->added, "wx-picker-added");
  gtk_widget_add_css_class(row->added, "wx-picker-added");
  gtk_widget_add_css_class(row->added, "dim-label");
  gtk_widget_set_visible(row->added, FALSE);
  gtk_box_append(GTK_BOX(box), row->added);

  g_object_set_data_full(G_OBJECT(box), ROW_KEY, row, row_free);
  gtk_list_item_set_child(list_item, box);
}

/**
 * list_item_row:
 * @list_item: (not nullable): a list item set up by factory_setup().
 *
 * Fetches the Row stored on the list item's child box.
 *
 * Preconditions:
 *  - @list_item is a live GtkListItem whose child is the box built by factory_setup(); main
 *    thread.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the Row stays owned by the box.
 *
 * Returns: (transfer none): the Row; never NULL.
 */
static Row *
list_item_row(GtkListItem *list_item)
{
  return g_object_get_data(G_OBJECT(gtk_list_item_get_child(list_item)), ROW_KEY);
}

/**
 * factory_bind:
 * @factory: (not nullable): the list's factory (unused).
 * @list_item: (not nullable): the list item being bound to an item of the model.
 * @user_data: (not nullable): the WxPicker passed in wx_picker_init().
 *
 * "bind" handler: fills the row's label from the item, sets the tooltip and the accessible label
 * of the row, adds the row to the set of bound rows and syncs the "Added" marker.
 *
 * Preconditions:
 *  - emitted on the main thread by GTK after factory_setup() for @list_item and with an item of
 *    the model, which is a WxPickerItem (the store holds only that type); @user_data is the
 *    picker (see factory_setup()).
 * Postconditions:
 *  - the row holds a reference on the item, shows its label (text, tooltip, accessible label of
 *    the list item) and is a member of bound_rows.
 * Thread affinity: main thread only.
 * Ownership: the row takes its own reference on the item; nothing else is retained.
 */
static void
factory_bind(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer user_data)
{
  (void)factory;
  WxPicker *self = user_data;
  Row *row = list_item_row(list_item);
  WxPickerItem *item = gtk_list_item_get_item(list_item);

  g_clear_object(&row->item);
  row->item = g_object_ref(item);
  row->list_item = list_item;
  gtk_label_set_text(GTK_LABEL(row->label), item->label);
  gtk_widget_set_tooltip_text(row->label, item->label);
  gtk_list_item_set_accessible_label(list_item, item->label);

  g_hash_table_add(self->bound_rows, row);
  row_sync(row);
}

/**
 * factory_unbind:
 * @factory: (not nullable): the list's factory (unused).
 * @list_item: (not nullable): the list item being unbound.
 * @user_data: (not nullable): the WxPicker passed in wx_picker_init().
 *
 * "unbind" handler: removes the row from the set of bound rows and drops its item reference.
 *
 * Preconditions:
 *  - emitted on the main thread by GTK for a list item that was set up and bound; @user_data is
 *    the picker, and the picker's bound_rows exists (it is freed only in finalize, after the list
 *    view has been disposed). If GTK skipped this call, row_free() performs the removal.
 * Postconditions:
 *  - the row is not in bound_rows, holds no item and no list item.
 * Thread affinity: main thread only.
 * Ownership: the item reference of the row is released; nothing else is retained.
 */
static void
factory_unbind(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer user_data)
{
  (void)factory;
  WxPicker *self = user_data;
  Row *row = list_item_row(list_item);
  g_hash_table_remove(self->bound_rows, row);
  row->list_item = NULL;
  g_clear_object(&row->item);
}

/**
 * on_places_changed:
 * @places: (not nullable): the places list that emitted "changed" (unused).
 * @user_data: (not nullable): the WxPicker given to g_signal_connect() in wx_picker_new().
 *
 * Handler of the places list's "changed" signal: brings the "Added" marker of all bound rows in
 * line with the list. It never changes the places list.
 *
 * Preconditions:
 *  - emitted on the main thread; @user_data is a live picker: the handler is disconnected in
 *    wx_picker_dispose() before the picker can be finalized.
 * Postconditions:
 *  - every row in bound_rows shows the current state (row_sync()).
 * Thread affinity: main thread only.
 * Ownership: @user_data is not referenced beyond the call (a temporary reference is held).
 */
static void
on_places_changed(WxPlaces *places, gpointer user_data)
{
  (void)places;
  WxPicker *self = user_data;
  /* Only this picker's own widgets react below, but the picker is held anyway so that nothing in
   * here can outlive it. */
  g_autoptr(WxPicker) hold = g_object_ref(self);
  GHashTableIter iter;
  gpointer key;
  g_hash_table_iter_init(&iter, self->bound_rows);
  while (g_hash_table_iter_next(&iter, &key, NULL))
    row_sync(key);
}

/* ------------------------------------------------------------------------ */
/* Adding                                                                   */
/* ------------------------------------------------------------------------ */

/**
 * refusal_message:
 * @self: (not nullable): the picker, not disposed.
 * @item: (not nullable): the item whose add was refused by wx_places_add().
 *
 * Works out why wx_places_add() refused @item from the places list as it is now (the refused
 * add did not change it).
 *
 * Preconditions:
 *  - @self holds its places list; @item is a live item; main thread.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the result is a static string literal owned by the program.
 *
 * Returns: (transfer none): "You can save up to 50 places" if the list holds WX_PLACE_MAX
 *   places, else "Already in your places" if its key is in the list or a place of the list is
 *   closer than WX_PLACES_DUPLICATE_KM, else "Could not add this place".
 */
static const char *
refusal_message(WxPicker *self, const WxPickerItem *item)
{
  guint n = wx_places_get_n_places(self->places);
  if (n >= WX_PLACE_MAX)
    return "You can save up to 50 places";
  gboolean duplicate = wx_places_index_of(self->places, item->key) >= 0;
  for (guint i = 0; i < n && !duplicate; i++) {
    const WxPlace *saved = wx_places_get_place(self->places, i);
    duplicate = wx_geo_distance_km(saved->lat, saved->lon, item->place->lat, item->place->lon) <
                WX_PLACES_DUPLICATE_KM;
  }
  if (duplicate)
    return "Already in your places";
  return "Could not add this place";
}

/**
 * add_item:
 * @self: (not nullable): the picker.
 * @item: (not nullable): the item the user activated.
 *
 * The one place where the user adds a place: adds @item's place to the places list; on success
 * emits "place-added" and closes the window, on refusal shows the reason.
 *
 * The places list runs foreign "changed" handlers inside the add, and the emission runs foreign
 * "place-added" handlers; any of them may destroy the picker. gtk_window_destroy() only drops
 * GTK's reference, so the picker and the item are held until this function returns, and the add
 * finishes on live objects. @self is not touched after the window was closed. A picker that
 * was destroyed before the add refuses it; one destroyed during the add keeps the add (the list
 * did change) but emits nothing and is not closed again, because a destroyed picker emits
 * nothing.
 *
 * Preconditions:
 *  - @self is a WxPicker and @item a WxPickerItem that are alive at the call; main thread.
 * Postconditions:
 *  - destroyed picker: nothing happens.
 *  - refused add: the status line shows the reason (class "error"); nothing is emitted.
 *  - successful add: the list holds the place, and unless the picker became destroyed
 *    meanwhile "place-added" was emitted with the key of the place and gtk_window_close() was
 *    called.
 * Thread affinity: main thread only.
 * Ownership: @self and @item are referenced for the duration of the call and released on return.
 */
static void
add_item(WxPicker *self, WxPickerItem *item)
{
  g_autoptr(WxPicker) hold = g_object_ref(self);
  g_autoptr(WxPickerItem) keep = g_object_ref(item);

  if (self->destroyed)
    return;
  if (!wx_places_add(self->places, item->place)) {
    set_status(self, refusal_message(self, item), TRUE);
    return;
  }
  if (self->destroyed)
    return;
  g_signal_emit(self, signals[SIGNAL_PLACE_ADDED], 0, item->key);
  if (!self->destroyed)
    gtk_window_close(GTK_WINDOW(self));
}

/**
 * on_list_activate:
 * @view: (not nullable): the list view whose row was activated.
 * @position: index of the activated row in the view's model.
 * @user_data: (not nullable): the WxPicker passed in wx_picker_init().
 *
 * "activate" handler (Enter / Space / double click): adds the activated place.
 *
 * Preconditions:
 *  - emitted on the main thread by GTK; @user_data is the picker (see factory_setup()); @view
 *    has a model.
 * Postconditions:
 *  - nothing happens if @position has no item; otherwise see add_item().
 * Thread affinity: main thread only.
 * Ownership: the item obtained from the model is referenced for the call and released.
 */
static void
on_list_activate(GtkListView *view, guint position, gpointer user_data)
{
  WxPicker *self = user_data;
  g_autoptr(WxPickerItem) item =
      g_list_model_get_item(G_LIST_MODEL(gtk_list_view_get_model(view)), position);
  if (item != NULL)
    add_item(self, item);
}

/* ------------------------------------------------------------------------ */
/* Search                                                                   */
/* ------------------------------------------------------------------------ */

typedef struct {
  GWeakRef picker;
  GCancellable *cancellable; /* identifies the request; strong */
} SearchRequest;

/**
 * cancel_search:
 * @self: (not nullable): the picker.
 *
 * Cancels the pending debounce timer and the in-flight request, and forgets the latest search
 * (a cancelled search is not a search that Enter must not repeat). Idempotent. The request stops
 * being the current one BEFORE it is cancelled, so a service that completes from inside the
 * cancellation finds it stale.
 *
 * Preconditions:
 *  - @self is a live picker; main thread.
 * Postconditions:
 *  - debounce_id is 0 and its source is removed; search_cancellable is NULL and the request
 *    that was current (if any) is cancelled; its SearchRequest is freed later by on_search_done();
 *    last_query is NULL.
 * Thread affinity: main thread only.
 * Ownership: the picker's reference on the cancellable is released; the request keeps its own.
 */
static void
cancel_search(WxPicker *self)
{
  g_clear_handle_id(&self->debounce_id, g_source_remove);
  g_clear_pointer(&self->last_query, g_free);
  g_autoptr(GCancellable) cancellable = g_steal_pointer(&self->search_cancellable);
  if (cancellable != NULL)
    g_cancellable_cancel(cancellable);
}

/**
 * fill_results:
 * @self: (not nullable): the picker.
 * @places: (not nullable) (element-type WxPlace): the places to list; not modified.
 *
 * Replaces the results list with copies of at most WX_GEOCODER_MAX_HITS of @places, in order.
 *
 * Preconditions:
 *  - @self is a live picker; every element of @places is a valid place (wx_place_new() rules;
 *    the service and wx_suggested_places_new() guarantee it); main thread.
 * Postconditions:
 *  - results_store holds one item per listed place; an element that does not pass
 *    wx_place_copy() would be skipped.
 * Thread affinity: main thread only.
 * Ownership: @places stays owned by the caller; the new items are owned by the store.
 *
 * Returns: the number of items now in the list.
 */
static guint
fill_results(WxPicker *self, const GPtrArray *places)
{
  g_autoptr(GPtrArray) items = g_ptr_array_new_with_free_func(g_object_unref);
  for (guint i = 0; i < places->len && items->len < WX_GEOCODER_MAX_HITS; i++) {
    WxPlace *copy = wx_place_copy(g_ptr_array_index(places, i));
    if (copy != NULL)
      g_ptr_array_add(items, item_new(copy));
  }
  g_list_store_splice(self->results_store, 0,
                      g_list_model_get_n_items(G_LIST_MODEL(self->results_store)), items->pdata,
                      items->len);
  return items->len;
}

/**
 * show_suggestions:
 * @self: (not nullable): the picker.
 *
 * Lists the first-run suggestions under the status text "Suggestions".
 *
 * Preconditions:
 *  - @self is a live picker; main thread.
 * Postconditions:
 *  - the results list holds wx_suggested_places_new() and the status line shows "Suggestions"
 *    (class "dim-label").
 * Thread affinity: main thread only.
 * Ownership: @self is only used.
 */
static void
show_suggestions(WxPicker *self)
{
  g_autoptr(GPtrArray) places = wx_suggested_places_new();
  fill_results(self, places);
  set_status(self, "Suggestions", FALSE);
}

/**
 * on_search_done:
 * @source: (not nullable): the WxService the search was started on.
 * @result: (not nullable): the GAsyncResult of the search.
 * @user_data: (transfer full): the SearchRequest created by start_search().
 *
 * GAsyncReadyCallback of wx_service_search_async(). Applies the outcome only if the request is
 * still the picker's current one; a cancelled or superseded request, or a vanished picker, is
 * silent. The picker is reached only through the request's GWeakRef, so a late completion never
 * touches a finalized picker. Comparing the request's cancellable with the picker's current one
 * is free of address reuse (ABA): the request holds a strong reference on its cancellable until
 * the end of this function, so no newer cancellable can have the same address.
 *
 * Preconditions:
 *  - called exactly once, on the main thread, by the service's GAsyncReadyCallback contract;
 *    @user_data is the SearchRequest that start_search() allocated for this call.
 * Postconditions:
 *  - the SearchRequest (weak reference, cancellable reference) is released and freed; the places
 *    and error returned by wx_service_search_finish() are released. If the request was current:
 *    the picker's search_cancellable is cleared; the search counts as answered now (answered_us),
 *    except a cancellation, which is not an answer and makes the picker forget the search;
 *    on success the places are listed ("No results" when there are none); on cancellation the
 *    status line is cleared; on any other error the results are cleared and "Search failed:
 *    <message>" is shown with the CSS class "error" (message through wx_sanitize_text(), cut to
 *    WX_PICKER_MAX_MESSAGE_BYTES).
 * Thread affinity: main thread only.
 * Ownership: @source and @result are borrowed; @user_data is owned by this function (freed).
 */
static void
on_search_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  SearchRequest *req = user_data;
  GError *error = NULL;
  GPtrArray *found = wx_service_search_finish(WX_SERVICE(source), result, &error);

  /* Only the latest request may change the UI. A request that is no longer the picker's current
   * one was cancelled or superseded (even if the geocoder delivered a result anyway), or the
   * picker is gone. */
  WxPicker *self = g_weak_ref_get(&req->picker);
  if (self != NULL && self->search_cancellable == req->cancellable) {
    g_clear_object(&self->search_cancellable);
    self->answered_us = g_get_monotonic_time();
    if (error == NULL) {
      guint n = fill_results(self, found);
      set_status(self, n > 0 ? NULL : "No results", FALSE);
    } else if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
      g_clear_pointer(&self->last_query, g_free); /* no answer: Enter may ask again at once */
      set_status(self, NULL, FALSE);
    } else {
      g_autofree char *text = wx_sanitize_text(error->message, WX_PICKER_MAX_MESSAGE_BYTES);
      g_autofree char *msg = g_strdup_printf("Search failed: %s", text);
      g_list_store_remove_all(self->results_store);
      set_status(self, msg, TRUE);
    }
  }

  g_clear_object(&self);
  g_clear_error(&error);
  g_clear_pointer(&found, g_ptr_array_unref);
  g_weak_ref_clear(&req->picker);
  g_object_unref(req->cancellable);
  g_free(req);
}

/**
 * start_search:
 * @self: (not nullable): the picker.
 * @text: (not nullable): the query (see entry_query()) that query_is_searchable() accepts.
 *
 * Starts the search for @text: a new request becomes the picker's current one, "Searching\u2026"
 * is shown and the service is called.
 *
 * Preconditions:
 *  - @self is a live, not destroyed picker that holds its service and has no pending timer and
 *    no request in flight (callers run cancel_search() first); @text is NUL-terminated; main
 *    thread.
 * Postconditions:
 *  - search_cancellable is the new request's cancellable; on_search_done() will run once for it;
 *    last_query is a copy of @text.
 * Thread affinity: main thread only.
 * Ownership: @text is copied by the service; the new SearchRequest is owned by the callback.
 */
static void
start_search(WxPicker *self, const char *text)
{
  SearchRequest *req = g_new0(SearchRequest, 1);
  g_weak_ref_init(&req->picker, self);
  self->search_cancellable = g_cancellable_new();
  g_free(self->last_query);
  self->last_query = g_strdup(text);
  req->cancellable = g_object_ref(self->search_cancellable);
  set_status(self, "Searching\xE2\x80\xA6", FALSE);
  wx_service_search_async(self->service, text, req->cancellable, on_search_done, req);
}

/**
 * on_debounce_fired:
 * @user_data: (not nullable): the WxPicker passed to g_timeout_add() in on_search_changed().
 *
 * Debounce timer callback: starts the search for the text of the entry.
 *
 * Preconditions:
 *  - runs on the main thread from the default main context; @user_data is a live picker that
 *    is not destroyed: the source is armed only by on_search_changed() for a query that
 *    query_is_searchable() accepts, and cancel_search() (called by every edit, by
 *    on_toplevels_changed() and by wx_picker_dispose()) removes it, so it can neither fire
 *    after destruction nor outlive the picker. The text cannot have changed since the timer
 *    was armed, because an edit re-arms it. No request is in flight, because arming the timer
 *    cancelled any.
 * Postconditions:
 *  - debounce_id is 0 and see start_search().
 * Thread affinity: main thread only.
 * Ownership: @user_data is not referenced.
 *
 * Returns: G_SOURCE_REMOVE always (the timer is one-shot).
 */
static gboolean
on_debounce_fired(gpointer user_data)
{
  WxPicker *self = user_data;
  self->debounce_id = 0;
  g_autofree char *text = entry_query(self);
  start_search(self, text);
  return G_SOURCE_REMOVE;
}

/**
 * on_insert_text:
 * @editable: (not nullable): the text widget inside the search entry (the GtkEditable that
 *   emits "insert-text").
 * @text: (not nullable): the text that is about to be inserted: valid UTF-8 and NUL-terminated
 *   (GTK passes the signal argument as a string); only its first @length bytes count.
 * @length: its length in bytes, or -1 for "up to the NUL".
 * @position: (inout): the character position of the insertion.
 * @user_data: unused (NULL).
 *
 * Keeps the entry within WX_PICKER_MAX_QUERY_BYTES bytes (the geocoder refuses a longer query,
 * and counts bytes, while the entry's own limit counts characters): an insertion that would
 * make the text longer is cut to the largest prefix that fits and ends on a character boundary
 * (nothing is inserted when no character fits), and inserted instead.
 *
 * Preconditions:
 *  - emitted on the main thread by the entry's GtkText before its class handler; @text is a
 *    NUL-terminated string of at least @length bytes (@length >= 0) holding valid UTF-8.
 * Postconditions:
 *  - the text of the entry is at most WX_PICKER_MAX_QUERY_BYTES bytes after the insertion;
 *    an insertion that fits is untouched.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed.
 */
static void
on_insert_text(GtkEditable *editable, const char *text, int length, int *position,
               gpointer user_data)
{
  (void)user_data;
  gsize new_bytes = length < 0 ? strlen(text) : (gsize)length;
  gsize have = strlen(gtk_editable_get_text(editable));
  if (have <= WX_PICKER_MAX_QUERY_BYTES && new_bytes <= WX_PICKER_MAX_QUERY_BYTES - have)
    return;
  g_signal_stop_emission_by_name(editable, "insert-text");
  gsize keep = have < WX_PICKER_MAX_QUERY_BYTES ? WX_PICKER_MAX_QUERY_BYTES - have : 0;
  /* keep < new_bytes here, so text[keep] is inside the inserted text */
  while (keep > 0 && (((guchar)text[keep]) & 0xC0) == 0x80)
    keep--;
  if (keep > 0)
    gtk_editable_insert_text(editable, text, (int)keep, position);
}

/**
 * on_search_changed:
 * @widget: (not nullable): the search entry (unused).
 * @user_data: (not nullable): the WxPicker passed to g_signal_connect() in wx_picker_init().
 *
 * "changed" handler of the entry: cancels the pending/in-flight search and forgets the latest
 * one, then, depending on the query (see entry_query()), shows the suggestions (empty), asks for
 * more letters (too short, or white space that is not ASCII only) or restarts the debounce timer.
 *
 * Preconditions:
 *  - emitted on the main thread by the picker's own entry; @user_data is the picker.
 * Postconditions:
 *  - a destroyed picker ignores the edit; otherwise the previous search is cancelled and either
 *    the suggestions are listed (empty query), the results are cleared with the status text
 *    "Type at least 2 letters" (the query is shorter than WX_PICKER_MIN_QUERY_BYTES bytes, or
 *    query_is_searchable() refuses it: it is made of white space that is not ASCII only, for
 *    example no-break spaces), or debounce_id is a new timer of WX_PICKER_SEARCH_DELAY_MS.
 * Thread affinity: main thread only.
 * Ownership: @user_data is not referenced (the timer holds it raw; see on_debounce_fired()).
 */
static void
on_search_changed(GtkWidget *widget, gpointer user_data)
{
  (void)widget;
  WxPicker *self = user_data;
  if (self->destroyed)
    return;

  cancel_search(self);
  g_autofree char *text = entry_query(self);
  if (text[0] == '\0') {
    show_suggestions(self);
  } else if (!query_is_searchable(text)) {
    g_autofree char *msg = g_strdup_printf("Type at least %d letters", WX_PICKER_MIN_QUERY_BYTES);
    g_list_store_remove_all(self->results_store);
    set_status(self, msg, FALSE);
  } else {
    self->debounce_id = g_timeout_add(WX_PICKER_SEARCH_DELAY_MS, on_debounce_fired, self);
  }
}

/**
 * repeats_latest_search:
 * @self: (not nullable): the picker.
 * @text: (not nullable): a query that query_is_searchable() accepts.
 *
 * Whether a search for @text would only repeat the latest one: it is for the same query, and that
 * search is still in flight or was answered (with results or with an error) less than
 * WX_PICKER_SEARCH_DELAY_MS ago. Enter uses it so that a held-down key (auto-repeat) does not turn
 * into one geocoder operation per key event.
 *
 * Preconditions:
 *  - @self is a live picker; @text is NUL-terminated; main thread.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff last_query is set, equals @text, and the search is in flight or was answered
 *   less than WX_PICKER_SEARCH_DELAY_MS ago.
 */
static gboolean
repeats_latest_search(const WxPicker *self, const char *text)
{
  if (self->last_query == NULL || strcmp(self->last_query, text) != 0)
    return FALSE;
  return self->search_cancellable != NULL ||
         g_get_monotonic_time() - self->answered_us < (gint64)WX_PICKER_SEARCH_DELAY_MS * 1000;
}

/**
 * on_search_activate:
 * @widget: (not nullable): the search entry (unused).
 * @user_data: (not nullable): the WxPicker passed to g_signal_connect() in wx_picker_init().
 *
 * "activate" handler of the entry (Enter): searches at once, without waiting for the debounce
 * timer, unless that would only repeat the latest search (see repeats_latest_search()).
 *
 * Preconditions:
 *  - emitted on the main thread by the picker's own entry; @user_data is the picker.
 * Postconditions:
 *  - a destroyed picker, a query that is not searchable (see query_is_searchable(); the state
 *    already shows what the last edit made of it) and a query that repeats the latest search (see
 *    repeats_latest_search()) ignore the key and change nothing; otherwise the timer and the
 *    request in flight (none, when the query is not that of the latest search) are cancelled and a
 *    new search for the query starts.
 * Thread affinity: main thread only.
 * Ownership: @user_data is not referenced.
 */
static void
on_search_activate(GtkWidget *widget, gpointer user_data)
{
  (void)widget;
  WxPicker *self = user_data;
  g_autofree char *text = entry_query(self);
  if (self->destroyed || !query_is_searchable(text) || repeats_latest_search(self, text))
    return;
  cancel_search(self);
  start_search(self, text);
}

/* ------------------------------------------------------------------------ */
/* Window                                                                   */
/* ------------------------------------------------------------------------ */

/**
 * on_key_pressed:
 * @controller: (not nullable): the picker's key controller (unused).
 * @keyval: the key pressed.
 * @keycode: the hardware keycode (unused).
 * @state: the modifier state.
 * @user_data: (not nullable): the WxPicker (a GtkWindow) passed in wx_picker_init().
 *
 * Capture-phase key handler of the window: Escape without modifiers closes the window.
 *
 * Preconditions:
 *  - emitted on the main thread by a controller attached to the picker itself, so @user_data
 *    outlives it.
 * Postconditions:
 *  - Escape (no modifier of the default mask): gtk_window_close() was called and the event is
 *    stopped; any other key: nothing, the event propagates.
 * Thread affinity: main thread only.
 * Ownership: @user_data is not referenced.
 *
 * Returns: GDK_EVENT_STOP for a plain Escape, GDK_EVENT_PROPAGATE otherwise.
 */
static gboolean
on_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode,
               GdkModifierType state, gpointer user_data)
{
  (void)controller;
  (void)keycode;
  if (keyval != GDK_KEY_Escape || (state & gtk_accelerator_get_default_mod_mask()) != 0)
    return GDK_EVENT_PROPAGATE;
  gtk_window_close(GTK_WINDOW(user_data));
  return GDK_EVENT_STOP;
}

/**
 * on_toplevels_changed:
 * @toplevels: (not nullable): GTK's list of toplevel windows.
 * @position: index of the change (unused).
 * @removed: number of removed windows.
 * @added: number of added windows (unused).
 * @user_data: (not nullable): the WxPicker passed in wx_picker_init().
 *
 * gtk_window_destroy() removes the window from GTK's list of toplevels but, while anybody else
 * holds a reference, does not dispose it. That removal is how the picker learns that it is gone
 * for good: from then on it cancels its search, issues no new one, adds nothing and emits
 * nothing. (Closing alone is not destruction: a close request may be vetoed, or only hide the
 * window.)
 *
 * Preconditions:
 *  - emitted on the main thread; @user_data is a live picker: the handler is disconnected in
 *    wx_picker_dispose() before the picker can be finalized.
 * Postconditions:
 *  - ignored unless something was removed and the picker is no longer in the list; then
 *    destroyed is TRUE, the search is cancelled and the status line cleared.
 * Thread affinity: main thread only.
 * Ownership: @toplevels is only read; items fetched from it are released.
 */
static void
on_toplevels_changed(GListModel *toplevels, guint position, guint removed, guint added,
                     gpointer user_data)
{
  (void)position;
  (void)added;
  WxPicker *self = user_data;
  if (removed == 0 || self->destroyed)
    return;
  for (guint i = 0, n = g_list_model_get_n_items(toplevels); i < n; i++) {
    g_autoptr(GObject) window = g_list_model_get_item(toplevels, i);
    if (window == G_OBJECT(self))
      return;
  }
  self->destroyed = TRUE;
  cancel_search(self);
  set_status(self, NULL, FALSE); /* no "Searching..." without a request */
}

/**
 * wx_picker_dispose:
 * @object: (not nullable): the WxPicker being disposed.
 *
 * GObject dispose (may run more than once): marks the picker destroyed, cancels the search and
 * the timer, disconnects the handlers on GTK's toplevel list and on the places list, then
 * chains up (which disposes the child widgets, whose factory calls factory_unbind() while
 * bound_rows is still alive) and finally releases the references on the places list and the
 * service. Nothing a row or a handler uses is released before the child widgets are gone.
 *
 * Preconditions:
 *  - called by GObject (never directly), on the main thread.
 * Postconditions:
 *  - no timer, request or handler remains, destroyed is TRUE; the picker holds no reference on
 *    the toplevel list, the places list or the service; a repeated call does nothing more.
 * Thread affinity: main thread only.
 * Ownership: @object is owned by GObject; the picker's references are released.
 */
static void
wx_picker_dispose(GObject *object)
{
  WxPicker *self = WX_PICKER(object);
  self->destroyed = TRUE;
  cancel_search(self);
  if (self->toplevels_handler != 0) {
    g_signal_handler_disconnect(self->toplevels, self->toplevels_handler);
    self->toplevels_handler = 0;
  }
  g_clear_object(&self->toplevels);
  if (self->places_handler != 0) {
    g_signal_handler_disconnect(self->places, self->places_handler);
    self->places_handler = 0;
  }
  G_OBJECT_CLASS(wx_picker_parent_class)->dispose(object);
  g_clear_object(&self->places);
  g_clear_object(&self->service);
}

/**
 * wx_picker_finalize:
 * @object: (not nullable): the WxPicker being finalized.
 *
 * GObject finalize: frees the set of bound rows and the results store, then chains up. Rows
 * that outlive the set (see row_free()) keep their own reference on it.
 *
 * Preconditions:
 *  - called once by GObject after dispose (never directly), on the main thread.
 * Postconditions:
 *  - the picker's own memory-owning fields are released.
 * Thread affinity: main thread only.
 * Ownership: @object is owned by GObject; the picker's references are released.
 */
static void
wx_picker_finalize(GObject *object)
{
  WxPicker *self = WX_PICKER(object);
  g_clear_pointer(&self->bound_rows, g_hash_table_unref);
  g_clear_object(&self->results_store);
  G_OBJECT_CLASS(wx_picker_parent_class)->finalize(object);
}

/**
 * wx_picker_class_init:
 * @klass: (not nullable): the class structure being initialised, passed by GObject.
 *
 * GObject class initialiser: installs dispose/finalize and registers the "place-added" signal.
 *
 * Preconditions:
 *  - called once by GObject during type registration (never called directly).
 * Postconditions:
 *  - the class vfuncs are set and signals[SIGNAL_PLACE_ADDED] is the signal id.
 * Thread affinity: main thread only (runs once, when the type is first used).
 * Ownership: @klass is owned by the type system; nothing is allocated except the signal.
 */
static void
wx_picker_class_init(WxPickerClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS(klass);
  object_class->dispose = wx_picker_dispose;
  object_class->finalize = wx_picker_finalize;

  signals[SIGNAL_PLACE_ADDED] =
      g_signal_new("place-added", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                   NULL, G_TYPE_NONE, 1, G_TYPE_STRING);
}

/**
 * make_list:
 * @self: (not nullable): the picker; used as the raw user_data of the handlers (it is the
 *   ancestor of the list view, see factory_setup()).
 * @scrolled_out: (out) (not nullable): receives the scrolled window that wraps the view.
 *
 * Builds the results list view with its factory, selection and scrolled window.
 *
 * Preconditions:
 *  - called from wx_picker_init() on the main thread; @self->bound_rows and
 *    @self->results_store already exist (the factory callbacks use the first, the selection
 *    model wraps the second).
 * Postconditions:
 *  - *@scrolled_out is a new floating widget containing the view; the factory (owned by the view)
 *    and selection model are owned by the view.
 * Thread affinity: main thread only.
 * Ownership: the store is referenced, not consumed; the caller owns the (floating) scrolled
 *   window and the returned view is a descendant of it.
 *
 * Returns: (transfer none): the list view (owned by the scrolled window).
 */
static GtkWidget *
make_list(WxPicker *self, GtkWidget **scrolled_out)
{
  GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
  g_signal_connect(factory, "setup", G_CALLBACK(factory_setup), self);
  g_signal_connect(factory, "bind", G_CALLBACK(factory_bind), self);
  g_signal_connect(factory, "unbind", G_CALLBACK(factory_unbind), self);
  GtkNoSelection *selection = gtk_no_selection_new(g_object_ref(G_LIST_MODEL(self->results_store)));
  GtkWidget *view = gtk_list_view_new(GTK_SELECTION_MODEL(selection), factory);
  gtk_widget_set_name(view, "wx-picker-results");
  /* Tab visits one row and then leaves the list; the arrow keys move between rows. */
  gtk_list_view_set_tab_behavior(GTK_LIST_VIEW(view), GTK_LIST_TAB_ITEM);
  g_signal_connect(view, "activate", G_CALLBACK(on_list_activate), self);

  GtkWidget *scrolled = gtk_scrolled_window_new();
  gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scrolled), 120);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), view);
  gtk_widget_set_vexpand(scrolled, TRUE);
  *scrolled_out = scrolled;
  return view;
}

/**
 * wx_picker_init:
 * @self: (not nullable): the new instance, zero-initialised by GObject.
 *
 * GObject instance initialiser: creates the row set and the store, then builds all widgets and
 * connects their handlers and gives the entry the keyboard focus. The raw
 * @self given to the handlers is safe: the widgets are descendants of @self and are disposed
 * with it; the toplevel-list handler is disconnected in dispose.
 *
 * Preconditions:
 *  - called once by GObject while the instance is created (never directly); GTK is initialised
 *    with a display; main thread.
 * Postconditions:
 *  - bound_rows, the store, all widgets, the key controller and the toplevel-list handler exist;
 *    the list is empty; places and service are still NULL (wx_picker_new() sets them and lists
 *    the suggestions, because list rows are bound, and need the places list, as soon as the
 *    list has items).
 * Thread affinity: main thread only.
 * Ownership: @self is owned by GObject; the widgets are owned by the window, the store,
 *   bound_rows and the toplevel-list reference by the picker.
 */
static void
wx_picker_init(WxPicker *self)
{
  self->bound_rows = g_hash_table_new(g_direct_hash, g_direct_equal);
  self->results_store = g_list_store_new(WX_TYPE_PICKER_ITEM);

  gtk_window_set_title(GTK_WINDOW(self), "Add a city");
  gtk_window_set_default_size(GTK_WINDOW(self), 460, 520);
  gtk_widget_add_css_class(GTK_WIDGET(self), "wx-picker");

  GtkEventController *keys = gtk_event_controller_key_new();
  gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
  g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key_pressed), self);
  gtk_widget_add_controller(GTK_WIDGET(self), keys);

  GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_set_margin_start(root, 12);
  gtk_widget_set_margin_end(root, 12);
  gtk_widget_set_margin_top(root, 12);
  gtk_widget_set_margin_bottom(root, 12);
  gtk_window_set_child(GTK_WINDOW(self), root);

  self->search_entry = gtk_entry_new();
  gtk_widget_set_name(self->search_entry, "wx-picker-search-entry");
  gtk_entry_set_max_length(GTK_ENTRY(self->search_entry), WX_PICKER_MAX_QUERY_CHARS);
  g_signal_connect(gtk_editable_get_delegate(GTK_EDITABLE(self->search_entry)), "insert-text",
                   G_CALLBACK(on_insert_text), NULL);
  gtk_entry_set_activates_default(GTK_ENTRY(self->search_entry), FALSE);
  gtk_entry_set_placeholder_text(GTK_ENTRY(self->search_entry), "Search for a city");
  gtk_accessible_update_property(GTK_ACCESSIBLE(self->search_entry),
                                 GTK_ACCESSIBLE_PROPERTY_LABEL, "Search for a city", -1);
  g_signal_connect(self->search_entry, "changed", G_CALLBACK(on_search_changed), self);
  g_signal_connect(self->search_entry, "activate", G_CALLBACK(on_search_activate), self);
  gtk_box_append(GTK_BOX(root), self->search_entry);

  self->status = gtk_label_new(NULL);
  gtk_widget_set_name(self->status, "wx-picker-status");
  gtk_label_set_xalign(GTK_LABEL(self->status), 0.0f);
  gtk_label_set_wrap(GTK_LABEL(self->status), TRUE);
  gtk_label_set_wrap_mode(GTK_LABEL(self->status), PANGO_WRAP_WORD_CHAR);
  gtk_label_set_max_width_chars(GTK_LABEL(self->status), 50);
  gtk_box_append(GTK_BOX(root), self->status);

  GtkWidget *scrolled = NULL;
  make_list(self, &scrolled);
  gtk_box_append(GTK_BOX(root), scrolled);

  gtk_window_set_focus(GTK_WINDOW(self), self->search_entry);

  self->toplevels = g_object_ref(gtk_window_get_toplevels());
  self->toplevels_handler =
      g_signal_connect(self->toplevels, "items-changed", G_CALLBACK(on_toplevels_changed), self);
}

/* Documented in wx-picker.h. */
GtkWidget *
wx_picker_new(WxPlaces *places, WxService *service)
{
  g_return_val_if_fail(WX_IS_PLACES(places), NULL);
  g_return_val_if_fail(WX_IS_SERVICE(service), NULL);

  WxPicker *self = g_object_new(WX_TYPE_PICKER, NULL);
  self->places = g_object_ref(places);
  self->service = g_object_ref(service);
  self->places_handler = g_signal_connect(places, "changed", G_CALLBACK(on_places_changed), self);
  /* Rows are bound as soon as the list has items, so this needs the places list. */
  show_suggestions(self);
  return GTK_WIDGET(self);
}
