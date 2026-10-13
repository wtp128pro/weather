/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * test-support.h - harness shared by the GUI tests of this directory
 * (test-window.c, test-picker.c, test-sources.c, test-detail.c). TEST-ONLY: never part of the
 * application. Every function is static inline, so a test that does not use
 * one pays nothing.
 *
 * What it guarantees (all of it BEFORE GTK, GLib's user-directory cache or any
 * GIO extension point is touched, which is why wxt_setup() is the first call
 * of main()):
 *  - a private temp root; XDG_CONFIG_HOME / XDG_CACHE_HOME / XDG_DATA_HOME /
 *    XDG_STATE_HOME / XDG_RUNTIME_DIR point below it, so nothing a test (or
 *    GTK, dconf, Mesa, fontconfig) writes can reach the user's real
 *    directories. If any part of the setup fails the process aborts: a test
 *    must never run against the real XDG tree;
 *  - GTK_A11Y=none, GTK_IM_MODULE=simple, GSETTINGS_BACKEND=memory,
 *    GDK_BACKEND=x11 (Xvfb; never a live compositor), a bare GTK theme (the
 *    tests do not depend on the installed one), GIO_USE_NETWORK_MONITOR=base
 *    (the base monitor reports a network as available and does not look at
 *    the host's, so the tests are deterministic) and GIO_USE_PROXY_RESOLVER=
 *    dummy; DBUS_SESSION_BUS_ADDRESS names a socket that does not exist, so
 *    GApplication never reaches the desktop's session bus;
 *  - the temp root is removed recursively by the process that created it, at a normal exit, at
 *    the skip exit (no display) and on SIGABRT/SIGSEGV/SIGTERM/SIGINT (a failing assertion
 *    aborts), using only async-signal-safe calls in the handler. A g_test_trap_subprocess()
 *    child borrows the root of its parent (through the environment) and removes nothing, so no
 *    test run leaves a directory in $TMPDIR even when GLib ends the child with _exit();
 *  - fatal log messages (wxt_init_gtk(), g_log_set_always_fatal() and g_log_set_fatal_mask()):
 *    a CRITICAL of any log domain aborts the test; a WARNING or CRITICAL of the application's own
 *    log domain "weather" (the code under test and the test code, built with
 *    -DG_LOG_DOMAIN="weather") aborts it. A WARNING of another domain (GLib, GIO, GTK, Mesa, ...)
 *    is printed and does not abort: those depend on the host (for example GApplication's note
 *    that an application was destroyed without g_application_run(), which the fixtures cause
 *    because they end an application through its "shutdown" vfunc), so they cannot decide a
 *    test. A message that a test expects with g_test_expect_message() is checked and never aborts.
 *    test-sources.c tests this policy.
 */
#ifndef WX_TEST_SUPPORT_H
#define WX_TEST_SUPPORT_H

#define _GNU_SOURCE /* syscall() for the signal-safe tree removal */
#include <fcntl.h>
#include <glib/gstdio.h>
#include <gtk/gtk.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/* Recursive removal (async-signal-safe)                              */
/* ------------------------------------------------------------------ */

#define WXT_RM_MAX_DEPTH 32
#define WXT_RM_PASSES 4

struct wxt_dirent64 { /* the kernel's linux_dirent64 */
  guint64 d_ino;
  gint64 d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[];
};

typedef union {
  struct wxt_dirent64 align_as;
  char bytes[2048];
} WxtDirentBuf;

/* Removes everything below the directory descriptor @dfd. Works relative to descriptors, never follows
 * a symlink (a link is unlinked itself) and never goes up, so it cannot leave the root. */
static inline void
wxt_remove_children(int dfd, int depth)
{
  WxtDirentBuf buf;
  for (int pass = 0; pass < WXT_RM_PASSES; pass++) {
    gboolean removed = FALSE;
    lseek(dfd, 0, SEEK_SET);
    long n;
    while ((n = syscall(SYS_getdents64, dfd, buf.bytes, sizeof buf.bytes)) > 0) {
      for (long off = 0; off < n;) {
        unsigned short reclen;
        memcpy(&reclen, buf.bytes + off + offsetof(struct wxt_dirent64, d_reclen), sizeof reclen);
        const char *name = buf.bytes + off + offsetof(struct wxt_dirent64, d_name);
        off += reclen;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0')))
          continue;
        struct stat st;
        if (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0)
          continue;
        if (S_ISDIR(st.st_mode)) {
          int child = depth < WXT_RM_MAX_DEPTH
                          ? openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                          : -1;
          if (child >= 0) {
            wxt_remove_children(child, depth + 1);
            close(child);
          }
          removed |= unlinkat(dfd, name, AT_REMOVEDIR) == 0;
        } else {
          removed |= unlinkat(dfd, name, 0) == 0;
        }
      }
    }
    if (!removed)
      break;
  }
}

/* Removes @root and everything below it; a symlink inside is removed, not followed. */
static inline void
wxt_remove_tree(const char *root)
{
  int fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    return;
  wxt_remove_children(fd, 0);
  close(fd);
  rmdir(root);
}

/* ------------------------------------------------------------------ */
/* Environment                                                        */
/* ------------------------------------------------------------------ */

/* The temp root of the process, "" before wxt_setup(); written once, before any signal can matter. */
static char wxt_root[4096];
/* Whether this process created (and so removes) the root. A g_test_trap_subprocess() child re-runs
 * main() and borrows its parent's root instead: GLib ends a subprocess that hit a fatal log message
 * with _exit(), which skips atexit() and the signal handlers, so a root of its own would leak. */
static gboolean wxt_owns_root;

#define WXT_OWNER_ROOT_VAR "WXT_OWNER_ROOT"
#define WXT_OWNER_PID_VAR "WXT_OWNER_PID"

static inline void
wxt_cleanup(void)
{
  if (wxt_owns_root && wxt_root[0] != '\0')
    wxt_remove_tree(wxt_root);
}

static inline void
wxt_on_fatal_signal(int sig)
{
  wxt_cleanup();
  signal(sig, SIG_DFL);
  raise(sig);
}

/* Creates the temp root and points every environment variable the stack consults at it. Must be the
 * first call of main(). Aborts when anything fails. */
static inline void
wxt_setup(const char *template_name)
{
  /* A test subprocess (our direct child, started by g_test_trap_subprocess() with the environment
   * of the owner) reuses the owner's root, which the owner removes. */
  const char *owner_root = g_getenv(WXT_OWNER_ROOT_VAR);
  const char *owner_pid = g_getenv(WXT_OWNER_PID_VAR);
  g_autofree char *own_pid = g_strdup_printf("%ld", (long)getppid());
  g_autofree char *root = NULL;
  if (owner_root != NULL && owner_pid != NULL && strcmp(owner_pid, own_pid) == 0 &&
      g_file_test(owner_root, G_FILE_TEST_IS_DIR)) {
    root = g_strdup(owner_root);
    wxt_owns_root = FALSE;
  } else {
    root = g_dir_make_tmp(template_name, NULL);
    wxt_owns_root = TRUE;
  }
  if (root == NULL || strlen(root) >= sizeof wxt_root) {
    g_printerr("test setup failed: cannot create the temp root\n");
    abort();
  }
  g_strlcpy(wxt_root, root, sizeof wxt_root);
  if (wxt_owns_root) {
    g_autofree char *me = g_strdup_printf("%ld", (long)getpid());
    g_setenv(WXT_OWNER_ROOT_VAR, root, TRUE);
    g_setenv(WXT_OWNER_PID_VAR, me, TRUE);
    atexit(wxt_cleanup);
    signal(SIGABRT, wxt_on_fatal_signal);
    signal(SIGSEGV, wxt_on_fatal_signal);
    signal(SIGTERM, wxt_on_fatal_signal);
    signal(SIGINT, wxt_on_fatal_signal);
  }

  g_autofree char *theme_dir = g_build_filename(root, "themes", "Bare", "gtk-4.0", NULL);
  g_autofree char *css = g_build_filename(theme_dir, "gtk.css", NULL);
  g_autofree char *cfg = g_build_filename(root, "config", NULL);
  g_autofree char *cache = g_build_filename(root, "cache", NULL);
  g_autofree char *state = g_build_filename(root, "state", NULL);
  g_autofree char *run = g_build_filename(root, "run", NULL);
  if (g_mkdir_with_parents(theme_dir, 0700) != 0 || g_mkdir_with_parents(cfg, 0700) != 0 ||
      g_mkdir_with_parents(cache, 0700) != 0 || g_mkdir_with_parents(state, 0700) != 0 ||
      g_mkdir_with_parents(run, 0700) != 0 ||
      !g_file_set_contents(css, "window { color: #101010; background-color: #ffffff; }\n", -1,
                           NULL)) {
    g_printerr("test setup failed: cannot create the XDG tree below %s\n", root);
    wxt_cleanup();
    abort();
  }
  g_setenv("XDG_DATA_HOME", root, TRUE);
  g_setenv("XDG_CONFIG_HOME", cfg, TRUE);
  g_setenv("XDG_CACHE_HOME", cache, TRUE);
  g_setenv("XDG_STATE_HOME", state, TRUE);
  g_setenv("XDG_RUNTIME_DIR", run, TRUE);
  g_setenv("MESA_SHADER_CACHE_DIR", cache, TRUE);
  g_setenv("__GL_SHADER_DISK_CACHE_PATH", cache, TRUE);
  g_setenv("GSETTINGS_BACKEND", "memory", TRUE);
  g_setenv("GTK_THEME", "Bare", TRUE);
  g_setenv("GTK_A11Y", "none", TRUE);
  g_setenv("GTK_IM_MODULE", "simple", TRUE);
  g_setenv("GDK_BACKEND", "x11", TRUE);
  g_setenv("GIO_USE_NETWORK_MONITOR", "base", TRUE);
  g_setenv("GIO_USE_PROXY_RESOLVER", "dummy", TRUE);
  /* No session bus: GApplication then runs unique-less in the process instead of talking to the
   * desktop's bus (and the tests can start many applications with the same id in turn). */
  g_autofree char *no_bus = g_strdup_printf("unix:path=%s/no-bus", root);
  g_setenv("DBUS_SESSION_BUS_ADDRESS", no_bus, TRUE);
  /* The environment really took effect: GLib resolves the user dirs from it (and caches them now). */
  g_assert(g_str_has_prefix(g_get_user_config_dir(), root));
  g_assert(g_str_has_prefix(g_get_user_cache_dir(), root));
}

/* Initialises GTK on the X11 backend after g_test_init(). Returns FALSE (the caller returns 77) when
 * there is no display; the temp root is removed then. */
static inline gboolean
wxt_init_gtk(void)
{
  g_log_set_always_fatal(G_LOG_FATAL_MASK | G_LOG_LEVEL_CRITICAL);
  g_log_set_fatal_mask("weather", G_LOG_FATAL_MASK | G_LOG_LEVEL_CRITICAL | G_LOG_LEVEL_WARNING);
  gdk_set_allowed_backends("x11");
  if (!gtk_init_check()) {
    g_print("1..0 # SKIP no display\n");
    wxt_cleanup();
    return FALSE;
  }
  g_assert_true(g_str_has_prefix(G_OBJECT_TYPE_NAME(gdk_display_get_default()), "GdkX11"));
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Main loop helpers                                                  */
/* ------------------------------------------------------------------ */

#define WXT_DEADLINE_US (15 * G_USEC_PER_SEC)

/* Runs the main loop for @ms milliseconds (used to show the absence of events). */
static inline void
wxt_pump_ms(guint ms)
{
  gint64 end = g_get_monotonic_time() + (gint64)ms * 1000;
  GMainContext *ctx = g_main_context_default();
  /* The deadline is re-checked after EVERY dispatched iteration: a periodic source that is due again
   * at each iteration (a slow host, valgrind) must not keep the loop from returning. */
  while (g_get_monotonic_time() < end) {
    if (!g_main_context_iteration(ctx, FALSE))
      g_usleep(2000);
  }
}

/* Runs the main loop until nothing is pending (one idle round). */
static inline void
wxt_pump_idle(void)
{
  for (int i = 0; i < 50 && g_main_context_iteration(NULL, FALSE); i++)
    ;
}

/* Waits until the display server has handled everything sent to it so far and dispatches the
 * events it answered with: a window state change (map, unmap) that is already on its way is seen
 * here instead of arriving in the middle of the next step of a test. */
static inline void
wxt_settle_display(void)
{
  gdk_display_sync(gdk_display_get_default());
  wxt_pump_idle();
}

/* Pumps until @cond holds or the deadline passes; then asserts @cond. */
#define WXT_WAIT_FOR(cond)                                                   \
  G_STMT_START                                                               \
  {                                                                          \
    gint64 wf_end_ = g_get_monotonic_time() + WXT_DEADLINE_US;               \
    while (!(cond) && g_get_monotonic_time() < wf_end_) {                    \
      if (!g_main_context_iteration(NULL, FALSE))                            \
        g_usleep(1000);                                                      \
    }                                                                        \
    g_assert_true(cond);                                                     \
  }                                                                          \
  G_STMT_END

/* ------------------------------------------------------------------ */
/* Widget lookup by widget name                                       */
/* ------------------------------------------------------------------ */

/* First descendant of @root (depth first, @root included) whose widget name is @name, or NULL. */
static inline GtkWidget *
wxt_find_named(GtkWidget *root, const char *name)
{
  if (strcmp(gtk_widget_get_name(root), name) == 0)
    return root;
  for (GtkWidget *c = gtk_widget_get_first_child(root); c != NULL;
       c = gtk_widget_get_next_sibling(c)) {
    GtkWidget *found = wxt_find_named(c, name);
    if (found != NULL)
      return found;
  }
  return NULL;
}

/* Appends every descendant of @root (@root included) named @name to @out. */
static inline void
wxt_collect_named(GtkWidget *root, const char *name, GPtrArray *out)
{
  if (strcmp(gtk_widget_get_name(root), name) == 0)
    g_ptr_array_add(out, root);
  for (GtkWidget *c = gtk_widget_get_first_child(root); c != NULL;
       c = gtk_widget_get_next_sibling(c))
    wxt_collect_named(c, name, out);
}

/* Text of the GtkLabel named @name below @root; "" when there is none. Asserts the widget is a label. */
static inline const char *
wxt_label_text(GtkWidget *root, const char *name)
{
  GtkWidget *w = wxt_find_named(root, name);
  if (w == NULL)
    return "";
  g_assert_true(GTK_IS_LABEL(w));
  return gtk_label_get_text(GTK_LABEL(w));
}

/* Whether the widget named @name below @root exists and is mapped (visible on screen). */
static inline gboolean
wxt_is_mapped(GtkWidget *root, const char *name)
{
  GtkWidget *w = wxt_find_named(root, name);
  return w != NULL && gtk_widget_get_mapped(w);
}

#endif /* WX_TEST_SUPPORT_H */
