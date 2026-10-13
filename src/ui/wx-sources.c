/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-sources.c - WxSources implementation. Behaviour is specified in wx-sources.h.
 *
 * Structure:
 *  - One Row per provider (id copy, switch, status label). The other row widgets never change
 *    after the row is built. The rows are only ever appended (the registry has no removal).
 *  - The forecast is kept as a private list of Entry structs (id, state, error code, member
 *    count) copied from the sources of the forecast handed in, so the status lines can be
 *    recomputed whenever the registry changes without holding the forecast.
 *  - The switch id is stored as data on the switch itself, so the "state-set" handler needs no
 *    pointer into the row array.
 */
#include "wx-sources.h"

#include <string.h>

#include "wx-text.h"

#define ROW_ID_KEY "wx-sources-provider-id"

/* The honesty note, verbatim. */
#define NOTE_TEXT                                                                            \
  "Forecasts blend several sources with fixed, documented weights. These weights are rules " \
  "of thumb, not statistics measured from past accuracy, so no accuracy figure is claimed."

/* ------------------------------------------------------------------------ */
/* Licence table                                                            */
/* ------------------------------------------------------------------------ */

/* before + (link_text linked to url, when url is non-NULL) + after. */
typedef struct {
  const char *id;
  const char *before;
  const char *link_text;
  const char *url;
  const char *after;
} Licence;

static const Licence licences[] = {
  { "open-meteo", "Open-Meteo data is licensed ", "CC BY 4.0",
    "https://creativecommons.org/licenses/by/4.0/", "" },
  { "met-no", "MET Norway data: ", "CC BY 4.0 / NLOD", "https://api.met.no/doc/License", "" },
  { "nws", "NOAA/National Weather Service data is US government work, credited as a courtesy",
    NULL, NULL, "" },
};

/* ------------------------------------------------------------------------ */
/* Instance                                                                 */
/* ------------------------------------------------------------------------ */

typedef struct {
  char *id;
  GtkWidget *sw;     /* owned by the row box, which is owned by rows_box */
  GtkWidget *status; /* same */
} Row;

typedef struct {
  char *id;
  WxSourceState state;
  int error_code;
  guint n_members;
} Entry;

enum { SIGNAL_PROVIDER_TOGGLED, SIGNAL_ABOUT_REQUESTED, N_SIGNALS };
static guint signals[N_SIGNALS];

struct _WxSources {
  GtkPopover parent_instance;
  WxRegistry *registry;      /* strong; NULL after dispose */
  gulong registry_handler;   /* 0 when not connected */
  GtkWidget *rows_box;       /* the rows' container; NULL after dispose */
  GArray *rows;              /* Row; emptied at dispose, freed at finalize */
  GArray *entries;           /* Entry; same */
  gboolean have_forecast;    /* a non-NULL forecast was set */
  gboolean syncing;          /* the popover itself is moving a switch */
  guint a11y_idle;           /* idle source id (see on_a11y_idle()), 0 when none */
};

/*
 * G_DEFINE_TYPE() below generates wx_sources_get_type() (registers the type once; thread-safe,
 * any thread) and the static instance/class trampolines that call wx_sources_class_init() and
 * wx_sources_init(). They own nothing; the documented functions that follow are the only
 * hand-written parts of the type.
 */
G_DEFINE_TYPE(WxSources, wx_sources, GTK_TYPE_POPOVER)

/* ------------------------------------------------------------------------ */
/* Helpers                                                                  */
/* ------------------------------------------------------------------------ */

/**
 * row_clear:
 * @data: (not nullable): a Row of the rows array.
 *
 * GDestroyNotify of the rows array: frees the id copy.
 *
 * Preconditions:
 *  - @data points to a Row whose id is NULL or owned by it; main thread.
 * Postconditions:
 *  - the id is freed; the widgets are not touched (their parents own them).
 * Thread affinity: main thread only.
 * Ownership: the Row is owned by the array; the widgets are not owned.
 */
static void
row_clear(gpointer data)
{
  g_free(((Row *)data)->id);
}

/**
 * entry_clear:
 * @data: (not nullable): an Entry of the entries array.
 *
 * GDestroyNotify of the entries array: frees the id copy.
 *
 * Preconditions:
 *  - @data points to an Entry whose id is NULL or owned by it; main thread.
 * Postconditions:
 *  - the id is freed.
 * Thread affinity: main thread only.
 * Ownership: the Entry is owned by the array.
 */
