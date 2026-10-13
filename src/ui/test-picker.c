/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * test-picker.c - WxPicker under a display with a controllable fake WxGeocoder behind a real
 * WxService and a real WxRegistry (plus the TEST-ONLY WxFakeGeocoder for a few end-to-end
 * cases).
 *
 * Needs a GDK display (run under xvfb-run); exits 77 (meson: skipped) when GTK cannot
 * initialise. Nothing touches the network or the disk: the fake geocoder completes searches only
 * when the test says so (success, failure or cancellation) and the places list is never saved
 * (its path lies in the harness' temp root and is asserted to stay absent).
 *
 * Determinism: the tests pump the main loop until a condition holds (mapped rows, a fired timer)
 * with a generous deadline instead of sleeping a fixed time; the only fixed waits are the ones
 * that prove that something does NOT happen or that wait out the delay of the picker
 * (WX_PICKER_SEARCH_DELAY_MS), and the timing assertions are lower bounds (the debounce never
 * fires early). The Enter tests that assert "too soon after an answer" measure that interval on
 * the monotonic clock and are skipped, never failed, when the host was too slow to press within
 * it. No test depends on the window being the active X window or on X
 * keyboard focus, which under Xvfb without a window manager belongs to whichever test window
 * happens to be topmost: keyboard focus is driven programmatically.
 *
 * Accessibility: the harness selects GTK_A11Y=none, under which accessible properties are
 * write-only. This test selects GTK_A11Y=test (GTK's in-process test backend) right after
 * wxt_setup(), before GTK is initialised, so that the accessible labels can be asserted with
 * gtk_test_accessible_check_property().
 */
#include "test-support.h"

#include <math.h>

#include "wx-fake-provider.h"
#include "wx-geo.h"
#include "wx-openmeteo.h"
#include "wx-picker.h"
#include "wx-registry.h"
#include "wx-service.h"
#include "wx-text.h"

/* ------------------------------------------------------------------ */
/* Fake geocoder                                                      */
/* ------------------------------------------------------------------ */

typedef struct {
  char *text;
  GCancellable *cancellable;
  GTask *task; /* NULL once completed */
} Pending;

#define FAKE_TYPE_GEOCODER (fake_geocoder_get_type())
G_DECLARE_FINAL_TYPE(FakeGeocoder, fake_geocoder, FAKE, GEOCODER, GObject)

struct _FakeGeocoder {
  GObject parent_instance;
  GPtrArray *searches; /* Pending* */
  gboolean ignore_cancel;
};

static void fake_geocoder_iface_init(WxGeocoderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(FakeGeocoder, fake_geocoder, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_GEOCODER, fake_geocoder_iface_init))

static void
pending_free(gpointer data)
{
  Pending *p = data;
  g_free(p->text);
  g_clear_object(&p->cancellable);
  g_clear_object(&p->task);
  g_free(p);
}

static void
fake_geocoder_finalize(GObject *object)
{
  g_ptr_array_unref(FAKE_GEOCODER(object)->searches);
  G_OBJECT_CLASS(fake_geocoder_parent_class)->finalize(object);
}

static void
fake_geocoder_class_init(FakeGeocoderClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = fake_geocoder_finalize;
}

static void
fake_geocoder_init(FakeGeocoder *self)
{
  self->searches = g_ptr_array_new_with_free_func(pending_free);
}

static void
fake_search_async(WxGeocoder *geocoder, const char *text, GCancellable *cancellable,
                  GAsyncReadyCallback callback, gpointer user_data)
{
  FakeGeocoder *self = FAKE_GEOCODER(geocoder);
  Pending *p = g_new0(Pending, 1);
  p->text = g_strdup(text);
  p->cancellable = cancellable != NULL ? g_object_ref(cancellable) : NULL;
  p->task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_check_cancellable(p->task, !self->ignore_cancel);
  g_ptr_array_add(self->searches, p);
}

static GPtrArray *
fake_search_finish(WxGeocoder *geocoder, GAsyncResult *result, GError **error)
{
  (void)geocoder;
  return g_task_propagate_pointer(G_TASK(result), error);
}

static void
fake_geocoder_iface_init(WxGeocoderInterface *iface)
{
  iface->search_async = fake_search_async;
  iface->search_finish = fake_search_finish;
}

static guint
fake_n(FakeGeocoder *f)
{
  return f->searches->len;
}

static Pending *
fake_pending(FakeGeocoder *f, guint i)
{
  g_assert_cmpuint(i, <, f->searches->len);
  return g_ptr_array_index(f->searches, i);
}

static void
fake_complete(FakeGeocoder *f, guint i, GPtrArray *places)
{
  Pending *p = fake_pending(f, i);
  g_assert_nonnull(p->task);
  GTask *task = g_steal_pointer(&p->task);
  g_task_return_pointer(task, places, places != NULL ? (GDestroyNotify)g_ptr_array_unref : NULL);
  g_object_unref(task);
}

static void
fake_fail(FakeGeocoder *f, guint i, GError *error)
{
  Pending *p = fake_pending(f, i);
  g_assert_nonnull(p->task);
  GTask *task = g_steal_pointer(&p->task);
  g_task_return_error(task, error);
  g_object_unref(task);
}

static void
fake_fail_cancelled(FakeGeocoder *f, guint i)
{
  fake_fail(f, i, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "cancelled"));
}

static gboolean
fake_is_cancelled(FakeGeocoder *f, guint i)
{
  return g_cancellable_is_cancelled(fake_pending(f, i)->cancellable);
}

/* ------------------------------------------------------------------ */
/* Places helpers                                                     */
/* ------------------------------------------------------------------ */

static WxPlace *
mk_place(const char *name, const char *admin1, const char *country, double lat, double lon)
{
  GError *error = NULL;
  WxPlace *p = wx_place_new(name, admin1, country, "US", lat, lon, "America/New_York", &error);
  g_assert_no_error(error);
  g_assert_nonnull(p);
  return p;
}

static GPtrArray *
places_new(void)
{
  return g_ptr_array_new_with_free_func((GDestroyNotify)wx_place_free);
}

/* "Springfield 0, Illinois, United States", at distinct spots far from each other (and from the
 * suggestions), for @n up to 99. */
static GPtrArray *
sample_places(guint n)
{
  GPtrArray *a = places_new();
  for (guint i = 0; i < n; i++) {
    g_autofree char *name = g_strdup_printf("Springfield %u", i);
    g_ptr_array_add(a, mk_place(name, "Illinois", "United States", 40.0 + (i / 10) * 2.0,
                                -100.0 + (i % 10) * 2.0));
  }
  return a;
}

static GPtrArray *
sample_hits(void)
{
  GPtrArray *a = places_new();
  g_ptr_array_add(a, mk_place("Miami", "Florida", "United States", 25.7743, -80.1937));
  g_ptr_array_add(a, mk_place("Miami", "Oklahoma", "United States", 36.8748, -94.8775));
  g_ptr_array_add(a, mk_place("Miami Beach", "Florida", "United States", 25.7907, -80.1300));
  return a;
}

/* ------------------------------------------------------------------ */
/* Widget helpers                                                     */
/* ------------------------------------------------------------------ */

static GtkWidget *
find(GtkWidget *picker, const char *name)
{
  GtkWidget *w = wxt_find_named(picker, name);
  g_assert_nonnull(w);
  return w;
}

static GtkEditable *
entry_of(GtkWidget *picker)
{
  return GTK_EDITABLE(find(picker, "wx-picker-search-entry"));
}

/* Makes the entry show @text the way typing does: when one text extends the other only the
 * difference is inserted or deleted. gtk_editable_set_text() would pass through the empty text,
 * which the picker (rightly) answers with the suggestions. */
static void
set_text(GtkWidget *picker, const char *text)
{
  GtkEditable *e = entry_of(picker);
  const char *cur = gtk_editable_get_text(e);
  if (cur[0] != '\0' && g_str_has_prefix(text, cur)) {
    int pos = (int)g_utf8_strlen(cur, -1);
    gtk_editable_insert_text(e, text + strlen(cur), -1, &pos);
  } else if (text[0] != '\0' && g_str_has_prefix(cur, text)) {
    gtk_editable_delete_text(e, (int)g_utf8_strlen(text, -1), -1);
  } else {
    gtk_editable_set_text(e, text);
  }
}

static const char *
status_text(GtkWidget *picker)
{
  return wxt_label_text(picker, "wx-picker-status");
}

static gboolean
status_visible(GtkWidget *picker)
{
  return gtk_widget_get_visible(find(picker, "wx-picker-status"));
}

static gboolean
status_is_error(GtkWidget *picker)
{
  return gtk_widget_has_css_class(find(picker, "wx-picker-status"), "error");
}

static gboolean
status_is_dim(GtkWidget *picker)
{
  return gtk_widget_has_css_class(find(picker, "wx-picker-status"), "dim-label");
}

static guint
list_n_items(GtkWidget *picker)
{
  GtkWidget *list = find(picker, "wx-picker-results");
  g_assert_true(GTK_IS_LIST_VIEW(list));
  return g_list_model_get_n_items(G_LIST_MODEL(gtk_list_view_get_model(GTK_LIST_VIEW(list))));
}

/* Mapped row labels. */
static GPtrArray *
mapped_labels(GtkWidget *picker)
{
  GPtrArray *labels = g_ptr_array_new();
  GtkWidget *list = find(picker, "wx-picker-results");
  g_autoptr(GPtrArray) all = g_ptr_array_new();
  wxt_collect_named(list, "wx-picker-label", all);
  for (guint i = 0; i < all->len; i++)
    if (gtk_widget_get_mapped(g_ptr_array_index(all, i)))
      g_ptr_array_add(labels, g_ptr_array_index(all, i));
  return labels;
}

static guint
n_mapped_labels(GtkWidget *picker)
{
  g_autoptr(GPtrArray) labels = mapped_labels(picker);
  return labels->len;
}

static GtkWidget *picker_for_sort; /* the list used by the sort below */

static int
compare_by_y(gconstpointer a, gconstpointer b)
{
  graphene_rect_t ra, rb;
  g_assert_true(gtk_widget_compute_bounds(*(GtkWidget *const *)a, picker_for_sort, &ra));
  g_assert_true(gtk_widget_compute_bounds(*(GtkWidget *const *)b, picker_for_sort, &rb));
  return ra.origin.y < rb.origin.y ? -1 : ra.origin.y > rb.origin.y ? 1 : 0;
}

/* The texts of the mapped row labels from top to bottom, as a NULL-terminated vector; free with
 * g_strfreev(). */
static char **
visible_labels(GtkWidget *picker)
{
  g_autoptr(GPtrArray) labels = mapped_labels(picker);
  picker_for_sort = find(picker, "wx-picker-results");
  g_ptr_array_sort(labels, compare_by_y);
  GStrvBuilder *b = g_strv_builder_new();
  for (guint i = 0; i < labels->len; i++)
    g_strv_builder_add(b, gtk_label_get_text(GTK_LABEL(g_ptr_array_index(labels, i))));
  char **v = g_strv_builder_end(b);
  g_strv_builder_unref(b);
  return v;
}

/* TRUE iff exactly the first @n of @places are shown, in order, with exactly their labels. */
static gboolean
rows_match(GtkWidget *picker, const GPtrArray *places, guint n)
{
  if (list_n_items(picker) != n)
    return FALSE;
  g_auto(GStrv) v = visible_labels(picker);
  if (g_strv_length(v) != n)
    return FALSE;
  for (guint i = 0; i < n; i++) {
    g_autofree char *label = wx_place_label(g_ptr_array_index(places, i));
    if (strcmp(v[i], label) != 0)
      return FALSE;
  }
  return TRUE;
}

/* The mapped label widget whose text is @text, or NULL. */
static GtkWidget *
find_label(GtkWidget *picker, const char *text)
{
  g_autoptr(GPtrArray) labels = mapped_labels(picker);
  for (guint i = 0; i < labels->len; i++)
    if (strcmp(gtk_label_get_text(GTK_LABEL(g_ptr_array_index(labels, i))), text) == 0)
      return g_ptr_array_index(labels, i);
  return NULL;
}

/* The "Added" marker next to the label widget @label. */
static GtkWidget *
marker_of(GtkWidget *label)
{
  GtkWidget *marker = gtk_widget_get_next_sibling(label);
  g_assert_nonnull(marker);
  g_assert_cmpstr(gtk_widget_get_name(marker), ==, "wx-picker-added");
  return marker;
}

/* The widget of the list row that holds @label (the list item widget). */
static GtkWidget *
row_widget_of(GtkWidget *label)
{
  return gtk_widget_get_parent(gtk_widget_get_parent(label));
}

static void
activate_row(GtkWidget *picker, guint position)
{
  g_signal_emit_by_name(find(picker, "wx-picker-results"), "activate", position);
}

/* TRUE iff the keyboard focus of @picker is @name or a descendant of it. */
static gboolean
focus_within(GtkWidget *picker, const char *name)
{
  for (GtkWidget *w = gtk_window_get_focus(GTK_WINDOW(picker)); w != NULL;
       w = gtk_widget_get_parent(w))
    if (strcmp(gtk_widget_get_name(w), name) == 0)
      return TRUE;
  return FALSE;
}

/* Asserts that the accessible @property of @w equals @expected (GTK_A11Y=test backend). */
static void
assert_a11y_label(GtkWidget *w, const char *expected)
{
  g_autofree char *problem =
      gtk_test_accessible_check_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                         expected);
  g_assert_null(problem);
}

static void
assert_a11y_description(GtkWidget *w, const char *expected)
{
  g_autofree char *problem = gtk_test_accessible_check_property(
      GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, expected);
  g_assert_null(problem);
}

/* Emits "key-pressed" on the picker's capture-phase key controller(s); returns whether one of them
 * handled it. */
static gboolean
press_key(GtkWidget *picker, guint keyval, GdkModifierType state)
{
  gboolean handled = FALSE;
  GListModel *controllers = gtk_widget_observe_controllers(picker);
  for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
    g_autoptr(GObject) c = g_list_model_get_item(controllers, i);
    if (GTK_IS_EVENT_CONTROLLER_KEY(c) &&
        gtk_event_controller_get_propagation_phase(GTK_EVENT_CONTROLLER(c)) == GTK_PHASE_CAPTURE) {
      gboolean ret = FALSE;
      g_signal_emit_by_name(c, "key-pressed", keyval, 0u, state, &ret);
      handled = handled || ret;
    }
  }
  g_object_unref(controllers);
  return handled;
}

/* ------------------------------------------------------------------ */
/* Fixture                                                            */
/* ------------------------------------------------------------------ */

typedef enum { PRESENT_NONE, PRESENT_TALL, PRESENT_SMALL } Present;

typedef struct {
  WxPlaces *places;
  WxRegistry *registry;
  WxService *service;
  FakeGeocoder *fake;
  GtkWidget *picker; /* NULL once destroyed and finalized */
  char *places_path;
  GPtrArray *added_keys;      /* every "place-added" key, in order */
  guint close_requests;       /* "close-request" emissions */
  guint closes_before_signal; /* close requests seen before the first "place-added" */
  gboolean visible_at_signal; /* the picker was visible while "place-added" ran */
} Fx;

static void
on_place_added(WxPicker *picker, const char *key, gpointer user_data)
{
  Fx *fx = user_data;
  if (fx->added_keys->len == 0)
    fx->closes_before_signal = fx->close_requests;
  fx->visible_at_signal = gtk_widget_get_visible(GTK_WIDGET(picker));
  g_ptr_array_add(fx->added_keys, g_strdup(key));
}

static gboolean
on_close_request(GtkWindow *window, gpointer user_data)
{
  (void)window;
  ((Fx *)user_data)->close_requests++;
  return FALSE;
}

/* Builds places + registry (fake geocoder) + service + picker and optionally presents it. */
static void
fx_init(Fx *fx, Present present)
{
  memset(fx, 0, sizeof *fx);
  fx->places_path = g_build_filename(wxt_root, "places-test.json", NULL);
  fx->places = wx_places_new(fx->places_path);
  fx->registry = wx_registry_new();
  fx->fake = g_object_new(FAKE_TYPE_GEOCODER, NULL);
  wx_registry_set_geocoder(fx->registry, WX_GEOCODER(fx->fake));
  fx->service = wx_service_new(fx->registry);
  fx->added_keys = g_ptr_array_new_with_free_func(g_free);
  fx->picker = wx_picker_new(fx->places, fx->service);
  g_assert_true(WX_IS_PICKER(fx->picker));
  g_object_add_weak_pointer(G_OBJECT(fx->picker), (gpointer *)&fx->picker);
  g_signal_connect(fx->picker, "place-added", G_CALLBACK(on_place_added), fx);
  g_signal_connect(fx->picker, "close-request", G_CALLBACK(on_close_request), fx);
  if (present != PRESENT_NONE) {
    if (present == PRESENT_TALL)
      gtk_window_set_default_size(GTK_WINDOW(fx->picker), 460, 1600);
    else if (present == PRESENT_SMALL)
      gtk_window_set_default_size(GTK_WINDOW(fx->picker), 460, 220);
    gtk_window_present(GTK_WINDOW(fx->picker));
    GtkWidget *list = find(fx->picker, "wx-picker-results");
    WXT_WAIT_FOR(gtk_widget_get_width(list) > 0 && gtk_widget_get_mapped(list));
  }
}

/* Destroys the picker (if still alive) and waits until it is finalized, which also proves that no
 * request or timer keeps it alive; then releases the rest. Unfinished fake searches are failed
 * with G_IO_ERROR_CANCELLED. The places file must never have been written. */
static void
fx_clear(Fx *fx)
{
  if (fx->picker != NULL) {
    gtk_window_destroy(GTK_WINDOW(fx->picker));
    WXT_WAIT_FOR(fx->picker == NULL);
  }
  for (guint i = 0; i < fx->fake->searches->len; i++)
    if (fake_pending(fx->fake, i)->task != NULL)
      fake_fail_cancelled(fx->fake, i);
  wxt_pump_idle();
  g_assert_false(g_file_test(fx->places_path, G_FILE_TEST_EXISTS));
  g_object_unref(fx->fake);
  g_object_unref(fx->service);
  g_object_unref(fx->registry);
  g_object_unref(fx->places);
  g_ptr_array_unref(fx->added_keys);
  g_free(fx->places_path);
}

/* Types @text and waits for the one request it produces; returns its index. */
static guint
search_for(Fx *fx, const char *text)
{
  guint before = fake_n(fx->fake);
  set_text(fx->picker, text);
  WXT_WAIT_FOR(fake_n(fx->fake) == before + 1);
  return before;
}

/* Types @text, answers with @hits and waits until exactly the first @n are listed. */
static void
show_results(Fx *fx, const char *text, GPtrArray *hits, guint n)
{
  guint i = search_for(fx, text);
  fake_complete(fx->fake, i, g_ptr_array_ref(hits));
  WXT_WAIT_FOR(rows_match(fx->picker, hits, n));
  g_ptr_array_unref(hits);
}

/* ------------------------------------------------------------------ */
/* Construction                                                       */
/* ------------------------------------------------------------------ */

static void
test_bad_arguments(void)
{
  g_autoptr(WxPlaces) places = wx_places_new("/nonexistent-dir/wx-test-places.json");
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(WxService) service = wx_service_new(registry);

  g_test_expect_message("weather", G_LOG_LEVEL_CRITICAL, "*WX_IS_PLACES*");
  g_assert_null(wx_picker_new(NULL, service));
  g_test_expect_message("weather", G_LOG_LEVEL_CRITICAL, "*WX_IS_SERVICE*");
  g_assert_null(wx_picker_new(places, NULL));
  /* wrong types: a service where the places list belongs and the other way round */
  g_test_expect_message("weather", G_LOG_LEVEL_CRITICAL, "*WX_IS_PLACES*");
  g_assert_null(wx_picker_new((WxPlaces *)service, service));
  g_test_expect_message("weather", G_LOG_LEVEL_CRITICAL, "*WX_IS_SERVICE*");
  g_assert_null(wx_picker_new(places, (WxService *)places));
  g_test_assert_expected_messages();
}

static void
test_construct_references(void)
{
  /* the picker takes its own references: the caller may drop its own at once */
  WxPlaces *places = wx_places_new("/nonexistent-dir/wx-test-places.json");
  WxRegistry *registry = wx_registry_new();
  WxService *service = wx_service_new(registry);
  g_object_add_weak_pointer(G_OBJECT(places), (gpointer *)&places);
  g_object_add_weak_pointer(G_OBJECT(service), (gpointer *)&service);
  GtkWidget *picker = wx_picker_new(places, service);
  g_object_add_weak_pointer(G_OBJECT(picker), (gpointer *)&picker);
  g_object_unref(registry);
  g_object_unref(places);
  g_object_unref(service);
  g_assert_nonnull(places);
  g_assert_nonnull(service);
  gtk_window_destroy(GTK_WINDOW(picker));
  WXT_WAIT_FOR(picker == NULL && places == NULL && service == NULL);
}

static void
test_initial_state(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_NONE);
  GtkWidget *p = fx.picker;

  g_assert_cmpstr(gtk_window_get_title(GTK_WINDOW(p)), ==, "Add a city");
  int w = 0, h = 0;
  gtk_window_get_default_size(GTK_WINDOW(p), &w, &h);
  g_assert_cmpint(w, ==, 460);
  g_assert_cmpint(h, ==, 520);
  g_assert_true(gtk_widget_has_css_class(p, "wx-picker"));
  g_assert_cmpstr(gtk_widget_get_css_name(p), ==, "window");
  g_assert_true(focus_within(p, "wx-picker-search-entry")); /* before it is ever shown */
  g_assert_false(gtk_window_get_modal(GTK_WINDOW(p)));
  g_assert_false(gtk_widget_get_visible(p));
  g_assert_null(gtk_window_get_transient_for(GTK_WINDOW(p)));

  GtkWidget *entry = find(p, "wx-picker-search-entry");
  g_assert_true(GTK_IS_ENTRY(entry));
  g_assert_false(GTK_IS_SEARCH_ENTRY(entry));
  g_assert_cmpstr(gtk_editable_get_text(GTK_EDITABLE(entry)), ==, "");
  g_assert_cmpstr(gtk_entry_get_placeholder_text(GTK_ENTRY(entry)), ==, "Search for a city");
  g_assert_cmpint(gtk_entry_get_max_length(GTK_ENTRY(entry)), ==, WX_PICKER_MAX_QUERY_CHARS);
  g_assert_false(gtk_entry_get_activates_default(GTK_ENTRY(entry)));
  assert_a11y_label(entry, "Search for a city");

  GtkWidget *list = find(p, "wx-picker-results");
  g_assert_true(GTK_IS_LIST_VIEW(list));
  g_assert_true(GTK_IS_NO_SELECTION(gtk_list_view_get_model(GTK_LIST_VIEW(list))));
  g_assert_true(GTK_IS_SCROLLED_WINDOW(gtk_widget_get_parent(list)));

  /* the suggestions with their status text, nothing searched */
  g_assert_cmpuint(list_n_items(p), ==, 5);
  g_assert_true(status_visible(p));
  g_assert_cmpstr(status_text(p), ==, "Suggestions");
  g_assert_true(status_is_dim(p));
  g_assert_false(status_is_error(p));
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  fx_clear(&fx);
}

static void
test_initial_focus(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  WXT_WAIT_FOR(focus_within(fx.picker, "wx-picker-search-entry"));
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  fx_clear(&fx);
}

static void
test_constants(void)
{
  /* the documented values of the header */
  g_assert_cmpint(WX_PICKER_SEARCH_DELAY_MS, ==, 300);
  g_assert_cmpint(WX_PICKER_MAX_QUERY_CHARS, ==, 64);
  g_assert_cmpint(WX_PICKER_MIN_QUERY_BYTES, ==, 2);
  g_assert_cmpint(WX_PICKER_MAX_MESSAGE_BYTES, ==, 200);
}

/* ------------------------------------------------------------------ */
/* Suggestions                                                        */
/* ------------------------------------------------------------------ */

static void
test_suggested_places(void)
{
  static const struct {
    const char *name, *key, *label;
    double lat, lon;
  } expect[] = {
    { "Miami", "25.7743,-80.1937", "Miami, Florida, United States", 25.7743, -80.1937 },
    { "Orlando", "28.5383,-81.3792", "Orlando, Florida, United States", 28.5383, -81.3792 },
    { "Tampa", "27.9475,-82.4584", "Tampa, Florida, United States", 27.9475, -82.4584 },
    { "Jacksonville", "30.3322,-81.6557", "Jacksonville, Florida, United States", 30.3322,
      -81.6557 },
    { "Key West", "24.5551,-81.7800", "Key West, Florida, United States", 24.5551, -81.7800 },
  };
  g_autoptr(GPtrArray) a = wx_suggested_places_new();
  g_assert_nonnull(a);
  g_assert_cmpuint(a->len, ==, G_N_ELEMENTS(expect));
  for (guint i = 0; i < a->len; i++) {
    const WxPlace *p = g_ptr_array_index(a, i);
    g_assert_nonnull(p);
    g_assert_cmpstr(p->name, ==, expect[i].name);
    g_assert_cmpstr(p->admin1, ==, "Florida");
    g_assert_cmpstr(p->country, ==, "United States");
    g_assert_cmpstr(p->country_code, ==, "US");
    g_assert_cmpstr(p->timezone, ==, "America/New_York");
    g_assert_cmpfloat(p->lat, ==, expect[i].lat);
    g_assert_cmpfloat(p->lon, ==, expect[i].lon);
    g_autofree char *key = wx_place_key(p);
    g_assert_cmpstr(key, ==, expect[i].key);
    g_autofree char *label = wx_place_label(p);
    g_assert_cmpstr(label, ==, expect[i].label);
    /* valid: a copy passes the validation of wx_place_new() */
    WxPlace *copy = wx_place_copy(p);
    g_assert_nonnull(copy);
    wx_place_free(copy);
  }

  /* every call returns a new, independent array */
  g_autoptr(GPtrArray) b = wx_suggested_places_new();
  g_assert_true(a != b);
  g_assert_true(g_ptr_array_index(a, 0) != g_ptr_array_index(b, 0));
}

static void
test_initial_rows(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(fx.picker, sug, 5));
  /* nothing of the suggestions is in the (empty) places list yet */
  g_autoptr(GPtrArray) labels = mapped_labels(fx.picker);
  for (guint i = 0; i < labels->len; i++)
    g_assert_false(gtk_widget_get_visible(marker_of(g_ptr_array_index(labels, i))));
  fx_clear(&fx);
}

static void
test_empty_text_restores_suggestions(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  g_autoptr(GPtrArray) hits = sample_hits();
  show_results(&fx, "mia", g_ptr_array_ref(hits), 3);
  g_assert_false(status_visible(fx.picker));

  set_text(fx.picker, "");
  WXT_WAIT_FOR(rows_match(fx.picker, sug, 5));
  g_assert_cmpstr(status_text(fx.picker), ==, "Suggestions");
  g_assert_true(status_is_dim(fx.picker));
  g_assert_false(status_is_error(fx.picker));
  fx_clear(&fx);
}