static void
entry_clear(gpointer data)
{
  g_free(((Entry *)data)->id);
}

/**
 * url_is_acceptable:
 * @url: (not nullable): the provider's attribution URL; NUL-terminated.
 *
 * Decides whether @url may become the href of a link (rules in wx-sources.h).
 *
 * Preconditions:
 *  - @url is NUL-terminated; wx_provider_get_attribution_url() never returns NULL (a NULL is
 *    treated as an unacceptable URL by the caller).
 * Postconditions:
 *  - nothing is modified; at most WX_SOURCE_URL_MAX + 1 bytes of @url are examined.
 * Thread affinity: main thread only (pure).
 * Ownership: @url is only read.
 *
 * Returns: TRUE iff @url is acceptable.
 */
static gboolean
url_is_acceptable(const char *url)
{
  static const char prefix[] = "https://";
  size_t prefix_len = sizeof prefix - 1;
  /* memchr: a longer string is rejected after WX_SOURCE_URL_MAX + 1 bytes were examined. */
  const char *nul = memchr(url, '\0', WX_SOURCE_URL_MAX + 1);
  size_t len = nul != NULL ? (size_t)(nul - url) : WX_SOURCE_URL_MAX + 1;
  if (len <= prefix_len || len > WX_SOURCE_URL_MAX || memcmp(url, prefix, prefix_len) != 0)
    return FALSE;
  g_autofree char *clean = wx_sanitize_text(url, WX_SOURCE_URL_MAX);
  if (strcmp(clean, url) != 0) /* invalid UTF-8 or a forbidden character */
    return FALSE;
  for (const char *p = url; *p != '\0'; p = g_utf8_next_char(p)) {
    gunichar c = g_utf8_get_char(p);
    if (c == '<' || c == '>' || c == '"' || g_unichar_isspace(c))
      return FALSE;
  }
  return TRUE;
}

/**
 * set_attribution:
 * @label: (not nullable): the attribution label.
 * @text: (nullable): the provider's attribution text (any bytes; NULL is "").
 * @url: (nullable): the provider's attribution URL (any bytes).
 *
 * Shows @text on @label, as a link to @url when @url is acceptable, as plain text otherwise;
 * hides the label when nothing is left of @text.
 *
 * Preconditions:
 *  - @label is a GtkLabel; the strings are NULL or NUL-terminated; main thread.
 * Postconditions:
 *  - the label shows the sanitised text (at most WX_SOURCE_TEXT_MAX bytes); use-markup is on
 *    exactly when the label holds a link; the label is visible iff there is text.
 * Thread affinity: main thread only.
 * Ownership: the strings are only read (copied by GTK); nothing is retained.
 */
static void
set_attribution(GtkWidget *label, const char *text, const char *url)
{
  g_autofree char *clean = wx_sanitize_text(text, WX_SOURCE_TEXT_MAX);
  gtk_widget_set_visible(label, clean[0] != '\0');
  if (url != NULL && url_is_acceptable(url)) {
    g_autofree char *esc_text = g_markup_escape_text(clean, -1);
    g_autofree char *esc_url = g_markup_escape_text(url, -1);
    g_autofree char *markup = g_strdup_printf("<a href=\"%s\">%s</a>", esc_url, esc_text);
    gtk_label_set_markup(GTK_LABEL(label), markup);
  } else {
    gtk_label_set_use_markup(GTK_LABEL(label), FALSE);
    gtk_label_set_text(GTK_LABEL(label), clean);
  }
}

/**
 * set_licence:
 * @label: (not nullable): the licence label.
 * @id: (not nullable): the provider id.
 *
 * Fills the licence label from the static table, or hides it when @id is not in the table.
 *
 * Preconditions:
 *  - @label is a GtkLabel; @id is NUL-terminated; main thread.
 * Postconditions:
 *  - for a table id the label shows its line (with use-markup when the entry has a link) and is
 *    visible; for any other id it is hidden and empty.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
set_licence(GtkWidget *label, const char *id)
{
  for (gsize i = 0; i < G_N_ELEMENTS(licences); i++) {
    const Licence *l = &licences[i];
    if (strcmp(l->id, id) != 0)
      continue;
    g_autofree char *before = g_markup_escape_text(l->before, -1);
    g_autofree char *after = g_markup_escape_text(l->after, -1);
    g_autofree char *link = NULL;
    if (l->url != NULL) {
      g_autofree char *text = g_markup_escape_text(l->link_text, -1);
      g_autofree char *url = g_markup_escape_text(l->url, -1);
      link = g_strdup_printf("<a href=\"%s\">%s</a>", url, text);
    }
    g_autofree char *markup = g_strconcat(before, link != NULL ? link : "", after, NULL);
    gtk_label_set_markup(GTK_LABEL(label), markup);
    gtk_widget_set_visible(label, TRUE);
    return;
  }
  gtk_label_set_text(GTK_LABEL(label), "");
  gtk_widget_set_visible(label, FALSE);
}

/**
 * error_reason:
 * @code: a WxError value, -1 or anything else.
 *
 * Maps the error code of a failed source to the short reason shown after "Could not load: ".
 *
 * Preconditions:
 *  - none (every int is accepted).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only (pure).
 * Ownership: the result is a static string.
 *
 * Returns: (transfer none): the reason; "unknown error" for -1 and for any other value.
 */
static const char *
error_reason(int code)
{
  switch (code) {
  case WX_ERROR_NETWORK:
    return "network error";
  case WX_ERROR_TIMEOUT:
    return "timed out";
  case WX_ERROR_HTTP:
    return "server error";
  case WX_ERROR_RATE_LIMITED:
    return "rate limited";
  case WX_ERROR_PARSE:
    return "unreadable answer";
  case WX_ERROR_NOT_FOUND:
    return "no data";
  case WX_ERROR_INVALID_ARG:
    return "invalid request";
  case WX_ERROR_UNSUPPORTED:
    return "not available";
  default:
    return "unknown error";
  }
}

/**
 * status_text:
 * @self: (not nullable): a live WxSources whose registry is set.
 * @id: (not nullable): the provider id.
 *
 * Computes the status line of a provider (rules in wx-sources.h).
 *
 * Preconditions:
 *  - @self->registry is non-NULL; main thread.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full): the status text; never NULL.
 */
static char *
status_text(WxSources *self, const char *id)
{
  if (!wx_registry_is_enabled(self->registry, id))
    return g_strdup("Turned off");
  if (!self->have_forecast)
    return g_strdup("No forecast loaded yet");
  for (guint i = 0; i < self->entries->len; i++) {
    const Entry *e = &g_array_index(self->entries, Entry, i);
    if (strcmp(e->id, id) != 0)
      continue;
    if (e->state == WX_SRC_OK)
      return g_strdup_printf("Used for this place (%u forecast %s)", e->n_members,
                             e->n_members == 1 ? "model" : "models");
    if (e->state == WX_SRC_FAILED)
      return g_strdup_printf("Could not load: %s", error_reason(e->error_code));
    break;
  }
  return g_strdup("Not used for this place");
}