static void
test_empty_text_cancels(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;

  /* the in-flight search is cancelled; its completion is silent */
  guint i = search_for(&fx, "mia");
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  set_text(p, "");
  g_assert_true(fake_is_cancelled(fx.fake, i));
  g_assert_cmpstr(status_text(p), ==, "Suggestions");
  fake_fail_cancelled(fx.fake, i);
  wxt_pump_ms(50);
  g_assert_cmpstr(status_text(p), ==, "Suggestions");
  g_assert_false(status_is_error(p));
  g_assert_cmpuint(list_n_items(p), ==, 5);

  /* the pending timer is cancelled: no request at all */
  set_text(p, "tampa");
  set_text(p, "");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_cmpstr(status_text(p), ==, "Suggestions");

  /* whitespace only is empty */
  set_text(p, "   \t ");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_cmpstr(status_text(p), ==, "Suggestions");
  g_assert_cmpuint(list_n_items(p), ==, 5);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Debounce                                                           */
/* ------------------------------------------------------------------ */

static void
test_debounce_not_early(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  gint64 t0 = g_get_monotonic_time();
  set_text(fx.picker, "mia");
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  wxt_pump_ms(120);
  /* only meaningful (and only asserted) if the clock really stood below the delay */
  if (g_get_monotonic_time() - t0 < (WX_PICKER_SEARCH_DELAY_MS - 20) * 1000)
    g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  WXT_WAIT_FOR(fake_n(fx.fake) == 1);
  g_assert_cmpint(g_get_monotonic_time() - t0, >=, (WX_PICKER_SEARCH_DELAY_MS - 50) * 1000);
  fx_clear(&fx);
}

static void
test_debounce_one_request(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  set_text(p, "mia");
  WXT_WAIT_FOR(fake_n(fx.fake) >= 1);
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 200);
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_cmpstr(fake_pending(fx.fake, 0)->text, ==, "mia");
  g_assert_false(fake_is_cancelled(fx.fake, 0));
  g_assert_true(status_visible(p));
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  g_assert_true(status_is_dim(p));
  g_assert_false(status_is_error(p));
  fx_clear(&fx);
}

static void
test_debounce_restarts_on_every_edit(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  /* four edits 100 ms apart: 400 ms in total, but each one restarts the 300 ms of quiet */
  const char *const texts[] = { "ma", "mia", "miam", "miami" };
  for (guint i = 0; i < G_N_ELEMENTS(texts); i++) {
    set_text(fx.picker, texts[i]);
    gint64 t0 = g_get_monotonic_time();
    wxt_pump_ms(100);
    if (g_get_monotonic_time() - t0 < (WX_PICKER_SEARCH_DELAY_MS - 20) * 1000)
      g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  }
  gint64 last_edit = g_get_monotonic_time() - 100 * 1000;
  WXT_WAIT_FOR(fake_n(fx.fake) == 1);
  g_assert_cmpint(g_get_monotonic_time() - last_edit, >=, (WX_PICKER_SEARCH_DELAY_MS - 50) * 1000);
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 100);
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_cmpstr(fake_pending(fx.fake, 0)->text, ==, "miami");
  fx_clear(&fx);
}

static void
test_debounce_trims_text(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  guint i = search_for(&fx, "  \t Key  West \n ");
  g_assert_cmpstr(fake_pending(fx.fake, i)->text, ==, "Key  West"); /* inner blanks stay */
  fx_clear(&fx);
}

static void
test_many_quick_edits(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GString *s = g_string_new(NULL);
  for (int i = 0; i < 50; i++) {
    g_string_append_c(s, (char)('a' + i % 26));
    set_text(fx.picker, s->str);
  }
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  WXT_WAIT_FOR(fake_n(fx.fake) == 1);
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 200);
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_cmpstr(fake_pending(fx.fake, 0)->text, ==, s->str);
  g_string_free(s, TRUE);
  fx_clear(&fx);
}

static void
test_new_edit_cancels_in_flight(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  guint a = search_for(&fx, "mia");
  g_assert_false(fake_is_cancelled(fx.fake, a));
  set_text(fx.picker, "miam");
  g_assert_true(fake_is_cancelled(fx.fake, a)); /* at once, before the new timer fires */
  WXT_WAIT_FOR(fake_n(fx.fake) == 2);
  g_assert_cmpstr(fake_pending(fx.fake, 1)->text, ==, "miam");
  g_assert_false(fake_is_cancelled(fx.fake, 1));
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Short text                                                         */
/* ------------------------------------------------------------------ */

static void
test_one_character(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(p, sug, 5));

  set_text(p, "m");
  g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
  g_assert_true(status_visible(p));
  g_assert_true(status_is_dim(p));
  g_assert_false(status_is_error(p));
  g_assert_cmpuint(list_n_items(p), ==, 0); /* results cleared */
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);

  /* after trimming */
  set_text(p, "  q \t");
  g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);

  /* a pending timer and an in-flight search are cancelled by shortening the text */
  guint i = search_for(&fx, "mia");
  set_text(p, "m");
  g_assert_true(fake_is_cancelled(fx.fake, i));
  g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
  fake_fail_cancelled(fx.fake, i);
  set_text(p, "mi");
  set_text(p, "m");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);

  /* two bytes are enough: the limit counts bytes, so one two-byte letter starts a search */
  guint j = search_for(&fx, "\xC3\xA9");
  g_assert_cmpstr(fake_pending(fx.fake, j)->text, ==, "\xC3\xA9");
  guint k = search_for(&fx, "ab");
  g_assert_cmpstr(fake_pending(fx.fake, k)->text, ==, "ab");
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Enter                                                              */
/* ------------------------------------------------------------------ */

static void
test_enter_searches_at_once(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;

  set_text(p, " mia ");
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  g_signal_emit_by_name(find(p, "wx-picker-search-entry"), "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 1); /* synchronously */
  g_assert_cmpstr(fake_pending(fx.fake, 0)->text, ==, "mia");
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250); /* the timer was cancelled */
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_false(fake_is_cancelled(fx.fake, 0));
  fx_clear(&fx);
}

/* Presses Enter @times in a row without running the main loop; TRUE iff all of them happened less
 * than WX_PICKER_SEARCH_DELAY_MS after @since_us (taken before the answer they follow, which came
 * later), i.e. every one of them is "too soon" by the rule of the picker. A host so slow that the
 * presses fall outside the delay makes the caller skip its assertions instead of failing. */
static gboolean
press_enter_soon(GtkWidget *entry, guint times, gint64 since_us)
{
  for (guint i = 0; i < times; i++)
    g_signal_emit_by_name(entry, "activate");
  return g_get_monotonic_time() - since_us < (gint64)WX_PICKER_SEARCH_DELAY_MS * 1000;
}

/* Enter while the same search is in flight does not replace it; after an edit it searches. */
static void
test_enter_does_not_replace_the_search_in_flight(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *entry = find(p, "wx-picker-search-entry");

  guint a = search_for(&fx, "mia");
  g_signal_emit_by_name(entry, "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_false(fake_is_cancelled(fx.fake, a));
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");

  /* an edit that leaves the query as it was still cancels the search and forgets it: Enter then
   * searches at once, and is ignored again while that search runs */
  set_text(p, "mia ");
  g_assert_true(fake_is_cancelled(fx.fake, a));
  g_signal_emit_by_name(entry, "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);
  g_assert_cmpstr(fake_pending(fx.fake, 1)->text, ==, "mia");
  g_signal_emit_by_name(entry, "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);
  g_assert_false(fake_is_cancelled(fx.fake, 1));

  /* another query is another search: the edit cancels the old one */
  set_text(p, "mia b");
  g_signal_emit_by_name(entry, "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 3);
  g_assert_true(fake_is_cancelled(fx.fake, 1));
  g_assert_cmpstr(fake_pending(fx.fake, 2)->text, ==, "mia b");
  fx_clear(&fx);
}

/* Key auto-repeat: Enter held down (60 key events in 2 s, 33 ms apart) with the text unchanged
 * makes at most one search, whether the search started by the debounce timer or by the first
 * Enter. */
static void
test_enter_held_down_starts_one_search(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *entry = find(p, "wx-picker-search-entry");

  set_text(p, "Miami");
  WXT_WAIT_FOR(fake_n(fx.fake) == 1); /* the debounced search is in flight */
  for (guint i = 0; i < 60; i++) {
    g_signal_emit_by_name(entry, "activate");
    wxt_pump_ms(33);
  }
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_false(fake_is_cancelled(fx.fake, 0));
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");

  /* the first Enter starts the search itself (the debounce timer is pending), the rest repeat it */
  set_text(p, "Orlando");
  for (guint i = 0; i < 60; i++) {
    g_signal_emit_by_name(entry, "activate");
    wxt_pump_ms(33);
  }
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);
  g_assert_true(fake_is_cancelled(fx.fake, 0)); /* the edit cancelled the first search */
  g_assert_false(fake_is_cancelled(fx.fake, 1));
  g_assert_cmpstr(fake_pending(fx.fake, 1)->text, ==, "Orlando");
  fx_clear(&fx);
}

/* A search that was answered a moment ago is not repeated by Enter, whatever the answer was; once
 * WX_PICKER_SEARCH_DELAY_MS have passed Enter repeats it, which is how a failure is retried. */
static void
test_enter_repeats_an_answered_search_only_after_the_delay(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *entry = find(p, "wx-picker-search-entry");
  g_autoptr(GPtrArray) hits = sample_hits();

  /* results */
  guint a = search_for(&fx, "mia");
  gint64 t0 = g_get_monotonic_time();
  fake_complete(fx.fake, a, g_ptr_array_ref(hits));
  WXT_WAIT_FOR(!status_visible(p)); /* the answer was applied */
  if (!press_enter_soon(entry, 60, t0)) {
    g_test_skip("the host is too slow for the delay of the picker");
    fx_clear(&fx);
    return;
  }
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_false(status_visible(p));
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 50);
  g_signal_emit_by_name(entry, "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");

  /* an error */
  t0 = g_get_monotonic_time();
  fake_fail(fx.fake, 1, g_error_new_literal(WX_ERROR, WX_ERROR_NETWORK, "offline"));
  WXT_WAIT_FOR(status_is_error(p));
  if (!press_enter_soon(entry, 60, t0)) {
    g_test_skip("the host is too slow for the delay of the picker");
    fx_clear(&fx);
    return;
  }
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);
  g_assert_true(status_is_error(p));
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 50);
  g_signal_emit_by_name(entry, "activate"); /* the retry */
  g_assert_cmpuint(fake_n(fx.fake), ==, 3);
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  g_assert_false(status_is_error(p));
  fx_clear(&fx);
}

/* What is not an answer is not remembered: an edit forgets the search that was just answered
 * (Enter after it searches at once), and so does a completion that reports a cancellation. */
static void
test_enter_after_an_edit_or_a_cancellation_searches(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *entry = find(p, "wx-picker-search-entry");
  g_autoptr(GPtrArray) hits = sample_hits();

  guint a = search_for(&fx, "mia");
  fake_complete(fx.fake, a, g_ptr_array_ref(hits));
  WXT_WAIT_FOR(!status_visible(p));
  set_text(p, "mia "); /* the same query, retyped */
  g_signal_emit_by_name(entry, "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);
  g_assert_cmpstr(fake_pending(fx.fake, 1)->text, ==, "mia");

  /* the geocoder gives up with a cancellation of its own accord: nothing was answered */
  fake_fail_cancelled(fx.fake, 1);
  WXT_WAIT_FOR(!status_visible(p));
  g_signal_emit_by_name(entry, "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 3);
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  fx_clear(&fx);
}

static void
test_enter_ignored_for_short_text(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *entry = find(p, "wx-picker-search-entry");

  g_signal_emit_by_name(entry, "activate"); /* empty */
  g_assert_cmpstr(status_text(p), ==, "Suggestions");
  set_text(p, " m ");
  g_signal_emit_by_name(entry, "activate"); /* one byte */
  g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
  set_text(p, "   ");
  g_signal_emit_by_name(entry, "activate"); /* blank */
  g_assert_cmpstr(status_text(p), ==, "Suggestions");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Query normalisation (what the geocoder accepts)                    */
/* ------------------------------------------------------------------ */

/* Text pasted from right-to-left pages carries bidirectional marks that the geocoder refuses
 * ("unacceptable search text"): the picker searches the text without them, whichever way the
 * search starts, and never shows "Search failed" for that. */
static void
test_query_bidi_marks_removed(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *entry = find(p, "wx-picker-search-entry");
  const struct {
    const char *typed;
    const char *query;
  } cases[] = {
      {"\xE2\x80\x8F" "Cairo", "Cairo"},                    /* U+200F first */
      {"Cairo\xE2\x80\x8E", "Cairo"},                       /* U+200E last */
      {"Ca\xE2\x80\xAE" "iro", "Cairo"},                    /* U+202E inside */
      {"\xD8\xA7\xD9\x84\xD9\x82\xD8\xA7\xD9\x87\xD8\xB1\xD8\xA9\xE2\x80\x8F",
       "\xD8\xA7\xD9\x84\xD9\x82\xD8\xA7\xD9\x87\xD8\xB1\xD8\xA9"}, /* Arabic, trailing RLM */
      {" \xE2\x80\x8F Cairo \xE2\x80\x8E ", "Cairo"},       /* with the white space around them */
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    /* the debounced search */
    guint a = search_for(&fx, cases[i].typed);
    g_assert_cmpstr(fake_pending(fx.fake, a)->text, ==, cases[i].query);
    g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
    g_assert_cmpstr(gtk_editable_get_text(entry_of(p)), ==, cases[i].typed); /* the entry is untouched */
    /* Enter */
    set_text(p, "");
    guint n = fake_n(fx.fake);
    set_text(p, cases[i].typed);
    g_signal_emit_by_name(entry, "activate");
    g_assert_cmpuint(fake_n(fx.fake), ==, n + 1);
    g_assert_cmpstr(fake_pending(fx.fake, n)->text, ==, cases[i].query);
    /* the geocoder's own rule accepts what was passed */
    g_assert_true(wx_text_is_usable_name(fake_pending(fx.fake, n)->text, WX_PICKER_MAX_QUERY_BYTES));
    g_assert_false(status_is_error(p));
  }
  fx_clear(&fx);
}

/* Text the geocoder refuses even after the forbidden characters are gone (only white space that
 * is not ASCII), or that is nothing but forbidden characters, starts no search and gets a hint,
 * never "Search failed". */
static void
test_query_unsearchable_has_a_hint(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *entry = find(p, "wx-picker-search-entry");
  const char *const nbsp_only[] = {
      "\xC2\xA0\xC2\xA0",                  /* two no-break spaces */
      " \xC2\xA0\xC2\xA0 ",                /* with ASCII spaces around */
      "\xE3\x80\x80\xE3\x80\x80",          /* two ideographic spaces */
      "\xE2\x80\x8F\xC2\xA0\xC2\xA0\xE2\x80\x8E", /* and bidi marks */
  };
  for (guint i = 0; i < G_N_ELEMENTS(nbsp_only); i++) {
    set_text(p, "");
    set_text(p, nbsp_only[i]);
    g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
    g_assert_false(status_is_error(p));
    g_assert_cmpuint(list_n_items(p), ==, 0);
    g_signal_emit_by_name(entry, "activate");
    wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
    g_assert_cmpuint(fake_n(fx.fake), ==, 0);
    g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
  }
  /* only marks: nothing is left of the query, so the picker is in its empty state */
  set_text(p, "");
  set_text(p, "\xE2\x80\x8E\xE2\x80\x8F");
  g_assert_cmpstr(status_text(p), ==, "Suggestions");
  g_signal_emit_by_name(entry, "activate");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  /* one letter plus a mark is still too short */
  set_text(p, "");
  set_text(p, "m\xE2\x80\x8F");
  g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  /* an in-flight search is cancelled when the text turns unsearchable */
  guint i = search_for(&fx, "mia");
  set_text(p, "");
  set_text(p, "\xC2\xA0\xC2\xA0");
  g_assert_true(fake_is_cancelled(fx.fake, i));
  g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
  fx_clear(&fx);
}

/* Whatever the entry holds, a search starts exactly when the geocoder's rule accepts the
 * query, and then with the independently computed query (forbidden characters removed, ASCII
 * white space stripped). Random texts from an alphabet of the characters that matter. */
static gboolean
oracle_forbidden(gunichar c)
{
  return (c >= 0x01 && c <= 0x1F) || c == 0x7F || (c >= 0x80 && c <= 0x9F) || c == 0x2028 ||
         c == 0x2029 || c == 0x061C || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) ||
         (c >= 0x2066 && c <= 0x2069);
}

static char *
oracle_query(const char *text)
{
  GString *out = g_string_new(NULL);
  for (const char *s = text; *s != '\0'; s = g_utf8_next_char(s)) {
    gunichar c = g_utf8_get_char(s);
    if (!oracle_forbidden(c))
      g_string_append_unichar(out, c);
  }
  char *q = g_string_free(out, FALSE);
  gsize start = 0;
  gsize end = strlen(q);
  while (start < end && (q[start] == ' ' || (q[start] >= 0x09 && q[start] <= 0x0D)))
    start++;
  while (end > start && (q[end - 1] == ' ' || (q[end - 1] >= 0x09 && q[end - 1] <= 0x0D)))
    end--;
  char *r = g_strndup(q + start, end - start);
  g_free(q);
  return r;
}

static void
test_query_matches_the_geocoder_rule(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *entry = find(p, "wx-picker-search-entry");
  const char *const atoms[] = {
      "a", "b", "Cairo", " ", "  ", "\xC3\xA9", "\xE2\x80\x8E", "\xE2\x80\x8F", "\xE2\x80\xAE",
      "\xE2\x81\xA6", "\xD8\x9C", "\xC2\xA0", "\xE3\x80\x80", "\xE2\x80\x83", "\xE2\x80\x8B",
      "\xEF\xBB\xBF", "\xC2\x85", "\xE2\x80\xA8", "\t", "\x01", "\x7F", "\xF0\x9F\x8C\xA7",
      "\xD8\xA7\xD9\x84\xD9\x82\xD8\xA7\xD9\x87\xD8\xB1\xD8\xA9",
  };
  g_autoptr(GRand) rnd = g_rand_new_with_seed(20260713);
  guint started = 0;
  guint refused = 0;
  for (guint round = 0; round < 600; round++) {
    GString *text = g_string_new(NULL);
    guint n_atoms = g_rand_int_range(rnd, 1, 7);
    for (guint i = 0; i < n_atoms; i++)
      g_string_append(text, atoms[g_rand_int_range(rnd, 0, G_N_ELEMENTS(atoms))]);
    set_text(p, "");
    set_text(p, text->str);
    g_string_free(text, TRUE);
    const char *typed = gtk_editable_get_text(entry_of(p));
    g_autofree char *want = oracle_query(typed);
    gboolean searchable = strlen(want) >= WX_PICKER_MIN_QUERY_BYTES &&
                          wx_text_is_usable_name(want, WX_PICKER_MAX_QUERY_BYTES);
    guint before = fake_n(fx.fake);
    g_signal_emit_by_name(entry, "activate");
    if (searchable) {
      g_assert_cmpuint(fake_n(fx.fake), ==, before + 1);
      g_assert_cmpstr(fake_pending(fx.fake, before)->text, ==, want);
      started++;
    } else {
      g_assert_cmpuint(fake_n(fx.fake), ==, before);
      refused++;
    }
    g_assert_false(status_is_error(p));
    /* no timer is left to start another search by itself */
    wxt_pump_idle();
  }
  g_assert_cmpuint(started, >, 100);
  g_assert_cmpuint(refused, >, 20);
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, started);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Results                                                            */
/* ------------------------------------------------------------------ */

static void
test_results_rows(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) hits = sample_hits();
  show_results(&fx, "mia", g_ptr_array_ref(hits), 3);
  g_assert_false(status_visible(p)); /* success hides the status line */
  g_assert_cmpstr(status_text(p), ==, "");

  g_auto(GStrv) v = visible_labels(p);
  g_assert_cmpstr(v[0], ==, "Miami, Florida, United States");
  g_assert_cmpstr(v[1], ==, "Miami, Oklahoma, United States");
  g_assert_cmpstr(v[2], ==, "Miami Beach, Florida, United States");
  /* every row has ONE label named "wx-picker-label" and a dim "Added" marker; the label is also
   * the tooltip */
  g_autoptr(GPtrArray) labels = mapped_labels(p);
  g_assert_cmpuint(labels->len, ==, 3);
  for (guint i = 0; i < labels->len; i++) {
    GtkWidget *label = g_ptr_array_index(labels, i);
    g_assert_cmpstr(gtk_widget_get_tooltip_text(label), ==, gtk_label_get_text(GTK_LABEL(label)));
    GtkWidget *marker = marker_of(label);
    g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(marker)), ==, "Added");
    g_assert_true(gtk_widget_has_css_class(marker, "dim-label"));
    g_assert_false(gtk_widget_get_visible(marker));
    g_assert_true(gtk_widget_get_hexpand(label));
    g_assert_cmpint(gtk_label_get_ellipsize(GTK_LABEL(label)), ==, PANGO_ELLIPSIZE_END);
  }
  /* a second search replaces the rows (and the first completion does not come back) */
  g_autoptr(GPtrArray) more = sample_places(2);
  show_results(&fx, "spring", g_ptr_array_ref(more), 2);
  fx_clear(&fx);
}

static void
test_result_cap(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) hits = sample_places(30);
  guint i = search_for(&fx, "spring");
  fake_complete(fx.fake, i, g_ptr_array_ref(hits));
  /* the service returns at most WX_GEOCODER_MAX_HITS places; all of them are listed, in order */
  WXT_WAIT_FOR(list_n_items(fx.picker) == WX_GEOCODER_MAX_HITS);
  WXT_WAIT_FOR(rows_match(fx.picker, hits, WX_GEOCODER_MAX_HITS));
  g_assert_cmpuint(WX_GEOCODER_MAX_HITS, ==, 20);
  g_assert_null(find_label(fx.picker, "Springfield 20, Illinois, United States"));
  g_assert_nonnull(find_label(fx.picker, "Springfield 19, Illinois, United States"));
  g_assert_false(status_visible(fx.picker));
  fx_clear(&fx);
}

static void
test_scrolled_list(void)
{
  /* in a small window only the first rows are on screen; the list is scrolled to see the rest */
  Fx fx;
  fx_init(&fx, PRESENT_SMALL);
  g_autoptr(GPtrArray) hits = sample_places(20);
  guint i = search_for(&fx, "spring");
  fake_complete(fx.fake, i, g_ptr_array_ref(hits));
  WXT_WAIT_FOR(list_n_items(fx.picker) == 20);
  WXT_WAIT_FOR(n_mapped_labels(fx.picker) > 0 && n_mapped_labels(fx.picker) < 20);
  WXT_WAIT_FOR(find_label(fx.picker, "Springfield 0, Illinois, United States") != NULL);
  GtkWidget *list = find(fx.picker, "wx-picker-results");
  g_assert_true(GTK_IS_SCROLLED_WINDOW(gtk_widget_get_parent(list)));
  g_assert_cmpuint(n_mapped_labels(fx.picker), <, 20);
  g_assert_null(find_label(fx.picker, "Springfield 19, Illinois, United States"));

  g_assert_true(gtk_widget_activate_action(list, "list.scroll-to-item", "u", 19u));
  WXT_WAIT_FOR(find_label(fx.picker, "Springfield 19, Illinois, United States") != NULL);
  WXT_WAIT_FOR(find_label(fx.picker, "Springfield 0, Illinois, United States") == NULL);
  fx_clear(&fx);
}

static void
test_no_results(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(p, sug, 5));
  guint i = search_for(&fx, "zzzz");
  /* the previous list stays while the search runs */
  g_assert_cmpuint(list_n_items(p), ==, 5);
  fake_complete(fx.fake, i, places_new());
  WXT_WAIT_FOR(strcmp(status_text(p), "No results") == 0);
  g_assert_true(status_visible(p));
  g_assert_true(status_is_dim(p));
  g_assert_false(status_is_error(p));
  g_assert_cmpuint(list_n_items(p), ==, 0);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Errors                                                             */
/* ------------------------------------------------------------------ */

static void
test_error_codes(void)
{
  static const WxError codes[] = {
    WX_ERROR_NETWORK, WX_ERROR_TIMEOUT,     WX_ERROR_HTTP,        WX_ERROR_RATE_LIMITED,
    WX_ERROR_PARSE,   WX_ERROR_NOT_FOUND,   WX_ERROR_INVALID_ARG, WX_ERROR_UNSUPPORTED,
  };
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) hits = sample_hits();
  for (guint c = 0; c < G_N_ELEMENTS(codes); c++) {
    /* results first, so that the failure has something to clear */
    show_results(&fx, "mia", g_ptr_array_ref(hits), 3);
    g_assert_false(status_is_error(p));
    g_autofree char *msg = g_strdup_printf("failure number %u", c);
    guint i = search_for(&fx, "miami");
    fake_fail(fx.fake, i, g_error_new_literal(WX_ERROR, codes[c], msg));
    g_autofree char *expected = g_strdup_printf("Search failed: %s", msg);
    WXT_WAIT_FOR(status_is_error(p));
    g_assert_cmpstr(status_text(p), ==, expected);
    g_assert_true(status_visible(p));
    g_assert_false(status_is_dim(p));
    g_assert_cmpuint(list_n_items(p), ==, 0);
  }
  fx_clear(&fx);
}

static void
test_error_foreign_and_missing(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;

  /* an error of another domain is shown with its message */
  guint i = search_for(&fx, "mia");
  fake_fail(fx.fake, i, g_error_new_literal(G_FILE_ERROR, G_FILE_ERROR_NOENT, "no such thing"));
  WXT_WAIT_FOR(status_is_error(p));
  g_assert_cmpstr(status_text(p), ==, "Search failed: no such thing");

  /* a geocoder that answers nothing at all */
  i = search_for(&fx, "miam");
  fake_complete(fx.fake, i, NULL);
  WXT_WAIT_FOR(strcmp(status_text(p), "Search failed: the geocoder returned no result") == 0);
  g_assert_true(status_is_error(p));

  /* no geocoder registered */
  wx_registry_set_geocoder(fx.registry, NULL);
  set_text(p, "miami");
  WXT_WAIT_FOR(strcmp(status_text(p), "Search failed: no geocoder is registered") == 0);
  g_assert_true(status_is_error(p));
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);

  /* success after failure clears the error class */
  wx_registry_set_geocoder(fx.registry, WX_GEOCODER(fx.fake));
  i = search_for(&fx, "miami!");
  fake_complete(fx.fake, i, sample_hits());
  WXT_WAIT_FOR(!status_visible(p));
  g_assert_false(status_is_error(p));
  g_assert_true(status_is_dim(p));
  fx_clear(&fx);
}

static void
test_error_cancelled_is_silent(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) hits = sample_hits();
  show_results(&fx, "mia", g_ptr_array_ref(hits), 3);

  /* a geocoder that reports CANCELLED for the current request (nobody cancelled it) */
  guint i = search_for(&fx, "miam");
  g_assert_true(status_visible(p));
  fake_fail_cancelled(fx.fake, i);
  WXT_WAIT_FOR(!status_visible(p));
  g_assert_false(status_is_error(p));
  g_assert_cmpstr(status_text(p), ==, "");
  WXT_WAIT_FOR(rows_match(p, hits, 3)); /* the list is left alone (the layout moves) */
  fx_clear(&fx);
}