/**
 * update_status:
 * @self: (not nullable): a live WxSources whose registry is set.
 * @row: (not nullable): one of its rows.
 *
 * Writes the current status line into the row's label.
 *
 * Preconditions:
 *  - @self->registry is non-NULL; @row belongs to @self->rows; main thread.
 * Postconditions:
 *  - the label shows status_text() of the row's provider.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
update_status(WxSources *self, const Row *row)
{
  g_autofree char *text = status_text(self, row->id);
  gtk_label_set_text(GTK_LABEL(row->status), text);
}

/**
 * set_switch:
 * @self: (not nullable): a live WxSources.
 * @sw: (not nullable): one of its switches.
 * @active: the position the switch must show.
 *
 * Moves a switch without it counting as a user toggle: while the move runs the "state-set"
 * handler ignores the change.
 *
 * Preconditions:
 *  - @sw is a GtkSwitch of @self; main thread.
 * Postconditions:
 *  - the switch's active flag and state both equal @active; nothing was emitted by @self.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
set_switch(WxSources *self, GtkWidget *sw, gboolean active)
{
  gboolean was_syncing = self->syncing;
  self->syncing = TRUE;
  gtk_switch_set_active(GTK_SWITCH(sw), active);
  gtk_switch_set_state(GTK_SWITCH(sw), active);
  self->syncing = was_syncing;
}

/**
 * on_a11y_idle:
 * @user_data: (not nullable): the WxSources the source was added for.
 *
 * Idle callback that republishes the accessible "checked" state of every switch from its real
 * position. Needed after a toggle that did not stick: gtk_switch_set_active() publishes the
 * state it was asked for after the "state-set" handlers have returned, which would leave the
 * accessible state of a switch that snapped back wrong.
 *
 * Preconditions:
 *  - added by on_switch_state_set() and removed at dispose, so @user_data is live and has a
 *    registry; main thread.
 * Postconditions:
 *  - every switch's accessible checked state equals gtk_switch_get_active(); the source id is
 *    cleared and the source is removed.
 * Thread affinity: main thread only (the default main context).
 * Ownership: nothing is retained.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_a11y_idle(gpointer user_data)
{
  WxSources *self = WX_SOURCES(user_data);
  self->a11y_idle = 0;
  for (guint i = 0; i < self->rows->len; i++) {
    GtkSwitch *sw = GTK_SWITCH(g_array_index(self->rows, Row, i).sw);
    gtk_accessible_update_state(GTK_ACCESSIBLE(sw), GTK_ACCESSIBLE_STATE_CHECKED,
                                gtk_switch_get_active(sw) ? GTK_ACCESSIBLE_TRISTATE_TRUE
                                                          : GTK_ACCESSIBLE_TRISTATE_FALSE,
                                -1);
  }
  return G_SOURCE_REMOVE;
}

/**
 * on_switch_state_set:
 * @sw: (not nullable): the switch whose state is being set.
 * @state: the requested state.
 * @user_data: (not nullable): the WxSources passed to g_signal_connect().
 *
 * "state-set" handler of every switch. A change the popover makes itself is left to the default
 * handler. A user toggle is announced with "provider-toggled" and the switch is then put back in
 * line with the registry, which is what keeps a refused toggle from sticking.
 *
 * Preconditions:
 *  - @sw is a descendant of @user_data and carries the provider id as ROW_ID_KEY data; main
 *    thread.
 * Postconditions:
 *  - for a user toggle on a live popover: "provider-toggled" was emitted once and the switch
 *    shows wx_registry_is_enabled() of the provider (the default handler does not run); if the
 *    switch ended up somewhere else than @state, on_a11y_idle() is scheduled (at most one
 *    pending).
 *  - for a change made by the popover itself, or after dispose: the default handler runs and
 *    nothing is emitted.
 * Thread affinity: main thread only.
 * Ownership: the popover is kept alive for the duration of the emission; the idle source is
 *   owned by the popover and removed at dispose.
 *
 * Returns: TRUE when the state was set here (stops the default handler), FALSE to let the
 *   default handler set @state.
 */
static gboolean
on_switch_state_set(GtkSwitch *sw, gboolean state, gpointer user_data)
{
  WxSources *self = WX_SOURCES(user_data);
  if (self->syncing || self->registry == NULL)
    return FALSE;
  const char *id = g_object_get_data(G_OBJECT(sw), ROW_ID_KEY);
  gboolean handled = FALSE;
  g_object_ref(self);
  g_signal_emit(self, signals[SIGNAL_PROVIDER_TOGGLED], 0, id, state);
  if (self->registry != NULL) {
    set_switch(self, GTK_WIDGET(sw), wx_registry_is_enabled(self->registry, id));
    handled = TRUE;
    if (gtk_switch_get_active(sw) != state && self->a11y_idle == 0)
      self->a11y_idle = g_idle_add(on_a11y_idle, self);
  }
  g_object_unref(self);
  return handled;
}