static void
test_error_text_sanitised(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;

  /* control characters, a bidi override and format characters are removed */
  guint i = search_for(&fx, "one");
  fake_fail(fx.fake, i,
            g_error_new_literal(WX_ERROR, WX_ERROR_NETWORK,
                                "boom\x01\n\t\xE2\x80\xAE<b>x</b>\xE2\x80\xA9 & \xE2\x81\xA6"
                                "done\x7f"));
  WXT_WAIT_FOR(status_is_error(p));
  g_assert_cmpstr(status_text(p), ==, "Search failed: boom<b>x</b> & done");

  /* a message of nothing but forbidden characters leaves the prefix alone */
  i = search_for(&fx, "two");
  fake_fail(fx.fake, i, g_error_new_literal(WX_ERROR, WX_ERROR_HTTP, "\x01\x02\xE2\x80\xAE"));
  WXT_WAIT_FOR(strcmp(status_text(p), "Search failed: ") == 0);
  g_assert_true(status_is_error(p));

  /* a huge message is cut to WX_PICKER_MAX_MESSAGE_BYTES */
  i = search_for(&fx, "three");
  g_autofree char *big = g_strnfill(10 * 1024, 'x');
  fake_fail(fx.fake, i, g_error_new_literal(WX_ERROR, WX_ERROR_HTTP, big));
  WXT_WAIT_FOR(strlen(status_text(p)) > 20);
  g_assert_cmpuint(strlen(status_text(p)), ==,
                   strlen("Search failed: ") + WX_PICKER_MAX_MESSAGE_BYTES);

  /* invalid UTF-8 is replaced, so the text is valid */
  i = search_for(&fx, "four");
  fake_fail(fx.fake, i, g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "ab\xff\xfe\xC3"));
  WXT_WAIT_FOR(strstr(status_text(p), "ab") != NULL);
  g_assert_true(g_utf8_validate(status_text(p), -1, NULL));
  g_assert_true(status_is_error(p));

  /* multi-byte text is cut on a character boundary */
  i = search_for(&fx, "five");
  GString *mb = g_string_new(NULL);
  for (int n = 0; n < 500; n++)
    g_string_append(mb, "\xE2\x82\xAC"); /* 3 bytes each */
  fake_fail(fx.fake, i, g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, mb->str));
  g_string_free(mb, TRUE);
  WXT_WAIT_FOR(strstr(status_text(p), "\xE2\x82\xAC") != NULL);
  g_assert_true(g_utf8_validate(status_text(p), -1, NULL));
  g_assert_cmpuint(strlen(status_text(p)), ==, strlen("Search failed: ") + 66 * 3);

  /* format characters are text, not format strings */
  i = search_for(&fx, "six");
  fake_fail(fx.fake, i, g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "%s%n%d %%"));
  WXT_WAIT_FOR(strstr(status_text(p), "%s%n%d %%") != NULL);
  g_assert_cmpstr(status_text(p), ==, "Search failed: %s%n%d %%");
  fx_clear(&fx);
}

static GPtrArray *
hostile_places(void)
{
  GPtrArray *a = places_new();
  WxPlace *bad = g_new0(WxPlace, 1); /* control characters, impossible latitude */
  bad->name = g_strdup("Ev\x01il\n");
  bad->admin1 = g_strdup("");
  bad->country = g_strdup("");
  bad->timezone = g_strdup("");
  bad->lat = 999.0;
  g_ptr_array_add(a, bad);
  g_ptr_array_add(a, NULL);
  WxPlace *bidi = g_new0(WxPlace, 1); /* a bidi override in the name */
  bidi->name = g_strdup("Bidi \xE2\x80\xAE" "name");
  bidi->admin1 = g_strdup("");
  bidi->country = g_strdup("");
  bidi->timezone = g_strdup("");
  g_ptr_array_add(a, bidi);
  g_ptr_array_add(a, mk_place("Good Place", "Region", "Country", 10.0, 10.0));
  WxPlace *nan_place = g_new0(WxPlace, 1);
  nan_place->name = g_strdup("Nowhere");
  nan_place->admin1 = g_strdup("");
  nan_place->country = g_strdup("");
  nan_place->timezone = g_strdup("../../etc");
  nan_place->lat = NAN;
  nan_place->lon = 1.0;
  g_ptr_array_add(a, nan_place);
  return a;
}

static void
test_hostile_places_dropped(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  guint i = search_for(&fx, "evil");
  fake_complete(fx.fake, i, hostile_places()); /* no critical, no assertion */
  g_autoptr(GPtrArray) good = places_new();
  g_ptr_array_add(good, mk_place("Good Place", "Region", "Country", 10.0, 10.0));
  WXT_WAIT_FOR(rows_match(p, good, 1));
  g_assert_false(status_visible(p));

  /* nothing but hostile places: "No results" */
  i = search_for(&fx, "evil2");
  GPtrArray *only_bad = hostile_places();
  g_ptr_array_remove_index(only_bad, 3);
  fake_complete(fx.fake, i, only_bad);
  WXT_WAIT_FOR(strcmp(status_text(p), "No results") == 0);
  g_assert_cmpuint(list_n_items(p), ==, 0);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Stale completions                                                  */
/* ------------------------------------------------------------------ */

/* Completes the superseded request @a with a result or an error. */
static void
complete_stale(Fx *fx, guint a, gboolean fails)
{
  if (fails)
    fake_fail(fx->fake, a, g_error_new_literal(WX_ERROR, WX_ERROR_NETWORK, "stale boom"));
  else
    fake_complete(fx->fake, a, sample_hits());
}

static void
run_stale(gboolean honours_cancel, gboolean stale_first, gboolean stale_fails)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  fx.fake->ignore_cancel = !honours_cancel;

  guint a = search_for(&fx, "old");
  set_text(p, "new");
  g_assert_true(fake_is_cancelled(fx.fake, a)); /* as soon as the text changes */
  WXT_WAIT_FOR(fake_n(fx.fake) == 2);
  g_assert_false(fake_is_cancelled(fx.fake, 1));
  g_assert_cmpstr(fake_pending(fx.fake, 1)->text, ==, "new");

  g_autoptr(GPtrArray) newer = places_new();
  g_ptr_array_add(newer, mk_place("Newer", "Region", "Country", 11.0, 11.0));

  if (stale_first) {
    complete_stale(&fx, a, stale_fails);
    wxt_pump_ms(50);
    /* the newer search is still in flight and still announced; nothing of the stale one */
    g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
    g_assert_false(status_is_error(p));
    g_assert_cmpuint(list_n_items(p), ==, 5); /* the suggestions are untouched */
    fake_complete(fx.fake, 1, g_ptr_array_ref(newer));
    WXT_WAIT_FOR(rows_match(p, newer, 1));
  } else {
    fake_complete(fx.fake, 1, g_ptr_array_ref(newer));
    WXT_WAIT_FOR(rows_match(p, newer, 1));
    complete_stale(&fx, a, stale_fails);
    wxt_pump_ms(50);
  }
  g_assert_false(status_visible(p));
  g_assert_false(status_is_error(p));
  g_assert_null(strstr(status_text(p), "boom"));
  WXT_WAIT_FOR(rows_match(p, newer, 1));
  fx_clear(&fx);
}

static void
test_stale_results(void)
{
  for (int honours = 0; honours < 2; honours++)
    for (int first = 0; first < 2; first++)
      for (int fails = 0; fails < 2; fails++)
        run_stale(honours, first, fails);
}

static void
test_stale_after_enter(void)
{
  /* a search replaced through an edit and Enter is stale too; its completion must not clear
   * "Searching" (Enter alone does not replace a search for the same query) */
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  guint a = search_for(&fx, "mia");
  set_text(p, "mia ");
  g_signal_emit_by_name(find(p, "wx-picker-search-entry"), "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);
  fake_fail_cancelled(fx.fake, a);
  wxt_pump_ms(50);
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  fake_complete(fx.fake, 1, sample_hits());
  WXT_WAIT_FOR(list_n_items(p) == 3);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Adding                                                             */
/* ------------------------------------------------------------------ */

static void
test_add_by_activate(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(fx.picker, sug, 5));
  activate_row(fx.picker, 1); /* Orlando */

  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
  const WxPlace *saved = wx_places_get_place(fx.places, 0);
  g_assert_cmpstr(saved->name, ==, "Orlando");
  g_assert_cmpstr(saved->admin1, ==, "Florida");
  g_assert_cmpstr(saved->timezone, ==, "America/New_York");
  g_assert_true(wx_places_is_dirty(fx.places)); /* edited; the picker never saves */
  /* the signal ran exactly once, with the key, while the window was still open, before the close
   * request */
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  g_assert_cmpstr(g_ptr_array_index(fx.added_keys, 0), ==, "28.5383,-81.3792");
  g_assert_true(fx.visible_at_signal);
  g_assert_cmpuint(fx.closes_before_signal, ==, 0);
  g_assert_cmpuint(fx.close_requests, ==, 1); /* and the picker closed itself */
  WXT_WAIT_FOR(fx.picker == NULL);
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  g_assert_cmpuint(fx.close_requests, ==, 1);
  fx_clear(&fx);
}

static void
test_add_from_results(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) hits = sample_hits();
  show_results(&fx, "mia", g_ptr_array_ref(hits), 3);
  activate_row(fx.picker, 2); /* Miami Beach */
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
  g_assert_cmpstr(wx_places_get_place(fx.places, 0)->name, ==, "Miami Beach");
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  g_assert_cmpstr(g_ptr_array_index(fx.added_keys, 0), ==, "25.7907,-80.1300");
  WXT_WAIT_FOR(fx.picker == NULL);
  fx_clear(&fx);
}

static void
test_add_by_action(void)
{
  /* the list's own activation action (what Enter and a double click end in) */
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(fx.picker, sug, 5));
  GtkWidget *list = find(fx.picker, "wx-picker-results");
  g_assert_true(gtk_widget_activate_action(list, "list.activate-item", "u", 4u));
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
  g_assert_cmpstr(wx_places_get_place(fx.places, 0)->name, ==, "Key West");
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  WXT_WAIT_FOR(fx.picker == NULL);
  fx_clear(&fx);
}

static void
test_add_out_of_range(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  activate_row(fx.picker, 99);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 0);
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  g_assert_cmpuint(fx.close_requests, ==, 0);
  fx_clear(&fx);
}

static void
test_add_refused_duplicate(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 0))); /* Miami */
  WXT_WAIT_FOR(rows_match(p, sug, 5));

  activate_row(p, 0);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
  g_assert_true(status_visible(p));
  g_assert_cmpstr(status_text(p), ==, "Already in your places");
  g_assert_true(status_is_error(p));
  g_assert_false(status_is_dim(p));
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  g_assert_cmpuint(fx.close_requests, ==, 0);
  g_assert_true(gtk_widget_get_visible(p));

  /* adding another place works afterwards, and the picker closes */
  activate_row(p, 1);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 2);
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  fx_clear(&fx);
}

static void
test_add_refused_near_duplicate(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  const WxPlace *orlando = g_ptr_array_index(sug, 1);

  /* a different place (different key) 2.2 km from Orlando, and one 6.7 km away */
  g_autoptr(WxPlace) near = mk_place("Orlando Downtown", "Florida", "United States",
                                     orlando->lat + 0.02, orlando->lon);
  g_autoptr(WxPlace) far = mk_place("Orlando Far", "Florida", "United States",
                                    orlando->lat + 0.06, orlando->lon);
  g_assert_cmpfloat(wx_geo_distance_km(orlando->lat, orlando->lon, near->lat, near->lon), <,
                    WX_PLACES_DUPLICATE_KM);
  g_assert_cmpfloat(wx_geo_distance_km(orlando->lat, orlando->lon, far->lat, far->lon), >,
                    WX_PLACES_DUPLICATE_KM);
  g_autofree char *near_key = wx_place_key(near);
  g_autofree char *orlando_key = wx_place_key(orlando);
  g_assert_cmpstr(near_key, !=, orlando_key);

  g_assert_true(wx_places_add(fx.places, near));
  WXT_WAIT_FOR(rows_match(p, sug, 5));
  activate_row(p, 1);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
  g_assert_cmpstr(status_text(p), ==, "Already in your places");
  g_assert_true(status_is_error(p));
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  g_assert_cmpuint(fx.close_requests, ==, 0);

  /* beyond the limit the same place is accepted */
  g_assert_true(wx_places_remove(fx.places, near_key));
  g_assert_true(wx_places_add(fx.places, far));
  activate_row(p, 1);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 2);
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  g_assert_cmpstr(g_ptr_array_index(fx.added_keys, 0), ==, orlando_key);
  fx_clear(&fx);
}

static void
fill_places(WxPlaces *places, guint n)
{
  g_autoptr(GPtrArray) a = sample_places(n);
  for (guint i = 0; i < a->len; i++)
    g_assert_true(wx_places_add(places, g_ptr_array_index(a, i)));
  g_assert_cmpuint(wx_places_get_n_places(places), ==, n);
}

static void
test_add_refused_full(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  fill_places(fx.places, WX_PLACE_MAX);
  WXT_WAIT_FOR(rows_match(p, sug, 5));

  activate_row(p, 2);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, WX_PLACE_MAX);
  g_assert_true(status_visible(p));
  g_assert_cmpstr(status_text(p), ==, "You can save up to 50 places");
  g_assert_true(status_is_error(p));
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  g_assert_cmpuint(fx.close_requests, ==, 0);
  g_assert_cmpuint(WX_PLACE_MAX, ==, 50);

  /* full is checked first: even a place that is already saved is reported as the limit */
  g_assert_true(wx_places_remove(fx.places, "40.0000,-100.0000"));
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 0)));
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, WX_PLACE_MAX);
  set_text(p, "m"); /* any status of the past is gone ... */
  g_assert_cmpstr(status_text(p), ==, "Type at least 2 letters");
  set_text(p, "");
  g_assert_cmpstr(status_text(p), ==, "Suggestions");
  activate_row(p, 0);
  g_assert_cmpstr(status_text(p), ==, "You can save up to 50 places");

  /* one place fewer and the add works */
  g_assert_true(wx_places_remove(fx.places, "40.0000,-98.0000"));
  activate_row(p, 2);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, WX_PLACE_MAX);
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  fx_clear(&fx);
}

static void
test_refusal_replaced_by_next_status(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 0)));
  WXT_WAIT_FOR(rows_match(p, sug, 5));
  activate_row(p, 0);
  g_assert_true(status_is_error(p));

  guint i = search_for(&fx, "mia");
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  g_assert_false(status_is_error(p));
  fake_complete(fx.fake, i, sample_hits());
  WXT_WAIT_FOR(!status_visible(p));
  g_assert_false(status_is_error(p));
  fx_clear(&fx);
}

static void
test_add_refused_in_results(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) hits = sample_hits();
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(hits, 0)));
  show_results(&fx, "mia", g_ptr_array_ref(hits), 3);
  activate_row(p, 0);
  g_assert_cmpstr(status_text(p), ==, "Already in your places");
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  /* the status line is not an error of the list */
  g_assert_cmpuint(list_n_items(p), ==, 3);
  fx_clear(&fx);
}

static void
test_place_added_only_for_own_adds(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 0)));
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 2)));
  g_assert_true(wx_places_remove(fx.places, "25.7743,-80.1937"));
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  g_assert_cmpuint(fx.close_requests, ==, 0);
  g_assert_true(gtk_widget_get_visible(fx.picker));
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* "Added" marker                                                     */
/* ------------------------------------------------------------------ */

static void
test_added_marker_follows_places(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 0))); /* Miami, before binding */
  WXT_WAIT_FOR(rows_match(p, sug, 5));

  GtkWidget *miami = find_label(p, "Miami, Florida, United States");
  GtkWidget *tampa = find_label(p, "Tampa, Florida, United States");
  g_assert_nonnull(miami);
  g_assert_nonnull(tampa);
  g_assert_true(gtk_widget_get_visible(marker_of(miami)));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(marker_of(miami))), ==, "Added");
  g_assert_false(gtk_widget_get_visible(marker_of(tampa)));
  assert_a11y_description(row_widget_of(miami), "Added");

  /* an external add and remove are reflected at once */
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 2)));
  g_assert_true(gtk_widget_get_visible(marker_of(tampa)));
  assert_a11y_description(row_widget_of(tampa), "Added");
  g_assert_true(wx_places_remove(fx.places, "25.7743,-80.1937"));
  g_assert_false(gtk_widget_get_visible(marker_of(miami)));
  assert_a11y_description(row_widget_of(miami), "");
  g_assert_true(gtk_widget_get_visible(marker_of(tampa)));

  /* a move changes nothing for the rows; a refused add neither */
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 0)));
  g_assert_true(wx_places_move(fx.places, 0, 1));
  g_assert_true(gtk_widget_get_visible(marker_of(miami)));
  g_assert_true(gtk_widget_get_visible(marker_of(tampa)));
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  fx_clear(&fx);
}

static void
test_added_marker_in_results(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) hits = sample_hits();
  show_results(&fx, "mia", g_ptr_array_ref(hits), 3);
  GtkWidget *beach = find_label(p, "Miami Beach, Florida, United States");
  g_assert_false(gtk_widget_get_visible(marker_of(beach)));
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(hits, 2)));
  g_assert_true(gtk_widget_get_visible(marker_of(beach)));

  /* a new list: rows that are bound to other places show the current state */
  g_autoptr(GPtrArray) hits2 = sample_hits();
  g_ptr_array_remove_index(hits2, 0);
  show_results(&fx, "miami", g_ptr_array_ref(hits2), 2);
  GtkWidget *okla = find_label(p, "Miami, Oklahoma, United States");
  beach = find_label(p, "Miami Beach, Florida, United States");
  g_assert_false(gtk_widget_get_visible(marker_of(okla)));
  g_assert_true(gtk_widget_get_visible(marker_of(beach)));
  fx_clear(&fx);
}

static void
test_places_outlive_picker(void)
{
  /* after the picker is gone, edits of the places list must not reach it */
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(fx.picker, sug, 5));
  gtk_window_destroy(GTK_WINDOW(fx.picker));
  WXT_WAIT_FOR(fx.picker == NULL);
  g_assert_true(wx_places_add(fx.places, g_ptr_array_index(sug, 0)));
  g_assert_true(wx_places_remove(fx.places, "25.7743,-80.1937"));
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Accessibility                                                      */
/* ------------------------------------------------------------------ */

static void
test_accessible_labels(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  assert_a11y_label(find(p, "wx-picker-search-entry"), "Search for a city");
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(p, sug, 5));
  /* the row of every suggestion is labelled with exactly the text of its label */
  g_autoptr(GPtrArray) labels = mapped_labels(p);
  g_assert_cmpuint(labels->len, ==, 5);
  for (guint i = 0; i < labels->len; i++) {
    GtkWidget *label = g_ptr_array_index(labels, i);
    GtkWidget *row = row_widget_of(label);
    g_assert_true(GTK_IS_ACCESSIBLE(row));
    g_assert_true(gtk_widget_get_focusable(row));
    assert_a11y_label(row, gtk_label_get_text(GTK_LABEL(label)));
    g_assert_false(gtk_test_accessible_has_property(GTK_ACCESSIBLE(row),
                                                    GTK_ACCESSIBLE_PROPERTY_PLACEHOLDER));
  }
  /* rows that are rebound to other places follow */
  g_autoptr(GPtrArray) hits = sample_hits();
  show_results(&fx, "mia", g_ptr_array_ref(hits), 3);
  g_autoptr(GPtrArray) labels2 = mapped_labels(p);
  g_assert_cmpuint(labels2->len, ==, 3);
  for (guint i = 0; i < labels2->len; i++) {
    GtkWidget *label = g_ptr_array_index(labels2, i);
    assert_a11y_label(row_widget_of(label), gtk_label_get_text(GTK_LABEL(label)));
  }
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Entry                                                              */
/* ------------------------------------------------------------------ */

static void
test_entry_max_length(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *entry = find(fx.picker, "wx-picker-search-entry");
  g_assert_cmpint(gtk_entry_get_max_length(GTK_ENTRY(entry)), ==, 64);
  g_assert_cmpint(WX_PICKER_MAX_QUERY_BYTES, ==, 64);
  /* The entry's limit is the one of the place search: the same constant, and a query that is
   * exactly at the limit is accepted by the geocoder's own text rule. */
  g_assert_cmpint(WX_PICKER_MAX_QUERY_BYTES, ==, WX_OPEN_METEO_SEARCH_MAX_BYTES);

  g_autofree char *huge = g_strnfill(100000, 'q');
  set_text(fx.picker, huge);
  const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
  g_assert_cmpuint(g_utf8_strlen(text, -1), ==, WX_PICKER_MAX_QUERY_CHARS);
  g_assert_cmpuint(strlen(text), ==, WX_PICKER_MAX_QUERY_BYTES);
  WXT_WAIT_FOR(fake_n(fx.fake) == 1);
  g_assert_cmpuint(strlen(fake_pending(fx.fake, 0)->text), ==, WX_PICKER_MAX_QUERY_CHARS);
  g_assert_true(wx_text_is_usable_name(fake_pending(fx.fake, 0)->text, WX_OPEN_METEO_SEARCH_MAX_BYTES));
  fx_clear(&fx);
}

/* Appends @n copies of @unit to @s. */
static void
append_n(GString *s, const char *unit, guint n)
{
  for (guint i = 0; i < n; i++)
    g_string_append(s, unit);
}

/* The bytes are the limit, not the characters: the entry never holds a text that the geocoder's
 * rule (wx_text_is_usable_name() with WX_OPEN_METEO_SEARCH_MAX_BYTES) refuses as too long, and a
 * character is never cut in two. */
static void
test_entry_byte_limit(void)
{
  static const struct {
    const char *unit;
    guint chars_kept;
  } cases[] = {
      {"q", 64},                  /* 1 byte: the character limit decides, 64 */
      {"\xC3\xA9", 32},           /* U+00E9, 2 bytes: 32 characters = 64 bytes */
      {"\xE2\x82\xAC", 21},       /* U+20AC, 3 bytes: 21 characters = 63 bytes, no half character */
      {"\xF0\x9F\x98\x80", 16},   /* U+1F600, 4 bytes: 16 characters = 64 bytes */
  };
  for (guint c = 0; c < G_N_ELEMENTS(cases); c++) {
    Fx fx;
    fx_init(&fx, PRESENT_TALL);
    GtkWidget *entry = find(fx.picker, "wx-picker-search-entry");
    GString *s = g_string_new(NULL);
    append_n(s, cases[c].unit, 100);
    set_text(fx.picker, s->str);
    g_string_free(s, TRUE);
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    g_assert_true(g_utf8_validate(text, -1, NULL));
    g_assert_cmpuint(g_utf8_strlen(text, -1), ==, cases[c].chars_kept);
    g_assert_cmpuint(strlen(text), ==, cases[c].chars_kept * strlen(cases[c].unit));
    g_assert_cmpuint(strlen(text), <=, WX_PICKER_MAX_QUERY_BYTES);
    g_assert_true(wx_text_is_usable_name(text, WX_OPEN_METEO_SEARCH_MAX_BYTES));
    /* the search is for exactly what the entry holds, and the geocoder accepts its length */
    WXT_WAIT_FOR(fake_n(fx.fake) == 1);
    g_assert_cmpstr(fake_pending(fx.fake, 0)->text, ==, text);
    fx_clear(&fx);
  }
}

/* Typing and editing at the limit: a character that does not fit is dropped whole, one that fits
 * is inserted, wherever the cursor is, and a replaced selection makes room. */
static void
test_entry_byte_limit_edits(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkEditable *e = entry_of(fx.picker);
  /* 31 two-byte characters and one ASCII byte: 63 bytes */
  GString *s = g_string_new("a");
  append_n(s, "\xC3\xA9", 31);
  gtk_editable_set_text(e, s->str);
  g_string_free(s, TRUE);
  g_assert_cmpuint(strlen(gtk_editable_get_text(e)), ==, 63);
  int pos = 5;
  gtk_editable_insert_text(e, "\xC3\xA9", -1, &pos); /* 2 bytes: 65, refused whole */
  g_assert_cmpuint(strlen(gtk_editable_get_text(e)), ==, 63);
  gtk_editable_insert_text(e, "z", -1, &pos); /* 1 byte: 64, fits, in the middle */
  g_assert_cmpuint(strlen(gtk_editable_get_text(e)), ==, 64);
  g_assert_cmpint(pos, ==, 6);
  g_assert_true(g_str_has_prefix(gtk_editable_get_text(e), "a\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9z"));
  pos = 0;
  gtk_editable_insert_text(e, "x", -1, &pos); /* full: nothing */
  gtk_editable_insert_text(e, "x", 1, &pos);
  g_assert_cmpuint(strlen(gtk_editable_get_text(e)), ==, 64);
  /* An empty insertion is untouched, and a selection that is replaced makes room (the paste of a
   * long text over everything keeps its first 64 bytes). */
  gtk_editable_insert_text(e, "", 0, &pos);
  g_assert_cmpuint(strlen(gtk_editable_get_text(e)), ==, 64);
  g_autofree char *paste = g_strnfill(200, 'p');
  gtk_editable_select_region(e, 0, -1);
  gtk_editable_delete_selection(e);
  g_assert_cmpstr(gtk_editable_get_text(e), ==, "");
  pos = 0;
  gtk_editable_insert_text(e, paste, -1, &pos);
  g_assert_cmpuint(strlen(gtk_editable_get_text(e)), ==, WX_PICKER_MAX_QUERY_BYTES);
  g_assert_cmpint(pos, ==, 64);
  /* An explicit length counts: only the first 3 bytes of the buffer are the insertion. */
  gtk_editable_set_text(e, "");
  pos = 0;
  gtk_editable_insert_text(e, "abcdefgh", 3, &pos);
  g_assert_cmpstr(gtk_editable_get_text(e), ==, "abc");
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Keyboard                                                           */
/* ------------------------------------------------------------------ */

/* Moves the focus one step the way the window does for Tab (@dir forward) or Shift+Tab
 * (backward) from wherever it is. The step must succeed. */
static void
tab_on(GtkWidget *picker, GtkDirectionType dir)
{
  g_assert_true(gtk_widget_child_focus(picker, dir));
}

/* The window orders its Tab stops by their allocated position, so the order is only the designed
 * one once the layout has run for both. */
static gboolean
tab_stops_laid_out(GtkWidget *picker)
{
  graphene_rect_t e, l;
  GtkWidget *entry = find(picker, "wx-picker-search-entry");
  GtkWidget *list = find(picker, "wx-picker-results");
  return gtk_widget_get_height(entry) > 0 && gtk_widget_get_height(list) > 0 &&
         gtk_widget_compute_bounds(entry, picker, &e) &&
         gtk_widget_compute_bounds(list, picker, &l) && e.origin.y < l.origin.y;
}

static void
test_keyboard_focus_chain(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(p, sug, 5));
  WXT_WAIT_FOR(tab_stops_laid_out(p));
  GtkWidget *entry = find(p, "wx-picker-search-entry");
  GtkWidget *list = find(p, "wx-picker-results");
  GtkWidget *text = GTK_WIDGET(gtk_editable_get_delegate(GTK_EDITABLE(entry)));
  g_assert_true(gtk_widget_get_focusable(text)); /* the GtkText inside the entry */
  g_assert_true(gtk_widget_get_focusable(list));

  /* the entry has the focus; the list is its Tab successor: one stop, a row */
  gtk_widget_grab_focus(entry);
  g_assert_true(focus_within(p, "wx-picker-search-entry"));
  gtk_widget_grab_focus(list);
  g_assert_true(focus_within(p, "wx-picker-results"));
  GtkWidget *first = gtk_window_get_focus(GTK_WINDOW(p));
  g_assert_true(first == list || gtk_widget_is_ancestor(first, list));

  /* Shift+Tab leads from the list back to the entry */
  tab_on(p, GTK_DIR_TAB_BACKWARD);
  g_assert_true(focus_within(p, "wx-picker-search-entry"));

  /* Tab from the list: one stop only, then out of it (it wraps around to the entry) */
  gtk_widget_grab_focus(list);
  tab_on(p, GTK_DIR_TAB_FORWARD);
  g_assert_false(focus_within(p, "wx-picker-results"));
  g_assert_true(focus_within(p, "wx-picker-search-entry"));

  /* and Tab from the entry reaches the list */
  tab_on(p, GTK_DIR_TAB_FORWARD);
  g_assert_true(focus_within(p, "wx-picker-results"));
  fx_clear(&fx);
}