/**
 * on_about_clicked:
 * @button: the About button; unused.
 * @user_data: (not nullable): the WxSources passed to g_signal_connect().
 *
 * "clicked" handler of the About button: pops the popover down, then emits "about-requested".
 *
 * Preconditions:
 *  - @user_data is the button's ancestor popover; main thread.
 * Postconditions:
 *  - the popover is popped down and "about-requested" was emitted once.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
on_about_clicked(GtkButton *button, gpointer user_data)
{
  (void)button;
  WxSources *self = WX_SOURCES(user_data);
  gtk_popover_popdown(GTK_POPOVER(self));
  g_signal_emit(self, signals[SIGNAL_ABOUT_REQUESTED], 0);
}

/**
 * make_label:
 * @name: (not nullable): widget name and style class of the label.
 *
 * Creates a left-aligned wrapping label bounded to WX_SOURCES_MAX_WIDTH_CHARS characters.
 *
 * Preconditions:
 *  - GTK is initialised; @name is NUL-terminated; main thread.
 * Postconditions:
 *  - the label has the name and the class, wraps by word then by character, requests at most
 *    WX_SOURCES_MAX_WIDTH_CHARS characters of width and has no text.
 * Thread affinity: main thread only.
 * Ownership: @name is copied; the caller owns the new, floating widget.
 *
 * Returns: (transfer floating): the label; never NULL.
 */
static GtkWidget *
make_label(const char *name)
{
  GtkWidget *label = gtk_label_new("");
  gtk_widget_set_name(label, name);
  gtk_widget_add_css_class(label, name);
  gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
  gtk_label_set_wrap(GTK_LABEL(label), TRUE);
  gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
  gtk_label_set_max_width_chars(GTK_LABEL(label), WX_SOURCES_MAX_WIDTH_CHARS);
  return label;
}

/**
 * add_row:
 * @self: (not nullable): a live WxSources whose registry is set.
 * @provider: (not nullable): the provider to list; borrowed for the call.
 *
 * Builds the row of @provider and appends it below the existing rows.
 *
 * Preconditions:
 *  - @provider is registered in @self->registry (so wx_provider_get_id() is non-NULL; else: critical
 *    and no row is built) and not listed yet; main thread.
 * Postconditions:
 *  - the row exists with its switch off and its status empty (sync_all() fills both); the
 *    switch is connected to on_switch_state_set(); no pointer to @provider is kept.
 * Thread affinity: main thread only.
 * Ownership: the widgets are owned by rows_box; the row array owns the id copy.
 */
static void
add_row(WxSources *self, WxProvider *provider)
{
  const char *id = wx_provider_get_id(provider);
  g_return_if_fail(id != NULL); /* a registered provider always has an id */
  g_autofree char *name = wx_sanitize_text(wx_provider_get_name(provider), WX_SOURCE_TEXT_MAX);
  if (name[0] == '\0') {
    g_free(name);
    name = g_strdup(id);
  }

  GtkWidget *row_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_set_name(row_box, "wx-sources-row");
  gtk_widget_add_css_class(row_box, "wx-sources-row");

  GtkWidget *sw = gtk_switch_new();
  gtk_widget_set_name(sw, "wx-sources-switch");
  gtk_widget_set_valign(sw, GTK_ALIGN_START);
  g_autofree char *accessible_label = g_strdup_printf("Use %s", name);
  gtk_accessible_update_property(GTK_ACCESSIBLE(sw), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 accessible_label, -1);
  g_object_set_data_full(G_OBJECT(sw), ROW_ID_KEY, g_strdup(id), g_free);
  g_signal_connect(sw, "state-set", G_CALLBACK(on_switch_state_set), self);
  gtk_box_append(GTK_BOX(row_box), sw);

  GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  gtk_widget_set_hexpand(texts, TRUE);
  GtkWidget *name_label = make_label("wx-sources-name");
  gtk_label_set_text(GTK_LABEL(name_label), name);
  GtkWidget *status = make_label("wx-sources-status");
  gtk_widget_add_css_class(status, "dim-label");
  GtkWidget *attribution = make_label("wx-sources-attribution");
  set_attribution(attribution, wx_provider_get_attribution(provider),
                  wx_provider_get_attribution_url(provider));
  GtkWidget *licence = make_label("wx-sources-licence");
  gtk_widget_add_css_class(licence, "dim-label");
  set_licence(licence, id);
  gtk_box_append(GTK_BOX(texts), name_label);
  gtk_box_append(GTK_BOX(texts), status);
  gtk_box_append(GTK_BOX(texts), attribution);
  gtk_box_append(GTK_BOX(texts), licence);
  gtk_box_append(GTK_BOX(row_box), texts);

  gtk_box_append(GTK_BOX(self->rows_box), row_box);
  Row row = { g_strdup(id), sw, status };
  g_array_append_val(self->rows, row);
}