static void
test_keyboard_arrows(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(p, sug, 5));
  GtkWidget *list = find(p, "wx-picker-results");

  GtkWidget *miami = row_widget_of(find_label(p, "Miami, Florida, United States"));
  GtkWidget *orlando = row_widget_of(find_label(p, "Orlando, Florida, United States"));
  GtkWidget *tampa = row_widget_of(find_label(p, "Tampa, Florida, United States"));
  gtk_widget_grab_focus(miami);
  g_assert_true(gtk_window_get_focus(GTK_WINDOW(p)) == miami);
  g_assert_true(gtk_widget_child_focus(list, GTK_DIR_DOWN));
  g_assert_true(gtk_window_get_focus(GTK_WINDOW(p)) == orlando);
  g_assert_true(gtk_widget_child_focus(list, GTK_DIR_DOWN));
  g_assert_true(gtk_window_get_focus(GTK_WINDOW(p)) == tampa);
  g_assert_true(gtk_widget_child_focus(list, GTK_DIR_UP));
  g_assert_true(gtk_window_get_focus(GTK_WINDOW(p)) == orlando);

  /* Enter and Space on the focused row end in the list's "activate" signal */
  g_assert_cmpuint(g_signal_lookup("activate-keybinding", G_OBJECT_TYPE(orlando)), !=, 0);
  g_signal_emit_by_name(orlando, "activate-keybinding");
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
  g_assert_cmpstr(wx_places_get_place(fx.places, 0)->name, ==, "Orlando");
  WXT_WAIT_FOR(fx.picker == NULL);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Closing                                                            */
/* ------------------------------------------------------------------ */

static void
test_escape_closes(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;

  /* other keys do nothing */
  g_assert_false(press_key(p, GDK_KEY_a, 0));
  g_assert_false(press_key(p, GDK_KEY_Escape, GDK_CONTROL_MASK));
  g_assert_cmpuint(fx.close_requests, ==, 0);
  g_assert_true(gtk_widget_get_visible(p));

  /* Escape with the focus in the entry, a pending timer and a cancelled request */
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(p, sug, 5));
  guint a = search_for(&fx, "abc");
  set_text(p, "abcd"); /* cancels #0, arms the timer again */
  g_assert_true(focus_within(p, "wx-picker-search-entry"));
  g_assert_true(press_key(p, GDK_KEY_Escape, 0));
  g_assert_cmpuint(fx.close_requests, ==, 1);
  WXT_WAIT_FOR(fx.picker == NULL);
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250); /* the cancelled timer must not fire */
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_assert_true(fake_is_cancelled(fx.fake, a));
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  fx_clear(&fx);

  /* Escape with the focus in the list */
  fx_init(&fx, PRESENT_TALL);
  p = fx.picker;
  WXT_WAIT_FOR(rows_match(p, sug, 5));
  gtk_widget_grab_focus(find(p, "wx-picker-results"));
  g_assert_true(focus_within(p, "wx-picker-results"));
  g_assert_true(press_key(p, GDK_KEY_Escape, 0));
  g_assert_cmpuint(fx.close_requests, ==, 1);
  WXT_WAIT_FOR(fx.picker == NULL);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 0);
  fx_clear(&fx);

  /* Escape cancels an in-flight request */
  fx_init(&fx, PRESENT_TALL);
  guint b = search_for(&fx, "abc");
  g_assert_false(fake_is_cancelled(fx.fake, b));
  g_assert_true(press_key(fx.picker, GDK_KEY_Escape, 0));
  g_assert_true(fake_is_cancelled(fx.fake, b));
  WXT_WAIT_FOR(fx.picker == NULL);
  fx_clear(&fx);
}

static gboolean
veto_close(GtkWindow *window, gpointer user_data)
{
  (void)window;
  (*(guint *)user_data)++;
  return TRUE;
}

static void
test_close_veto_keeps_search(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  guint vetoes = 0;
  g_signal_connect(fx.picker, "close-request", G_CALLBACK(veto_close), &vetoes);
  guint a = search_for(&fx, "abc");
  g_assert_true(press_key(fx.picker, GDK_KEY_Escape, 0));
  gtk_window_close(GTK_WINDOW(fx.picker));
  g_assert_cmpuint(vetoes, ==, 2);
  /* a vetoed close leaves the window and its search alone */
  g_assert_true(gtk_widget_get_visible(fx.picker));
  g_assert_false(fake_is_cancelled(fx.fake, a));
  g_assert_cmpstr(status_text(fx.picker), ==, "Searching\xE2\x80\xA6");
  fake_complete(fx.fake, a, sample_hits());
  WXT_WAIT_FOR(list_n_items(fx.picker) == 3);
  g_assert_false(status_visible(fx.picker));
  fx_clear(&fx);
}

/* A veto from a handler that runs after the class handler (so after the point where the window
 * would have been destroyed) leaves the timer and the search alone. */
static void
test_close_veto_after(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  guint vetoes = 0;
  g_signal_connect_after(p, "close-request", G_CALLBACK(veto_close), &vetoes);
  guint a = search_for(&fx, "abc");
  set_text(p, "abcd"); /* cancels #0 and arms the timer again */
  g_assert_true(fake_is_cancelled(fx.fake, a));
  gtk_window_close(GTK_WINDOW(p));
  g_assert_cmpuint(vetoes, ==, 1);
  g_assert_true(gtk_widget_get_visible(p));
  WXT_WAIT_FOR(fake_n(fx.fake) == 2);
  g_assert_cmpstr(fake_pending(fx.fake, 1)->text, ==, "abcd");
  g_assert_false(fake_is_cancelled(fx.fake, 1));
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  fake_complete(fx.fake, 1, sample_hits());
  WXT_WAIT_FOR(list_n_items(p) == 3);
  fx_clear(&fx);
}

/* gtk_window_set_hide_on_close(): the window survives the close request, so neither the in-flight
 * search nor the pending debounce timer may be lost. */
static void
test_hide_on_close_keeps_search(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  gtk_window_set_hide_on_close(GTK_WINDOW(p), TRUE);

  guint a = search_for(&fx, "mia");
  gtk_window_close(GTK_WINDOW(p));
  g_assert_cmpuint(fx.close_requests, ==, 1);
  g_assert_false(gtk_widget_get_visible(p));
  g_assert_false(fake_is_cancelled(fx.fake, a));
  fake_complete(fx.fake, a, sample_hits());
  gtk_window_present(GTK_WINDOW(p));
  WXT_WAIT_FOR(list_n_items(p) == 3);
  g_assert_false(status_visible(p));

  set_text(p, "abc"); /* the debounce timer is pending when the window is hidden */
  gtk_window_close(GTK_WINDOW(p));
  g_assert_false(gtk_widget_get_visible(p));
  WXT_WAIT_FOR(fake_n(fx.fake) == 2);
  g_assert_cmpstr(fake_pending(fx.fake, 1)->text, ==, "abc");
  g_assert_false(fake_is_cancelled(fx.fake, 1));
  fake_complete(fx.fake, 1, places_new());
  gtk_window_present(GTK_WINDOW(p));
  WXT_WAIT_FOR(strcmp(status_text(p), "No results") == 0);
  g_assert_cmpuint(fake_n(fx.fake), ==, 2);
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* Destruction and dispose                                            */
/* ------------------------------------------------------------------ */

/* gtk_window_destroy() does not dispose a picker whose owner still holds a reference; the picker
 * nevertheless cancels its timer and its request, and refuses everything afterwards. */
static void
test_destroy_with_owner_ref(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *owner = g_object_ref(p);
  set_text(p, "mia"); /* the timer is pending */
  gtk_window_destroy(GTK_WINDOW(p));
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  /* later edits issue nothing either */
  set_text(p, "miami");
  set_text(p, "");
  set_text(p, "orlando");
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  g_signal_emit_by_name(find(p, "wx-picker-search-entry"), "activate");
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  g_object_unref(owner);
  WXT_WAIT_FOR(fx.picker == NULL);
  fx_clear(&fx);
}

static void
test_destroy_cancels_search(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *owner = g_object_ref(p);
  guint a = search_for(&fx, "msft");
  g_assert_cmpstr(status_text(p), ==, "Searching\xE2\x80\xA6");
  gtk_window_destroy(GTK_WINDOW(p));
  g_assert_nonnull(fx.picker);
  g_assert_true(fake_is_cancelled(fx.fake, a));
  g_assert_false(status_visible(p)); /* no "Searching" without a request */
  g_assert_cmpstr(status_text(p), ==, "");
  fake_complete(fx.fake, a, sample_hits()); /* the late completion is dropped */
  wxt_pump_ms(50);
  g_assert_cmpuint(list_n_items(p), ==, 5);
  g_assert_false(status_visible(p));
  g_assert_false(status_is_error(p));

  /* a destroyed picker adds nothing and emits nothing */
  activate_row(p, 0);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 0);
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  g_assert_false(status_visible(p));
  g_object_unref(owner);
  WXT_WAIT_FOR(fx.picker == NULL);
  fx_clear(&fx);
}

static void
test_dispose_in_flight(void)
{
  for (int ignore = 0; ignore < 2; ignore++) {
    Fx fx;
    fx_init(&fx, PRESENT_TALL);
    fx.fake->ignore_cancel = ignore;
    guint a = search_for(&fx, "abc");
    gtk_window_destroy(GTK_WINDOW(fx.picker));
    WXT_WAIT_FOR(fx.picker == NULL); /* the request does not keep the picker alive */
    g_assert_true(fake_is_cancelled(fx.fake, a));
    /* late completions, success and failure, are dropped */
    if (ignore)
      fake_fail(fx.fake, a, g_error_new_literal(WX_ERROR, WX_ERROR_NETWORK, "late"));
    else
      fake_complete(fx.fake, a, sample_hits());
    wxt_pump_ms(50);
    fx_clear(&fx);
  }
}

static void
test_dispose_pending_timer(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  set_text(fx.picker, "abc");
  gtk_window_destroy(GTK_WINDOW(fx.picker));
  WXT_WAIT_FOR(fx.picker == NULL);
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  fx_clear(&fx);

  /* never presented */
  fx_init(&fx, PRESENT_NONE);
  set_text(fx.picker, "abc");
  gtk_window_destroy(GTK_WINDOW(fx.picker));
  WXT_WAIT_FOR(fx.picker == NULL);
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 0);
  fx_clear(&fx);
}

static void
test_run_dispose(void)
{
  /* g_object_run_dispose(): the timer and the search are cancelled and the picker is inert */
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  GtkWidget *p = fx.picker;
  GtkWidget *owner = g_object_ref(p);
  guint a = search_for(&fx, "abc");
  set_text(p, "abcd"); /* cancels #0, arms the timer */
  g_object_run_dispose(G_OBJECT(p));
  g_assert_true(fake_is_cancelled(fx.fake, a));
  fake_complete(fx.fake, a, sample_hits());
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  g_object_unref(owner);
  WXT_WAIT_FOR(fx.picker == NULL);
  g_assert_cmpuint(fx.added_keys->len, ==, 0);
  fx_clear(&fx);

  /* with a search in flight and no timer */
  fx_init(&fx, PRESENT_TALL);
  owner = g_object_ref(fx.picker);
  a = search_for(&fx, "abc");
  g_object_run_dispose(G_OBJECT(fx.picker));
  g_assert_true(fake_is_cancelled(fx.fake, a));
  g_object_run_dispose(G_OBJECT(owner)); /* may run more than once */
  fake_fail_cancelled(fx.fake, a);
  wxt_pump_ms(50);
  g_object_unref(owner);
  WXT_WAIT_FOR(fx.picker == NULL);
  fx_clear(&fx);
}

static void
test_destroyed_with_transient_parent(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_NONE);
  GtkWidget *parent = gtk_window_new();
  g_object_add_weak_pointer(G_OBJECT(parent), (gpointer *)&parent);
  gtk_window_present(GTK_WINDOW(parent));
  gtk_window_set_transient_for(GTK_WINDOW(fx.picker), GTK_WINDOW(parent));
  gtk_window_set_destroy_with_parent(GTK_WINDOW(fx.picker), TRUE);
  gtk_window_present(GTK_WINDOW(fx.picker));
  guint a = search_for(&fx, "abc");
  set_text(fx.picker, "abcd"); /* a pending timer as well */

  gtk_window_destroy(GTK_WINDOW(parent));
  WXT_WAIT_FOR(parent == NULL);
  WXT_WAIT_FOR(fx.picker == NULL);
  g_assert_true(fake_is_cancelled(fx.fake, a));
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 250);
  g_assert_cmpuint(fake_n(fx.fake), ==, 1);
  fx_clear(&fx);
}

static void
destroy_picker(WxPicker *picker, const char *key, gpointer user_data)
{
  (void)key;
  (void)user_data;
  gtk_window_destroy(GTK_WINDOW(picker));
}

static void
destroy_on_places_changed(WxPlaces *places, gpointer user_data)
{
  (void)places;
  GtkWidget **picker = user_data; /* &Fx.picker: NULL once finalized */
  if (*picker != NULL)
    gtk_window_destroy(GTK_WINDOW(*picker));
}

/* A "place-added" handler may destroy the picker. */
static void
test_destroy_in_place_added(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(fx.picker, sug, 5));
  g_signal_connect(fx.picker, "place-added", G_CALLBACK(destroy_picker), NULL);
  activate_row(fx.picker, 0);
  WXT_WAIT_FOR(fx.picker == NULL);
  g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  fx_clear(&fx);
}

/* A handler of the PLACES' "changed" signal (connected after the picker's own) destroys the
 * picker in the middle of the picker's add, with and without an owner that still holds a
 * reference. The add stands, nothing is emitted, nothing is used after free (the ASan run of
 * this test is the proof), and a destroyed picker accepts no further add. */
static void
test_destroy_in_places_handler(void)
{
  for (int held = 0; held < 2; held++) {
    Fx fx;
    fx_init(&fx, PRESENT_TALL);
    g_autoptr(GPtrArray) sug = wx_suggested_places_new();
    WXT_WAIT_FOR(rows_match(fx.picker, sug, 5));
    g_signal_connect(fx.places, "changed", G_CALLBACK(destroy_on_places_changed), &fx.picker);
    GtkWidget *owner = held ? g_object_ref(fx.picker) : NULL;
    GtkWidget *p = fx.picker;

    activate_row(p, 0);
    g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
    g_assert_cmpuint(fx.added_keys->len, ==, 0);
    g_assert_cmpuint(fx.close_requests, ==, 0);
    if (held) {
      g_assert_nonnull(fx.picker); /* alive, but destroyed */
      activate_row(p, 1);
      g_assert_cmpuint(wx_places_get_n_places(fx.places), ==, 1);
      g_assert_cmpuint(fx.added_keys->len, ==, 0);
      g_object_unref(owner);
    }
    WXT_WAIT_FOR(fx.picker == NULL);
    fx_clear(&fx);
  }
}

static void
hide_on_places_changed(WxPlaces *places, gpointer user_data)
{
  (void)places;
  GtkWidget **picker = user_data;
  if (*picker != NULL)
    gtk_widget_set_visible(*picker, FALSE);
}

/* A places handler that merely hides the picker does not stop the add from being announced. */
static void
test_hide_in_places_handler(void)
{
  Fx fx;
  fx_init(&fx, PRESENT_TALL);
  g_autoptr(GPtrArray) sug = wx_suggested_places_new();
  WXT_WAIT_FOR(rows_match(fx.picker, sug, 5));
  g_signal_connect(fx.places, "changed", G_CALLBACK(hide_on_places_changed), &fx.picker);
  activate_row(fx.picker, 3);
  g_assert_cmpuint(fx.added_keys->len, ==, 1);
  g_assert_cmpstr(g_ptr_array_index(fx.added_keys, 0), ==, "30.3322,-81.6557");
  fx_clear(&fx);
}

/* ------------------------------------------------------------------ */
/* End to end with the shipped test fake                              */
/* ------------------------------------------------------------------ */

typedef struct {
  WxPlaces *places;
  WxRegistry *registry;
  WxService *service;
  WxFakeGeocoder *geocoder;
  GtkWidget *picker;
  char *path;
} E2e;

static void
e2e_init(E2e *e)
{
  memset(e, 0, sizeof *e);
  e->path = g_build_filename(wxt_root, "places-e2e.json", NULL);
  e->places = wx_places_new(e->path);
  e->registry = wx_registry_new();
  e->geocoder = wx_fake_geocoder_new();
  wx_registry_set_geocoder(e->registry, WX_GEOCODER(e->geocoder));
  e->service = wx_service_new(e->registry);
  e->picker = wx_picker_new(e->places, e->service);
  g_object_add_weak_pointer(G_OBJECT(e->picker), (gpointer *)&e->picker);
  gtk_window_set_default_size(GTK_WINDOW(e->picker), 460, 1600);
  gtk_window_present(GTK_WINDOW(e->picker));
  WXT_WAIT_FOR(gtk_widget_get_width(find(e->picker, "wx-picker-results")) > 0);
}

static void
e2e_clear(E2e *e)
{
  if (e->picker != NULL) {
    gtk_window_destroy(GTK_WINDOW(e->picker));
    WXT_WAIT_FOR(e->picker == NULL);
  }
  wxt_pump_idle();
  g_assert_false(g_file_test(e->path, G_FILE_TEST_EXISTS));
  g_object_unref(e->geocoder);
  g_object_unref(e->service);
  g_object_unref(e->registry);
  g_object_unref(e->places);
  g_free(e->path);
}

static void
test_e2e_search_and_add(void)
{
  E2e e;
  e2e_init(&e);
  g_autoptr(GPtrArray) hits = sample_hits();
  for (guint i = 0; i < hits->len; i++)
    wx_fake_geocoder_add_hit(e.geocoder, g_ptr_array_index(hits, i));

  set_text(e.picker, "mia");
  WXT_WAIT_FOR(wx_fake_geocoder_get_search_count(e.geocoder) == 1);
  WXT_WAIT_FOR(rows_match(e.picker, hits, 3));
  g_assert_false(status_visible(e.picker));

  activate_row(e.picker, 0);
  g_assert_cmpuint(wx_places_get_n_places(e.places), ==, 1);
  g_assert_cmpstr(wx_places_get_place(e.places, 0)->name, ==, "Miami");
  WXT_WAIT_FOR(e.picker == NULL);
  e2e_clear(&e);
}

static void
test_e2e_failure_and_cancel(void)
{
  E2e e;
  e2e_init(&e);
  wx_fake_geocoder_fail_with(e.geocoder, WX_ERROR_RATE_LIMITED);
  wx_fake_geocoder_set_delay_ms(e.geocoder, 20);
  set_text(e.picker, "mia");
  g_signal_emit_by_name(find(e.picker, "wx-picker-search-entry"), "activate");
  g_assert_cmpstr(status_text(e.picker), ==, "Searching\xE2\x80\xA6");
  WXT_WAIT_FOR(status_is_error(e.picker));
  g_assert_true(g_str_has_prefix(status_text(e.picker), "Search failed: "));
  g_assert_cmpuint(list_n_items(e.picker), ==, 0);
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(e.geocoder), ==, 1);

  /* a slow search that is replaced by an edit never shows an error. (The failed search is retried
   * with Enter once the delay of the picker has passed: sooner, Enter would only repeat it.) */
  wx_fake_geocoder_fail_with(e.geocoder, -1);
  wx_fake_geocoder_set_delay_ms(e.geocoder, 400);
  wxt_pump_ms(WX_PICKER_SEARCH_DELAY_MS + 50);
  g_signal_emit_by_name(find(e.picker, "wx-picker-search-entry"), "activate");
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(e.geocoder), ==, 2);
  set_text(e.picker, "");
  wxt_pump_ms(600);
  g_assert_false(status_is_error(e.picker));
  g_assert_cmpstr(status_text(e.picker), ==, "Suggestions");
  g_assert_cmpuint(list_n_items(e.picker), ==, 5);
  e2e_clear(&e);
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

int
main(int argc, char **argv)
{
  wxt_setup("wx-picker-test-XXXXXX");
  /* the harness chose GTK_A11Y=none; this test reads accessible properties back, which needs
   * GTK's test backend (see the file comment). GTK has not been initialised yet. */
  g_setenv("GTK_A11Y", "test", TRUE);
  g_test_init(&argc, &argv, NULL);
  if (!wxt_init_gtk())
    return 77;

  g_test_add_func("/picker/construct/bad-arguments", test_bad_arguments);
  g_test_add_func("/picker/construct/references", test_construct_references);
  g_test_add_func("/picker/construct/initial-state", test_initial_state);
  g_test_add_func("/picker/construct/initial-focus", test_initial_focus);
  g_test_add_func("/picker/construct/constants", test_constants);
  g_test_add_func("/picker/suggestions/places", test_suggested_places);
  g_test_add_func("/picker/suggestions/rows", test_initial_rows);
  g_test_add_func("/picker/empty/restores-suggestions", test_empty_text_restores_suggestions);
  g_test_add_func("/picker/empty/cancels", test_empty_text_cancels);
  g_test_add_func("/picker/debounce/not-early", test_debounce_not_early);
  g_test_add_func("/picker/debounce/one-request", test_debounce_one_request);
  g_test_add_func("/picker/debounce/restarts", test_debounce_restarts_on_every_edit);
  g_test_add_func("/picker/debounce/trims", test_debounce_trims_text);
  g_test_add_func("/picker/debounce/many-edits", test_many_quick_edits);
  g_test_add_func("/picker/debounce/edit-cancels-in-flight", test_new_edit_cancels_in_flight);
  g_test_add_func("/picker/short/one-character", test_one_character);
  g_test_add_func("/picker/enter/at-once", test_enter_searches_at_once);
  g_test_add_func("/picker/enter/in-flight-is-not-replaced", test_enter_does_not_replace_the_search_in_flight);
  g_test_add_func("/picker/enter/held-down-starts-one-search", test_enter_held_down_starts_one_search);
  g_test_add_func("/picker/enter/answered-repeats-after-the-delay", test_enter_repeats_an_answered_search_only_after_the_delay);
  g_test_add_func("/picker/enter/edit-or-cancellation-forgets", test_enter_after_an_edit_or_a_cancellation_searches);
  g_test_add_func("/picker/enter/short-text", test_enter_ignored_for_short_text);
  g_test_add_func("/picker/results/rows", test_results_rows);
  g_test_add_func("/picker/results/cap", test_result_cap);
  g_test_add_func("/picker/results/scrolled", test_scrolled_list);
  g_test_add_func("/picker/results/none", test_no_results);
  g_test_add_func("/picker/errors/every-code", test_error_codes);
  g_test_add_func("/picker/errors/foreign-and-missing", test_error_foreign_and_missing);
  g_test_add_func("/picker/errors/cancelled-is-silent", test_error_cancelled_is_silent);
  g_test_add_func("/picker/errors/sanitised", test_error_text_sanitised);
  g_test_add_func("/picker/errors/hostile-places", test_hostile_places_dropped);
  g_test_add_func("/picker/stale/combinations", test_stale_results);
  g_test_add_func("/picker/stale/after-enter", test_stale_after_enter);
  g_test_add_func("/picker/add/activate", test_add_by_activate);
  g_test_add_func("/picker/add/from-results", test_add_from_results);
  g_test_add_func("/picker/add/action", test_add_by_action);
  g_test_add_func("/picker/add/out-of-range", test_add_out_of_range);
  g_test_add_func("/picker/add/refused-duplicate", test_add_refused_duplicate);
  g_test_add_func("/picker/add/refused-near-duplicate", test_add_refused_near_duplicate);
  g_test_add_func("/picker/add/refused-full", test_add_refused_full);
  g_test_add_func("/picker/add/refusal-replaced", test_refusal_replaced_by_next_status);
  g_test_add_func("/picker/add/refused-in-results", test_add_refused_in_results);
  g_test_add_func("/picker/add/signal-only-for-own-adds", test_place_added_only_for_own_adds);
  g_test_add_func("/picker/added-marker/follows-places", test_added_marker_follows_places);
  g_test_add_func("/picker/added-marker/in-results", test_added_marker_in_results);
  g_test_add_func("/picker/added-marker/places-outlive", test_places_outlive_picker);
  g_test_add_func("/picker/accessible/labels", test_accessible_labels);
  g_test_add_func("/picker/entry/max-length", test_entry_max_length);
  g_test_add_func("/picker/entry/byte-limit", test_entry_byte_limit);
  g_test_add_func("/picker/entry/byte-limit-edits", test_entry_byte_limit_edits);
  g_test_add_func("/picker/keyboard/focus-chain", test_keyboard_focus_chain);
  g_test_add_func("/picker/keyboard/arrows-and-activate", test_keyboard_arrows);
  g_test_add_func("/picker/close/escape", test_escape_closes);
  g_test_add_func("/picker/close/veto", test_close_veto_keeps_search);
  g_test_add_func("/picker/close/veto-after", test_close_veto_after);
  g_test_add_func("/picker/close/hide-on-close", test_hide_on_close_keeps_search);
  g_test_add_func("/picker/destroy/owner-ref", test_destroy_with_owner_ref);
  g_test_add_func("/picker/destroy/cancels-search", test_destroy_cancels_search);
  g_test_add_func("/picker/destroy/in-flight", test_dispose_in_flight);
  g_test_add_func("/picker/destroy/pending-timer", test_dispose_pending_timer);
  g_test_add_func("/picker/destroy/run-dispose", test_run_dispose);
  g_test_add_func("/picker/destroy/transient-parent", test_destroyed_with_transient_parent);
  g_test_add_func("/picker/destroy/in-place-added", test_destroy_in_place_added);
  g_test_add_func("/picker/destroy/in-places-handler", test_destroy_in_places_handler);
  g_test_add_func("/picker/destroy/hide-in-places-handler", test_hide_in_places_handler);
  g_test_add_func("/picker/e2e/search-and-add", test_e2e_search_and_add);
  g_test_add_func("/picker/e2e/failure-and-cancel", test_e2e_failure_and_cancel);
  g_test_add_func("/picker/query/bidi-marks-removed", test_query_bidi_marks_removed);
  g_test_add_func("/picker/query/unsearchable-has-a-hint", test_query_unsearchable_has_a_hint);
  g_test_add_func("/picker/query/matches-the-geocoder-rule", test_query_matches_the_geocoder_rule);
  return g_test_run();
}