/**
 * sync_all:
 * @self: (not nullable): a WxSources whose registry is set.
 *
 * Brings the popover in line with the registry: appends the rows of providers that were added
 * since the last call, then re-synchronises every switch and status line.
 *
 * Preconditions:
 *  - @self->registry is non-NULL (the callers are wx_sources_new() and the registry's "changed"
 *    handler, which is disconnected before the registry is released); main thread.
 * Postconditions:
 *  - one row per listed provider (the registry lists at most WX_REGISTRY_MAX_PROVIDERS), every
 *    switch equals the registry's flag, every status line is current; "provider-toggled" was
 *    not emitted.
 * Thread affinity: main thread only.
 * Ownership: the provider list is a temporary container and is released here.
 */
static void
sync_all(WxSources *self)
{
  g_autoptr(GPtrArray) providers = wx_registry_list_providers(self->registry);
  for (guint i = self->rows->len; i < providers->len; i++)
    add_row(self, g_ptr_array_index(providers, i));
  for (guint i = 0; i < self->rows->len; i++) {
    const Row *row = &g_array_index(self->rows, Row, i);
    set_switch(self, row->sw, wx_registry_is_enabled(self->registry, row->id));
    update_status(self, row);
  }
}

/**
 * on_registry_changed:
 * @registry: the registry; unused.
 * @user_data: (not nullable): the WxSources passed to g_signal_connect().
 *
 * "changed" handler of the registry: re-synchronises the popover.
 *
 * Preconditions:
 *  - connected by wx_sources_new() and disconnected at dispose, so @user_data is live; main
 *    thread.
 * Postconditions:
 *  - see sync_all().
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
on_registry_changed(WxRegistry *registry, gpointer user_data)
{
  (void)registry;
  sync_all(WX_SOURCES(user_data));
}

/* ------------------------------------------------------------------------ */
/* GObject                                                                  */
/* ------------------------------------------------------------------------ */

/**
 * wx_sources_dispose:
 * @object: (not nullable): the WxSources being disposed.
 *
 * GObject dispose (may run more than once): disconnects from the registry, releases it and
 * forgets rows and forecast data, then chains up (which disposes the child widgets).
 *
 * Preconditions:
 *  - called by GObject (never directly), on the main thread.
 * Postconditions:
 *  - no handler on the registry, no reference to it, no row and no forecast data remain; the
 *    containers stay allocated until finalize, so later calls are safe no-ops.
 * Thread affinity: main thread only.
 * Ownership: @object is owned by GObject; the popover's reference on the registry is released.
 */
static void
wx_sources_dispose(GObject *object)
{
  WxSources *self = WX_SOURCES(object);
  if (self->registry_handler != 0) {
    g_signal_handler_disconnect(self->registry, self->registry_handler);
    self->registry_handler = 0;
  }
  g_clear_handle_id(&self->a11y_idle, g_source_remove);
  g_clear_object(&self->registry);
  self->rows_box = NULL;
  g_array_set_size(self->rows, 0);
  g_array_set_size(self->entries, 0);
  self->have_forecast = FALSE;
  G_OBJECT_CLASS(wx_sources_parent_class)->dispose(object);
}

/**
 * wx_sources_finalize:
 * @object: (not nullable): the WxSources being finalized.
 *
 * GObject finalize: frees the row and entry arrays and chains up.
 *
 * Preconditions:
 *  - called once by GObject after dispose (never directly), on the main thread.
 * Postconditions:
 *  - the arrays are freed.
 * Thread affinity: main thread only.
 * Ownership: @object is owned by GObject; the arrays are owned by the popover.
 */
static void
wx_sources_finalize(GObject *object)
{
  WxSources *self = WX_SOURCES(object);
  g_clear_pointer(&self->rows, g_array_unref);
  g_clear_pointer(&self->entries, g_array_unref);
  G_OBJECT_CLASS(wx_sources_parent_class)->finalize(object);
}

/**
 * wx_sources_class_init:
 * @klass: (not nullable): the class structure being initialised, passed by GObject.
 *
 * GObject class initialiser: installs dispose/finalize and registers "provider-toggled" and
 * "about-requested".
 *
 * Preconditions:
 *  - called once by GObject during type registration (never called directly).
 * Postconditions:
 *  - the class vfuncs are set and signals[] holds the two signal ids.
 * Thread affinity: main thread only (runs once, when the type is first used).
 * Ownership: @klass is owned by the type system; nothing is allocated except the signals.
 */
static void
wx_sources_class_init(WxSourcesClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS(klass);
  object_class->dispose = wx_sources_dispose;
  object_class->finalize = wx_sources_finalize;

  signals[SIGNAL_PROVIDER_TOGGLED] =
      g_signal_new("provider-toggled", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL,
                   NULL, NULL, G_TYPE_NONE, 2, G_TYPE_STRING, G_TYPE_BOOLEAN);
  signals[SIGNAL_ABOUT_REQUESTED] =
      g_signal_new("about-requested", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL,
                   NULL, NULL, G_TYPE_NONE, 0);
}

/**
 * wx_sources_init:
 * @self: (not nullable): the new instance, zero-initialised by GObject.
 *
 * GObject instance initialiser: creates the arrays and the fixed widgets (title, empty rows
 * box, note, About button). The raw @self given to the handlers is safe: the widgets are
 * descendants of @self and are disposed with it.
 *
 * Preconditions:
 *  - called once by GObject while the instance is created (never directly); GTK is initialised
 *    with a display; main thread.
 * Postconditions:
 *  - the arrays and all fixed widgets exist; the registry is still NULL (wx_sources_new() sets
 *    it) and there is no row.
 * Thread affinity: main thread only.
 * Ownership: @self is owned by GObject; the widgets are owned by the popover.
 */
static void
wx_sources_init(WxSources *self)
{
  self->rows = g_array_new(FALSE, TRUE, sizeof(Row));
  g_array_set_clear_func(self->rows, row_clear);
  self->entries = g_array_new(FALSE, TRUE, sizeof(Entry));
  g_array_set_clear_func(self->entries, entry_clear);
  gtk_widget_add_css_class(GTK_WIDGET(self), "wx-sources");

  GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_start(root, 12);
  gtk_widget_set_margin_end(root, 12);
  gtk_widget_set_margin_top(root, 12);
  gtk_widget_set_margin_bottom(root, 12);
  gtk_popover_set_child(GTK_POPOVER(self), root);

  GtkWidget *title = make_label("wx-sources-title");
  gtk_label_set_text(GTK_LABEL(title), "Data sources");
  gtk_box_append(GTK_BOX(root), title);

  self->rows_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_box_append(GTK_BOX(root), self->rows_box);

  GtkWidget *note = make_label("wx-sources-note");
  gtk_label_set_text(GTK_LABEL(note), NOTE_TEXT);
  gtk_box_append(GTK_BOX(root), note);

  GtkWidget *about = gtk_button_new_with_label("About Weather");
  gtk_widget_set_name(about, "wx-sources-about");
  gtk_widget_add_css_class(about, "flat");
  g_signal_connect(about, "clicked", G_CALLBACK(on_about_clicked), self);
  gtk_box_append(GTK_BOX(root), about);
}

/* ------------------------------------------------------------------------ */
/* Public API                                                               */
/* ------------------------------------------------------------------------ */

/* Documented in wx-sources.h. */
GtkWidget *
wx_sources_new(WxRegistry *registry)
{
  g_return_val_if_fail(WX_IS_REGISTRY(registry), NULL);
  WxSources *self = g_object_new(WX_TYPE_SOURCES, NULL);
  self->registry = g_object_ref(registry);
  self->registry_handler =
      g_signal_connect(registry, "changed", G_CALLBACK(on_registry_changed), self);
  sync_all(self);
  return GTK_WIDGET(self);
}

/* Documented in wx-sources.h. */
void
wx_sources_set_forecast(WxSources *self, const WxForecast *forecast)
{
  g_return_if_fail(WX_IS_SOURCES(self));
  if (self->registry == NULL)
    return;
  g_array_set_size(self->entries, 0);
  self->have_forecast = forecast != NULL;
  if (forecast != NULL) {
    guint n = 0;
    const WxSourceStatus *sources = wx_forecast_get_sources(forecast, &n);
    for (guint i = 0; i < n; i++) {
      Entry e = { g_strdup(sources[i].provider_id), sources[i].state, sources[i].error_code,
                  sources[i].n_members };
      g_array_append_val(self->entries, e);
    }
  }
  for (guint i = 0; i < self->rows->len; i++)
    update_status(self, &g_array_index(self->rows, Row, i));
}
