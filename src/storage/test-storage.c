/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * test-storage.c - offline tests of the storage module: wx-fileio, WxPlaces,
 * WxSettings and WxCache.
 *
 * Every test works in a private temporary directory (or never touches the
 * disk); nothing reads or writes the real XDG directories. The default-path
 * tests only compare path strings. Time never matters except for the age
 * reported by the cache, which is checked with generous bounds.
 */
#define _XOPEN_SOURCE 700 /* mkfifo(), truncate(), fchmod(), mmap() under -std=c11 */
#define _DEFAULT_SOURCE   /* MAP_ANONYMOUS */

#undef _FORTIFY_SOURCE /* the fault-injection wrappers below redefine read() and write() */
#include <fcntl.h>
#include <glib/gstdio.h>
#include <json-glib/json-glib.h>
#include <math.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "wx-cache.h"
#include "wx-fileio.h"
#include "wx-places.h"
#include <errno.h>
#include <sys/syscall.h>
#include "wx-text.h"
#include "wx-settings.h"
#include "wx-store-json.h"

/* ------------------------------------------------------------------------ */
/* Fault injection for the system calls of wx-fileio                         */
/* ------------------------------------------------------------------------ */

/*
 * The test executable defines write(), read(), fsync(), close() and fstat()
 * itself. The linker resolves the calls of the static storage library to these
 * definitions, so a test can make one call fail (or be interrupted, or write
 * a single byte) and prove that wx-fileio reports the error, removes its
 * temporary file and leaves the target intact. Every wrapper forwards to the
 * kernel with syscall() when no fault is armed, so nothing else changes. The
 * plan is thread-local: a worker thread of an unrelated test is never hit.
 */
typedef struct {
  int write_eintr;    /* the next n write() calls fail with EINTR            */
  int write_one_byte; /* the next n write() calls write at most one byte    */
  int write_errno;    /* every write() fails with this errno when non-zero  */
  int fsync_errno;    /* every fsync() fails with this errno when non-zero  */
  int close_errno;    /* the next close() closes the fd, then reports this  */
  int read_eintr;     /* the next n read() calls fail with EINTR            */
  int read_errno;     /* every read() fails with this errno when non-zero   */
  int fstat_errno;    /* every fstat() fails with this errno when non-zero  */
} Faults;

static _Thread_local Faults faults;

ssize_t
write(int fd, const void *buf, size_t n)
{
  if (faults.write_eintr > 0) {
    faults.write_eintr--;
    errno = EINTR;
    return -1;
  }
  if (faults.write_errno != 0) {
    errno = faults.write_errno;
    return -1;
  }
  if (faults.write_one_byte > 0 && n > 1) {
    faults.write_one_byte--;
    n = 1;
  }
  return (ssize_t)syscall(SYS_write, fd, buf, n);
}

ssize_t
read(int fd, void *buf, size_t n)
{
  if (faults.read_eintr > 0) {
    faults.read_eintr--;
    errno = EINTR;
    return -1;
  }
  if (faults.read_errno != 0) {
    errno = faults.read_errno;
    return -1;
  }
  return (ssize_t)syscall(SYS_read, fd, buf, n);
}

int
fsync(int fd)
{
  if (faults.fsync_errno != 0) {
    errno = faults.fsync_errno;
    return -1;
  }
  return (int)syscall(SYS_fsync, fd);
}

int
close(int fd)
{
  int rc = (int)syscall(SYS_close, fd);
  if (rc == 0 && faults.close_errno != 0) {
    int e = faults.close_errno;
    faults.close_errno = 0;
    errno = e;
    return -1;
  }
  return rc;
}

int
fstat(int fd, struct stat *st)
{
  if (faults.fstat_errno != 0) {
    errno = faults.fstat_errno;
    return -1;
  }
  return (int)syscall(SYS_fstat, fd, st);
}

/* ------------------------------------------------------------------------ */
/* Fixture: a private temp directory                                        */
/* ------------------------------------------------------------------------ */

typedef struct {
  char *dir;
} Fixture;

static void
fixture_set_up(Fixture *f, gconstpointer unused)
{
  (void)unused;
  GError *err = NULL;
  f->dir = g_dir_make_tmp("wx-storage-XXXXXX", &err);
  g_assert_no_error(err);
}

static void
rm_rf(const char *path)
{
  GStatBuf st;
  if (g_lstat(path, &st) != 0)
    return;
  if (S_ISDIR(st.st_mode)) {
    (void)g_chmod(path, 0700);
    GDir *d = g_dir_open(path, 0, NULL);
    if (d != NULL) {
      const char *n;
      while ((n = g_dir_read_name(d)) != NULL) {
        char *child = g_build_filename(path, n, NULL);
        rm_rf(child);
        g_free(child);
      }
      g_dir_close(d);
    }
  }
  (void)g_remove(path);
}

static void
fixture_tear_down(Fixture *f, gconstpointer unused)
{
  (void)unused;
  rm_rf(f->dir);
  g_free(f->dir);
}

static char *
path_in(Fixture *f, const char *name)
{
  return g_build_filename(f->dir, name, NULL);
}

static void
put_file(const char *path, const char *data, gsize len)
{
  GError *err = NULL;
  g_assert_true(g_file_set_contents(path, data, (gssize)len, &err));
  g_assert_no_error(err);
}

static void
put_text(const char *path, const char *text)
{
  put_file(path, text, strlen(text));
}

/* Number of directory entries; used to prove no temp file is left behind. */
static guint
count_files(const char *dir)
{
  guint n = 0;
  GDir *d = g_dir_open(dir, 0, NULL);
  g_assert_nonnull(d);
  while (g_dir_read_name(d) != NULL)
    n++;
  g_dir_close(d);
  return n;
}

/* chmod 0500 the directory; returns FALSE (and skips) when that cannot block writes (root). */
static gboolean
make_read_only(const char *dir)
{
  g_assert_cmpint(g_chmod(dir, 0500), ==, 0);
  if (g_access(dir, W_OK) == 0) {
    (void)g_chmod(dir, 0700);
    g_test_skip("directory permissions are not enforced for this user");
    return FALSE;
  }
  return TRUE;
}

static unsigned
file_mode(const char *path)
{
  GStatBuf st;
  g_assert_cmpint(g_stat(path, &st), ==, 0);
  return (unsigned)(st.st_mode & 07777);
}

/* ------------------------------------------------------------------------ */
/* fileio                                                                   */
/* ------------------------------------------------------------------------ */

static void
test_fileio_roundtrip(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "a/b/c/data.bin"); /* parents are created */
  const char data[] = {'h', 'i', '\0', 'x', '\n'};      /* embedded NUL */
  GError *err = NULL;
  g_assert_true(wx_file_write_atomic(path, data, sizeof data, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(file_mode(path), ==, 0600);

  g_autofree char *got = NULL;
  gsize len = 99;
  g_assert_true(wx_file_read_bounded(path, 1024, &got, &len, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(len, ==, sizeof data);
  g_assert_cmpmem(got, len, data, sizeof data);
  g_assert_cmpint(got[len], ==, '\0');

  /* Overwrite with different (shorter) content: the old bytes must not remain. */
  g_assert_true(wx_file_write_atomic(path, "z", 1, &err));
  g_assert_no_error(err);
  g_free(got);
  g_assert_true(wx_file_read_bounded(path, 1024, &got, &len, &err));
  g_assert_cmpuint(len, ==, 1);
  g_assert_cmpstr(got, ==, "z");

  g_autofree char *dir = g_path_get_dirname(path);
  g_assert_cmpuint(count_files(dir), ==, 1); /* no temp file left */

  /* Empty content is valid. */
  g_assert_true(wx_file_write_atomic(path, NULL, 0, &err));
  g_free(got);
  g_assert_true(wx_file_read_bounded(path, 0, &got, &len, &err));
  g_assert_cmpuint(len, ==, 0);
}

static void
test_fileio_read_limits(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "r.txt");
  put_text(path, "0123456789");

  g_autofree char *got = NULL;
  gsize len = 0;
  GError *err = NULL;
  g_assert_true(wx_file_read_bounded(path, 10, &got, &len, &err)); /* exactly at the limit */
  g_assert_cmpuint(len, ==, 10);
  g_free(got);

  g_assert_false(wx_file_read_bounded(path, 9, &got, &len, &err));
  g_assert_error(err, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE);
  g_assert_null(got);
  g_assert_cmpuint(len, ==, 0);
  g_clear_error(&err);

  g_autofree char *missing = path_in(f, "missing.txt");
  g_assert_false(wx_file_read_bounded(missing, 10, &got, &len, &err));
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_NOENT);
  g_clear_error(&err);

  /* A directory and a FIFO are not regular files; the FIFO must not block. */
  g_assert_false(wx_file_read_bounded(f->dir, 10, &got, &len, &err));
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_INVAL);
  g_clear_error(&err);
  g_autofree char *fifo = path_in(f, "fifo");
  g_assert_cmpint(mkfifo(fifo, 0600), ==, 0);
  g_assert_false(wx_file_read_bounded(fifo, 10, &got, &len, &err));
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_INVAL);
  g_clear_error(&err);

  /* A sparse file far beyond the limit is rejected without reading it. */
  g_autofree char *big = path_in(f, "big");
  put_text(big, "x");
  g_assert_cmpint(truncate(big, (off_t)1 << 40), ==, 0);
  g_assert_false(wx_file_read_bounded(big, 1024, &got, &len, &err));
  g_assert_error(err, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE);
  g_clear_error(&err);
}

static void
test_fileio_write_failures(Fixture *f, gconstpointer unused)
{
  (void)unused;
  GError *err = NULL;

  /* Target is a non-empty directory: rename() fails after the temp file was
   * fully written; the temp file must be cleaned up and the target untouched. */
  g_autofree char *dirtarget = path_in(f, "target");
  g_autofree char *inner = g_build_filename(dirtarget, "keep", NULL);
  g_assert_cmpint(g_mkdir_with_parents(dirtarget, 0700), ==, 0);
  put_text(inner, "keep");
  g_assert_false(wx_file_write_atomic(dirtarget, "new", 3, &err));
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_ISDIR);
  g_clear_error(&err);
  g_assert_cmpuint(count_files(f->dir), ==, 1);
  g_assert_cmpuint(count_files(dirtarget), ==, 1);

  /* A parent component that is a regular file. */
  g_autofree char *file = path_in(f, "plain");
  put_text(file, "x");
  g_autofree char *below = g_build_filename(file, "sub", "x.json", NULL);
  g_assert_false(wx_file_write_atomic(below, "new", 3, &err));
  g_assert_nonnull(err);
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_NOTDIR);
  g_clear_error(&err);

  /* Read-only target directory: the previous content survives, no stray temp. */
  g_autofree char *rodir = path_in(f, "ro");
  g_assert_cmpint(g_mkdir(rodir, 0700), ==, 0);
  g_autofree char *rofile = g_build_filename(rodir, "data.json", NULL);
  put_text(rofile, "old");
  if (!make_read_only(rodir))
    return;
  g_assert_false(wx_file_write_atomic(rofile, "new", 3, &err));
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_ACCES);
  g_clear_error(&err);
  g_autofree char *got = NULL;
  g_assert_true(g_file_get_contents(rofile, &got, NULL, NULL));
  g_assert_cmpstr(got, ==, "old");
  g_assert_cmpuint(count_files(rodir), ==, 1);
}


static void
set_mtime_ago(const char *path, glong seconds)
{
  struct timeval tv[2];
  gettimeofday(&tv[0], NULL);
  tv[0].tv_sec -= seconds;
  tv[1] = tv[0];
  g_assert_cmpint(utimes(path, tv), ==, 0);
}

static void
test_fileio_stale_temps(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "cache.json");
  put_text(path, "{}");
  g_autofree char *old_tmp = path_in(f, "cache.json.wx-tmp-AbC123");
  g_autofree char *new_tmp = path_in(f, "cache.json.wx-tmp-zzZZ99");
  g_autofree char *other = path_in(f, "cache.json.bak");
  g_autofree char *other2 = path_in(f, "cache.json.wx-tmp-ab-123"); /* not alphanumeric */
  g_autofree char *foreign = path_in(f, "other.json.wx-tmp-AbC123"); /* another file's temp */
  g_autofree char *dir_tmp = path_in(f, "cache.json.wx-tmp-DIR123"); /* not a regular file */
  /* User copies a 6-character suffix could collide with: never removed. */
  const char *user_names[] = { "cache.json.backup", "cache.json.2026Q3", "cache.json.old123",
                               "cache.json.before", "cache.json.AbC123", "cache.json.wx-tmp-AbC1234",
                               "cache.json.wx-tmp-AbC12", "cache.json.wx-tmp-", "cache.json.wx-tmpAbC123" };
  for (guint i = 0; i < G_N_ELEMENTS(user_names); i++) {
    g_autofree char *u = path_in(f, user_names[i]);
    put_text(u, "u");
    set_mtime_ago(u, 3600);
  }
  put_text(old_tmp, "x");
  put_text(new_tmp, "y");
  put_text(other, "z");
  put_text(other2, "z");
  put_text(foreign, "z");
  g_assert_cmpint(g_mkdir(dir_tmp, 0700), ==, 0);
  set_mtime_ago(old_tmp, 3600);
  set_mtime_ago(other, 3600);
  set_mtime_ago(other2, 3600);
  set_mtime_ago(foreign, 3600);
  set_mtime_ago(dir_tmp, 3600);

  wx_file_remove_stale_temps(path);
  g_assert_false(g_file_test(old_tmp, G_FILE_TEST_EXISTS));
  g_assert_true(g_file_test(new_tmp, G_FILE_TEST_EXISTS)); /* a write may be running */
  g_assert_true(g_file_test(other, G_FILE_TEST_EXISTS));
  g_assert_true(g_file_test(other2, G_FILE_TEST_EXISTS));
  g_assert_true(g_file_test(foreign, G_FILE_TEST_EXISTS));
  g_assert_true(g_file_test(dir_tmp, G_FILE_TEST_IS_DIR));
  g_assert_true(g_file_test(path, G_FILE_TEST_EXISTS));

  /* A missing directory is not an error. */
  g_autofree char *nodir = path_in(f, "nodir/x.json");
  wx_file_remove_stale_temps(nodir);

  /* Both loaders clean up as well. */
  put_text(old_tmp, "x");
  set_mtime_ago(old_tmp, 3600);
  g_autoptr(WxCache) c = wx_cache_new(path);
  g_assert_false(wx_cache_load(c, NULL));
  g_assert_false(g_file_test(old_tmp, G_FILE_TEST_EXISTS));
  g_autofree char *wpath = path_in(f, "w.json");
  g_autofree char *wtmp = path_in(f, "w.json.wx-tmp-QqQq00");
  put_text(wtmp, "x");
  set_mtime_ago(wtmp, 3600);
  g_autoptr(WxPlaces) wl = wx_places_new(wpath);
  g_assert_false(wx_places_load(wl, NULL, NULL));
  g_assert_false(g_file_test(wtmp, G_FILE_TEST_EXISTS));
}

static char *
nested(gsize depth, char open, char close)
{
  GString *g = g_string_new(NULL);
  for (gsize i = 0; i < depth; i++)
    g_string_append_c(g, open);
  for (gsize i = 0; i < depth; i++)
    g_string_append_c(g, close);
  return g_string_free(g, FALSE);
}

static void
test_json_strict(void)
{
  g_autofree char *ok = nested(32, '[', ']');
  g_autofree char *deep = nested(33, '[', ']');
  g_autofree char *deep_obj = g_strconcat("{\"a\":", deep, "}", NULL);
  g_assert_true(wx_json_check_strict(ok, strlen(ok), 32));
  g_assert_false(wx_json_check_strict(deep, strlen(deep), 32));
  g_assert_false(wx_json_check_strict(deep_obj, strlen(deep_obj), 32));
  /* Brackets in strings (with escaped quotes) do not count. */
  const char *str = "[\"[[[[[[\\\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\"]";
  g_assert_true(wx_json_check_strict(str, strlen(str), 1));
  g_assert_true(wx_json_check_strict(NULL, 0, 0));
  g_assert_false(wx_json_check_strict("[", 1, 0));

  /* Structure: closers underflow, mismatch, unclosed containers. */
  const char *bad_struct[] = { "]]]][", "[}", "{]", "[[]", "]", "[]]", "{\"a\":[}]", "[{]}" };
  for (guint i = 0; i < G_N_ELEMENTS(bad_struct); i++)
    g_assert_false(wx_json_check_strict(bad_struct[i], strlen(bad_struct[i]), 32));

  /* Lenient json-glib syntax and stray bytes outside strings. */
  const char *bad_lex[] = {
    "['\"',[[[", "/*\"*/[[[", "// \"\n[", "['a']", "{'a':1}", "[1] # x", "[/**/]", "[b]", "[x]",
    "[tru e,\xc3\xa9]", "[\f1]", "[\v1]", "[\x01]", "[1]\x7f", "[\"a\"]\xff", "\0[]",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad_lex); i++) {
    gsize l = i == G_N_ELEMENTS(bad_lex) - 1 ? 3 : strlen(bad_lex[i]);
    g_assert_false(wx_json_check_strict(bad_lex[i], l, 32));
  }

  /* Strings: raw control bytes, bad/truncated escapes, unterminated. */
  const char *bad_str[] = { "[\"a\nb\"]", "[\"a\tb\"]", "[\"\\x\"]", "[\"\\u12\"]", "[\"\\u12G4\"]",
                            "[\"\\", "[\"abc", "[\"\\\"]", "[\"\\u123" };
  for (guint i = 0; i < G_N_ELEMENTS(bad_str); i++)
    g_assert_false(wx_json_check_strict(bad_str[i], strlen(bad_str[i]), 32));
  g_assert_false(wx_json_check_strict("[\"a\0b\"]", 7, 32)); /* NUL inside a string */

  /* Valid text, including every escape, non-ASCII bytes and ' / # inside strings. */
  const char *good =
    "{\"a\": [1, -2.5e+10, true, false, null, \"x\\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9\\uD83D\", \"'/#\\\\\", "
    "\"\xc3\xa9\xff\"], \"b\":{}, \"c\":[]}\n\t\r ";
  g_assert_true(wx_json_check_strict(good, strlen(good), 2));
  g_assert_false(wx_json_check_strict(good, strlen(good), 1));

  /* Siblings do not accumulate. */
  GString *many = g_string_new("[");
  for (guint i = 0; i < 5000; i++)
    g_string_append(many, "[],");
  g_string_append(many, "[]]");
  g_assert_true(wx_json_check_strict(many->str, many->len, 2));
  g_string_free(many, TRUE);
}

/* Appends a random JSON value of nesting at most @budget to @out. */
static void
random_value(GString *out, GRand *r, guint budget)
{
  static const char *const ws[] = { "", " ", "\n", "\t ", "\r\n" };
  g_string_append(out, ws[g_rand_int_range(r, 0, 5)]);
  gint kind = g_rand_int_range(r, 0, budget > 0 ? 8 : 5);
  switch (kind) {
  case 0: g_string_append(out, "null"); break;
  case 1: g_string_append(out, g_rand_boolean(r) ? "true" : "false"); break;
  case 2: g_string_append_printf(out, "%d", g_rand_int_range(r, -100000, 100000)); break;
  case 3: g_string_append_printf(out, "%.3e", g_rand_double_range(r, -1e9, 1e9)); break;
  case 4: {
    static const char *const frag[] = { "a", "'", "/", "#", "[", "{", "\\\"", "\\\\", "\\u00e9", "\xc3\xa9",
                                        "/*", "\\n", " ", "]" };
    g_string_append_c(out, '"');
    for (gint i = g_rand_int_range(r, 0, 8); i > 0; i--)
      g_string_append(out, frag[g_rand_int_range(r, 0, 14)]);
    g_string_append_c(out, '"');
    break;
  }
  case 5: case 6: {
    g_string_append_c(out, '[');
    for (gint i = g_rand_int_range(r, 0, 4); i > 0; i--) {
      random_value(out, r, budget - 1);
      g_string_append_c(out, i > 1 ? ',' : ' ');
    }
    g_string_append_c(out, ']');
    break;
  }
  default: {
    g_string_append_c(out, '{');
    for (gint i = g_rand_int_range(r, 0, 4); i > 0; i--) {
      g_string_append_printf(out, "\"k%d\":", i);
      random_value(out, r, budget - 1);
      g_string_append_c(out, i > 1 ? ',' : ' ');
    }
    g_string_append_c(out, '}');
    break;
  }
  }
  g_string_append(out, ws[g_rand_int_range(r, 0, 5)]);
}

static void
test_json_strict_random(void)
{
  GRand *r = g_rand_new_with_seed(12345);
  for (guint n = 0; n < 3000; n++) {
    g_autoptr(GString) doc = g_string_new(NULL);
    guint budget = (guint)g_rand_int_range(r, 0, 12);
    random_value(doc, r, budget);
    g_assert_true(wx_json_check_strict(doc->str, doc->len, 32));
    /* A valid document of depth <= 12 is accepted at exactly its depth and refused one below. */
    guint depth = 0, maxd = 0;
    gboolean in_s = FALSE;
    for (gsize i = 0; i < doc->len; i++) {
      char c = doc->str[i];
      if (in_s) {
        if (c == '\\') i++;
        else if (c == '"') in_s = FALSE;
      } else if (c == '"') in_s = TRUE;
      else if (c == '[' || c == '{') {
        depth++;
        maxd = MAX(maxd, depth);
      }
      else if (c == ']' || c == '}') depth--;
    }
    g_assert_true(wx_json_check_strict(doc->str, doc->len, maxd));
    if (maxd > 0)
      g_assert_false(wx_json_check_strict(doc->str, doc->len, maxd - 1));
    /* Truncation always yields an unclosed container or string: rejected. */
    if (doc->len > 0 && maxd > 0) {
      gsize cut = (gsize)g_rand_int_range(r, 0, (gint)doc->len);
      gboolean complete_prefix = wx_json_check_strict(doc->str, cut, 32);
      /* A strict prefix passes only when it is itself balanced (e.g. cut inside trailing whitespace). */
      if (complete_prefix) {
        guint d2 = 0;
        in_s = FALSE;
        for (gsize i = 0; i < cut; i++) {
          char c = doc->str[i];
          if (in_s) { if (c == '\\') i++; else if (c == '"') in_s = FALSE; }
          else if (c == '"') in_s = TRUE;
          else if (c == '[' || c == '{') d2++;
          else if (c == ']' || c == '}') d2--;
        }
        g_assert_cmpuint(d2, ==, 0);
        g_assert_false(in_s);
      }
    }
    /* A forbidden byte placed between tokens (outside any string) is refused. */
    g_string_prepend_c(doc, "'/#\x01\xff"[g_rand_int_range(r, 0, 5)]);
    g_assert_false(wx_json_check_strict(doc->str, doc->len, 32));
  }
  g_rand_free(r);
}


/* Writers never produce what the loaders' strict gate rejects              */
/* ------------------------------------------------------------------------ */

/* Every byte that needs escaping or is a control character: 0x01-0x1f, 0x7f,
 * '"' and '\\'. */
static guint
special_bytes(char out[34])
{
  guint n = 0;
  for (char c = 0x01; c <= 0x1f; c++)
    out[n++] = c;
  out[n++] = 0x7f;
  out[n++] = '"';
  out[n++] = '\\';
  return n;
}

static void
test_json_append_string(void)
{
  char bytes[34];
  guint n = special_bytes(bytes);
  for (guint i = 0; i < n; i++) {
    char text[] = {'a', bytes[i], 'b', '\0'};
    g_autoptr(GString) out = g_string_new(NULL);
    wx_json_append_string(out, text);
    g_assert_true(wx_json_check_strict(out->str, out->len, 1));
    guchar c = (guchar)bytes[i];
    g_autofree char *want = NULL;
    if (c == '"' || c == '\\')
      want = g_strdup_printf("\"a\\%cb\"", c);
    else if (c < 0x20)
      want = g_strdup_printf("\"a\\u%04xb\"", c);
    else
      want = g_strdup_printf("\"a%cb\"", c);
    g_assert_cmpstr(out->str, ==, want);
  }
  g_autoptr(GString) out = g_string_new("x");
  wx_json_append_string(out, "");
  g_assert_cmpstr(out->str, ==, "x\"\"");
}

static void
test_fileio_stale_temps_symlinks(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "places.json");
  put_text(path, "{}");
  set_mtime_ago(path, 3600);
  g_autofree char *good_link = path_in(f, "places.json.wx-tmp-LINK01");
  g_autofree char *dead_link = path_in(f, "places.json.wx-tmp-LINK02");
  g_autofree char *dir_link = path_in(f, "places.json.wx-tmp-LINK03");
  g_assert_cmpint(symlink("places.json", good_link), ==, 0);
  g_assert_cmpint(symlink("does-not-exist", dead_link), ==, 0);
  g_assert_cmpint(symlink(".", dir_link), ==, 0);
  /* Age the links themselves (not their targets). */
  struct timespec ts[2];
  clock_gettime(CLOCK_REALTIME, &ts[0]);
  ts[0].tv_sec -= 3600;
  ts[1] = ts[0];
  g_assert_cmpint(utimensat(AT_FDCWD, good_link, ts, AT_SYMLINK_NOFOLLOW), ==, 0);
  g_assert_cmpint(utimensat(AT_FDCWD, dead_link, ts, AT_SYMLINK_NOFOLLOW), ==, 0);
  g_assert_cmpint(utimensat(AT_FDCWD, dir_link, ts, AT_SYMLINK_NOFOLLOW), ==, 0);

  wx_file_remove_stale_temps(path);
  /* Only regular files are removed: a symlink is never judged by, or
   * followed to, its target. */
  GStatBuf st;
  g_assert_cmpint(g_lstat(good_link, &st), ==, 0);
  g_assert_true(S_ISLNK(st.st_mode));
  g_assert_cmpint(g_lstat(dead_link, &st), ==, 0);
  g_assert_true(S_ISLNK(st.st_mode));
  g_assert_cmpint(g_lstat(dir_link, &st), ==, 0);
  g_assert_true(S_ISLNK(st.st_mode));
  g_assert_true(g_file_test(path, G_FILE_TEST_IS_REGULAR));
}

/* ------------------------------------------------------------------------ */
/* Helpers shared by the tests below                                        */
/* ------------------------------------------------------------------------ */

#define EXPECT_CRITICAL(pattern) \
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, pattern)

/* A buffer of @n bytes that ENDS EXACTLY at a PROT_NONE page: any read past
 * the buffer faults. The bytes start zeroed. */
typedef struct {
  char *map;
  gsize size;
  char *buf;
} Guard;

static char *
guard_alloc(Guard *g, gsize n)
{
  long page = sysconf(_SC_PAGESIZE);
  g_assert_cmpint(page, >, 0);
  g_assert_cmpuint(n, <=, (gsize)page);
  g->size = 2 * (gsize)page;
  g->map = mmap(NULL, g->size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(g->map != MAP_FAILED);
  g_assert_cmpint(mprotect(g->map + page, (gsize)page, PROT_NONE), ==, 0);
  g->buf = g->map + page - n;
  return g->buf;
}

static void
guard_free(Guard *g)
{
  g_assert_cmpint(munmap(g->map, g->size), ==, 0);
}

/* A valid place at (lat, lon); the name is derived from @tag. */
static WxPlace *
make_place(const char *tag, double lat, double lon)
{
  GError *err = NULL;
  g_autofree char *name = g_strdup_printf("Place %s", tag);
  WxPlace *p = wx_place_new(name, "Region", "Country", "US", lat, lon, "America/New_York", &err);
  g_assert_no_error(err);
  g_assert_nonnull(p);
  return p;
}

/* Place number @i of a grid whose neighbours are more than 20 km apart. */
static WxPlace *
grid_place(guint i)
{
  g_autofree char *tag = g_strdup_printf("%u", i);
  return make_place(tag, -60.0 + 0.5 * (double)(i % 100), -170.0 + 0.7 * (double)(i / 100) * 10.0);
}

/* A hostile file of @n '[' must fail with a parse error, not crash. */
static void
put_open_brackets(const char *path, gsize n)
{
  g_autofree char *buf = g_malloc(n);
  memset(buf, '[', n);
  put_file(path, buf, n);
}

/* Payloads that hid every later bracket from a naive depth scan (a quote
 * inside a comment or a single-quoted string) while json-glib's default
 * scanner still recursed into them. */
static const char *const bypass_prefixes[] = {
  "['\"',", "/*\"*/", "// \"\n", "/* ' */ ['\"',", "'\"'", "# \"\n", "\"\\", "\"\\u12\"",
};

static void
put_prefixed_brackets(const char *path, const char *prefix, gsize total)
{
  gsize plen = strlen(prefix);
  g_assert_cmpuint(plen, <, total);
  g_autofree char *buf = g_malloc(total);
  memcpy(buf, prefix, plen);
  memset(buf + plen, '[', total - plen);
  put_file(path, buf, total);
}

static void
on_changed(gpointer obj, gpointer data)
{
  (void)obj;
  (*(guint *)data)++;
}

/* ------------------------------------------------------------------------ */
/* wx-fileio: number writer, strict gate bounds                              */
/* ------------------------------------------------------------------------ */

static void
check_double_roundtrip(double v)
{
  g_autoptr(GString) out = g_string_new(NULL);
  wx_json_append_double(out, v);
  g_assert_cmpuint(out->len, <=, 24);
  if (!isfinite(v)) {
    g_assert_cmpstr(out->str, ==, "null");
    return;
  }
  g_assert_true(wx_json_check_strict(out->str, out->len, 1));
  char *end = NULL;
  double back = g_ascii_strtod(out->str, &end);
  g_assert_true(*end == '\0');
  g_assert_cmpmem(&back, sizeof back, &v, sizeof v); /* bit-identical, -0.0 included */
  /* The text must be a JSON number json-glib reads as the same value. */
  g_autoptr(JsonParser) p = json_parser_new();
  g_autofree char *doc = g_strdup_printf("[%s]", out->str);
  g_assert_true(json_parser_load_from_data(p, doc, -1, NULL));
  JsonNode *n = json_array_get_element(json_node_get_array(json_parser_get_root(p)), 0);
  g_assert_cmpfloat(json_node_get_double(n), ==, v);
  if (v == 0.0)
    g_assert_cmpint(signbit(json_node_get_double(n)) != 0, ==, signbit(v) != 0);
}

static void
test_json_append_double(void)
{
  const double specials[] = {0.0,     -0.0,    1.0,      -1.0,     0.1,       1.0 / 3.0,
                             1e300,   -1e300,  5e-324,   -5e-324,  2.2250738585072014e-308,
                             G_MAXDOUBLE, -G_MAXDOUBLE, 123456789012345678.0, 1e15, 1e16, 1e17,
                             0.30000000000000004, 9007199254740993.0, NAN, INFINITY, -INFINITY,
                             25.7617, -80.1918, 100.0, 1e-5, 1e21, 1.7976931348623157e308};
  for (guint i = 0; i < G_N_ELEMENTS(specials); i++)
    check_double_roundtrip(specials[i]);

  /* Random bit patterns, including subnormals; the fixed seed keeps it reproducible. */
  GRand *r = g_rand_new_with_seed(4711);
  for (guint i = 0; i < 100000; i++) {
    guint64 bits = ((guint64)g_rand_int(r) << 32) | g_rand_int(r);
    double v;
    memcpy(&v, &bits, sizeof v);
    check_double_roundtrip(v);
  }
  for (guint i = 0; i < 20000; i++)
    check_double_roundtrip(g_rand_double_range(r, -200.0, 200.0));
  g_rand_free(r);

  /* Appends, never replaces. */
  g_autoptr(GString) out = g_string_new("x");
  wx_json_append_double(out, 2.5);
  g_assert_cmpstr(out->str, ==, "x2.5");

  EXPECT_CRITICAL("*out != NULL*");
  wx_json_append_double(NULL, 1.0);
  g_test_assert_expected_messages();
}

static void
test_json_append_string_null_args(void)
{
  g_autoptr(GString) out = g_string_new("keep");
  EXPECT_CRITICAL("*out != NULL && s != NULL*");
  wx_json_append_string(NULL, "x");
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*out != NULL && s != NULL*");
  wx_json_append_string(out, NULL);
  g_test_assert_expected_messages();
  g_assert_cmpstr(out->str, ==, "keep");
}

/* wx_json_check_strict() "never reads at or past @text + @len": run it over
 * buffers that end exactly at a guard page, for every first byte and for many
 * short strings made of the characters that change the scanner state. */
static void
test_json_strict_guard_page(void)
{
  Guard g;
  /* Every single byte, and every byte followed by structural characters. */
  static const char tails[] = {'"', '\\', 'u', '0', '[', ']', '{', '}', ',', ':', 'e', '-', 'n', 't'};
  for (guint b = 0; b < 256; b++) {
    for (gsize n = 1; n <= 3; n++) {
      char *buf = guard_alloc(&g, n);
      buf[0] = (char)b;
      for (guint t = 0; t < G_N_ELEMENTS(tails); t++) {
        for (gsize i = 1; i < n; i++)
          buf[i] = tails[(t + i) % G_N_ELEMENTS(tails)];
        (void)wx_json_check_strict(buf, n, 32);
      }
      guard_free(&g);
    }
  }
  /* Exhaustive short strings over the scanner-relevant alphabet. */
  static const char alphabet[] = {'"', '\\', 'u', '0', '1', 'f', '[', ']', '{', '}', ' ', 'x', '\n'};
  for (gsize n = 1; n <= 5; n++) {
    guint total = 1;
    for (gsize i = 0; i < n; i++)
      total *= G_N_ELEMENTS(alphabet);
    char *buf = guard_alloc(&g, n);
    for (guint k = 0; k < total; k++) {
      guint v = k;
      for (gsize i = 0; i < n; i++) {
        buf[i] = alphabet[v % G_N_ELEMENTS(alphabet)];
        v /= G_N_ELEMENTS(alphabet);
      }
      (void)wx_json_check_strict(buf, n, 32);
    }
    guard_free(&g);
  }
  /* A one-byte page buffer and the NULL / zero-length forms. */
  g_assert_true(wx_json_check_strict(NULL, 0, 32));
  g_assert_true(wx_json_check_strict("", 0, 0));
  EXPECT_CRITICAL("*max_depth <= 32*");
  g_assert_false(wx_json_check_strict("[]", 2, WX_JSON_MAX_DEPTH + 1));
  g_test_assert_expected_messages();
}

/* ------------------------------------------------------------------------ */
/* Forecast builder and comparison                                          */
/* ------------------------------------------------------------------------ */

#define T0 ((G_GINT64_CONSTANT(1768000000) / 3600) * 3600)

/* A valid forecast of the given shape; @variant changes every value. */
static WxForecast *
make_forecast(const WxPlace *place, guint n_hours, guint n_quarters, guint n_days,
              guint n_sources, guint variant)
{
  g_autofree WxBlendHour *hours = g_new0(WxBlendHour, n_hours);
  g_autofree WxQuarter *quarters = g_new0(WxQuarter, n_quarters);
  g_autofree WxDay *days = g_new0(WxDay, n_days);
  g_autofree WxSourceStatus *sources = g_new0(WxSourceStatus, n_sources);
  GPtrArray *owned = g_ptr_array_new_with_free_func((GDestroyNotify)wx_source_status_free);
  double v = (double)variant;
  for (guint i = 0; i < n_hours; i++) {
    WxBlendHour *h = &hours[i];
    h->t_s = T0 + (gint64)i * 3600;
    h->temp_c = 20.5 + 0.37 * i + v;
    h->feels_c = 21.25 - 0.11 * i - v;
    h->precip_mm = (i % 5) * 0.31;
    h->precip_mm_max = h->precip_mm * 1.5;
    h->precip_prob = (i * 7) % 101;
    h->cloud_pct = (i * 3) % 101;
    h->wind_kmh = 5.5 + 0.1 * i;
    h->gust_kmh = h->wind_kmh * 1.5;
    h->humidity_pct = 40 + i % 50;
    h->temp_spread_c = i % 2 ? NAN : 1.25;
    h->n_members = (guint8)(1 + i % 5);
    h->condition = (WxCondition)(i % WX_COND_COUNT);
    h->is_day = i % 2;
  }
  for (guint i = 0; i < n_quarters; i++) {
    quarters[i].t_s = T0 + (gint64)i * 900;
    quarters[i].precip_mm = (i % 4) * 0.05 + v * 0.001;
  }
  for (guint i = 0; i < n_days; i++) {
    WxDay *d = &days[i];
    d->start_s = T0 + (gint64)i * 86400;
    d->temp_max_c = 30.5 - i;
    d->temp_min_c = 20.25 - i;
    d->precip_mm = i * 1.75;
    d->precip_prob_max = (i * 11) % 101;
    d->cloud_pct = (i * 13) % 101;
    d->condition = (WxCondition)((i + 1) % WX_COND_COUNT);
  }
  for (guint i = 0; i < n_sources; i++) {
    g_autofree char *id = g_strdup_printf("src%u", i);
    g_autofree char *name = g_strdup_printf("Source %u", i);
    g_autofree char *attr = g_strdup_printf("Data from source %u", i);
    WxSourceState state = (WxSourceState)(i % 3);
    GError *err = NULL;
    WxSourceStatus *s = wx_source_status_new(id, name, attr, "https://example.org/data?a=1&b=2",
                                             state, state == WX_SRC_FAILED ? WX_ERROR_HTTP : -1,
                                             i, &err);
    g_assert_no_error(err);
    g_assert_nonnull(s);
    g_ptr_array_add(owned, s);
    sources[i] = *s;
  }
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, T0 + 100 + variant, hours, n_hours, quarters, n_quarters,
                                  days, n_days, sources, n_sources, &err);
  g_assert_no_error(err);
  g_assert_nonnull(f);
  g_ptr_array_unref(owned);
  return f;
}

static void
assert_same_double(double a, double b)
{
  if (isnan(a) || isnan(b)) {
    g_assert_true(isnan(a) && isnan(b));
    return;
  }
  g_assert_cmpmem(&a, sizeof a, &b, sizeof b); /* bit-identical: -0.0 differs from 0.0 */
}

static void
assert_forecast_equal(const WxForecast *a, const WxForecast *b)
{
  g_assert_cmpstr(a->place.name, ==, b->place.name);
  g_assert_cmpstr(a->place.admin1, ==, b->place.admin1);
  g_assert_cmpstr(a->place.country, ==, b->place.country);
  g_assert_cmpstr(a->place.country_code, ==, b->place.country_code);
  g_assert_cmpstr(a->place.timezone, ==, b->place.timezone);
  assert_same_double(a->place.lat, b->place.lat);
  assert_same_double(a->place.lon, b->place.lon);
  g_assert_cmpint(a->generated_s, ==, b->generated_s);
  g_assert_cmpuint(a->n_hours, ==, b->n_hours);
  g_assert_cmpuint(a->n_quarters, ==, b->n_quarters);
  g_assert_cmpuint(a->n_days, ==, b->n_days);
  g_assert_cmpuint(a->n_sources, ==, b->n_sources);
  for (guint i = 0; i < a->n_hours; i++) {
    const WxBlendHour *x = &a->hours[i], *y = &b->hours[i];
    g_assert_cmpint(x->t_s, ==, y->t_s);
    assert_same_double(x->temp_c, y->temp_c);
    assert_same_double(x->feels_c, y->feels_c);
    assert_same_double(x->precip_mm, y->precip_mm);
    assert_same_double(x->precip_mm_max, y->precip_mm_max);
    assert_same_double(x->precip_prob, y->precip_prob);
    assert_same_double(x->cloud_pct, y->cloud_pct);
    assert_same_double(x->wind_kmh, y->wind_kmh);
    assert_same_double(x->gust_kmh, y->gust_kmh);
    assert_same_double(x->humidity_pct, y->humidity_pct);
    assert_same_double(x->temp_spread_c, y->temp_spread_c);
    g_assert_cmpuint(x->n_members, ==, y->n_members);
    g_assert_cmpint(x->condition, ==, y->condition);
    g_assert_cmpint(x->is_day, ==, y->is_day);
  }
  for (guint i = 0; i < a->n_quarters; i++) {
    g_assert_cmpint(a->quarters[i].t_s, ==, b->quarters[i].t_s);
    assert_same_double(a->quarters[i].precip_mm, b->quarters[i].precip_mm);
  }
  for (guint i = 0; i < a->n_days; i++) {
    const WxDay *x = &a->days[i], *y = &b->days[i];
    g_assert_cmpint(x->start_s, ==, y->start_s);
    assert_same_double(x->temp_max_c, y->temp_max_c);
    assert_same_double(x->temp_min_c, y->temp_min_c);
    assert_same_double(x->precip_mm, y->precip_mm);
    assert_same_double(x->precip_prob_max, y->precip_prob_max);
    assert_same_double(x->cloud_pct, y->cloud_pct);
    g_assert_cmpint(x->condition, ==, y->condition);
  }
  for (guint i = 0; i < a->n_sources; i++) {
    const WxSourceStatus *x = &a->sources[i], *y = &b->sources[i];
    g_assert_cmpstr(x->provider_id, ==, y->provider_id);
    g_assert_cmpstr(x->name, ==, y->name);
    g_assert_cmpstr(x->attribution, ==, y->attribution);
    g_assert_cmpstr(x->attribution_url, ==, y->attribution_url);
    g_assert_cmpint(x->state, ==, y->state);
    g_assert_cmpint(x->error_code, ==, y->error_code);
    g_assert_cmpuint(x->n_members, ==, y->n_members);
  }
}

/* A 64-bit FNV-1a digest of every field of a forecast (NAN canonicalised). */
static void
fnv(guint64 *h, const void *data, gsize n)
{
  const guchar *p = data;
  for (gsize i = 0; i < n; i++)
    *h = (*h ^ p[i]) * G_GUINT64_CONSTANT(1099511628211);
}

static void
fnv_double(guint64 *h, double v)
{
  if (isnan(v))
    v = NAN;
  fnv(h, &v, sizeof v);
}

static guint64
forecast_digest(const WxForecast *f)
{
  guint64 h = G_GUINT64_CONSTANT(14695981039346656037);
  fnv(&h, f->place.name, strlen(f->place.name));
  fnv(&h, f->place.admin1, strlen(f->place.admin1));
  fnv(&h, f->place.country, strlen(f->place.country));
  fnv(&h, f->place.country_code, strlen(f->place.country_code));
  fnv(&h, f->place.timezone, strlen(f->place.timezone));
  fnv_double(&h, f->place.lat);
  fnv_double(&h, f->place.lon);
  fnv(&h, &f->generated_s, sizeof f->generated_s);
  for (guint i = 0; i < f->n_hours; i++) {
    const WxBlendHour *x = &f->hours[i];
    fnv(&h, &x->t_s, sizeof x->t_s);
    fnv_double(&h, x->temp_c);
    fnv_double(&h, x->feels_c);
    fnv_double(&h, x->precip_mm);
    fnv_double(&h, x->precip_mm_max);
    fnv_double(&h, x->precip_prob);
    fnv_double(&h, x->cloud_pct);
    fnv_double(&h, x->wind_kmh);
    fnv_double(&h, x->gust_kmh);
    fnv_double(&h, x->humidity_pct);
    fnv_double(&h, x->temp_spread_c);
    fnv(&h, &x->n_members, sizeof x->n_members);
    fnv(&h, &x->condition, sizeof x->condition);
    fnv(&h, &x->is_day, sizeof x->is_day);
  }
  for (guint i = 0; i < f->n_quarters; i++) {
    fnv(&h, &f->quarters[i].t_s, sizeof f->quarters[i].t_s);
    fnv_double(&h, f->quarters[i].precip_mm);
  }
  for (guint i = 0; i < f->n_days; i++) {
    const WxDay *d = &f->days[i];
    fnv(&h, &d->start_s, sizeof d->start_s);
    fnv_double(&h, d->temp_max_c);
    fnv_double(&h, d->temp_min_c);
    fnv_double(&h, d->precip_mm);
    fnv_double(&h, d->precip_prob_max);
    fnv_double(&h, d->cloud_pct);
    fnv(&h, &d->condition, sizeof d->condition);
  }
  for (guint i = 0; i < f->n_sources; i++) {
    const WxSourceStatus *s = &f->sources[i];
    fnv(&h, s->provider_id, strlen(s->provider_id));
    fnv(&h, s->name, strlen(s->name));
    fnv(&h, s->attribution, strlen(s->attribution));
    fnv(&h, s->attribution_url, strlen(s->attribution_url));
    fnv(&h, &s->state, sizeof s->state);
    fnv(&h, &s->error_code, sizeof s->error_code);
    fnv(&h, &s->n_members, sizeof s->n_members);
  }
  return h;
}

/* ------------------------------------------------------------------------ */
/* Generic store operations: the three classes share the save/load contract  */
/* ------------------------------------------------------------------------ */

typedef struct {
  const char *name;
  gpointer (*create)(const char *path);
  /* Makes one visible, valid change (step 0, 1, 2, ...) that marks the object dirty. */
  void (*mutate)(gpointer obj, guint step);
  gboolean (*is_dirty)(gpointer obj);
  gboolean (*save)(gpointer obj, GError **error);
  void (*save_async)(gpointer obj, GCancellable *c, GAsyncReadyCallback cb, gpointer data);
  gboolean (*save_finish)(gpointer obj, GAsyncResult *res, GError **error);
  gboolean (*load)(gpointer obj, GError **error);
  /* A string that is equal for equal contents (order included). */
  char *(*fingerprint)(gpointer obj);
  gsize max_file_bytes;
} StoreOps;

static gpointer
places_create(const char *path)
{
  return wx_places_new(path);
}

static void
places_mutate(gpointer obj, guint step)
{
  g_autoptr(WxPlace) p = grid_place(step);
  g_assert_true(wx_places_add(obj, p));
}

static gboolean
places_load(gpointer obj, GError **error)
{
  return wx_places_load(obj, NULL, error);
}

static char *
places_fingerprint(gpointer obj)
{
  GString *s = g_string_new(NULL);
  for (guint i = 0; i < wx_places_get_n_places(obj); i++) {
    const WxPlace *p = wx_places_get_place(obj, i);
    g_string_append_printf(s, "%s|%s|%s|%s|%s|%a|%a;", p->name, p->admin1, p->country,
                           p->country_code, p->timezone, p->lat, p->lon);
  }
  return g_string_free(s, FALSE);
}

static gpointer
settings_create(const char *path)
{
  return wx_settings_new(path);
}

static void
settings_mutate(gpointer obj, guint step)
{
  g_autofree char *id = g_strdup_printf("prov%u", step);
  g_assert_true(wx_settings_set_provider_disabled(obj, id, TRUE));
}

static char *
settings_fingerprint(gpointer obj)
{
  GString *s = g_string_new(NULL);
  g_string_append_printf(s, "%d|%s|", (int)wx_settings_get_units(obj),
                         wx_settings_get_selected(obj) ? wx_settings_get_selected(obj) : "(none)");
  for (guint i = 0; i < 40; i++) {
    g_autofree char *id = g_strdup_printf("prov%u", i);
    if (wx_settings_is_provider_disabled(obj, id))
      g_string_append_printf(s, "%s,", id);
  }
  return g_string_free(s, FALSE);
}

static gpointer
cache_create(const char *path)
{
  return wx_cache_new(path);
}

static void
cache_mutate(gpointer obj, guint step)
{
  g_autoptr(WxPlace) p = grid_place(step);
  g_autoptr(WxForecast) f = make_forecast(p, 6, 2, 1, 1, step);
  g_assert_true(wx_cache_put(obj, f, T0 * 1000 + step));
}

static char *
cache_fingerprint(gpointer obj)
{
  /* Recency order is part of the content: the grid keys are probed in order,
   * and the LRU order is compared separately by the cache tests. */
  GString *s = g_string_new(NULL);
  for (guint i = 0; i < 120; i++) {
    g_autoptr(WxPlace) p = grid_place(i);
    g_autofree char *key = wx_place_key(p);
    WxCache *c = obj;
    guint before = wx_cache_get_n_places(c);
    gint64 age = -1;
    WxForecast *f = wx_cache_get(c, key, &age);
    g_assert_cmpuint(wx_cache_get_n_places(c), ==, before);
    if (f != NULL) {
      g_string_append_printf(s, "%s@%" G_GINT64_FORMAT ":%u/%u/%u/%u:%" G_GUINT64_FORMAT ";", key,
                             f->generated_s, f->n_hours, f->n_quarters, f->n_days, f->n_sources,
                             forecast_digest(f));
      wx_forecast_unref(f);
    }
  }
  return g_string_free(s, FALSE);
}

/* Type-erasing wrappers: the object functions take their own pointer type. */
#define DEFINE_WRAPPERS(prefix)                                                            \
  static gboolean prefix##_is_dirty_w(gpointer o) { return prefix##_is_dirty(o); }          \
  static gboolean prefix##_save_w(gpointer o, GError **e) { return prefix##_save(o, e); }   \
  static void prefix##_save_async_w(gpointer o, GCancellable *c, GAsyncReadyCallback cb,    \
                                    gpointer d)                                              \
  {                                                                                          \
    prefix##_save_async(o, c, cb, d);                                                        \
  }                                                                                          \
  static gboolean prefix##_save_finish_w(gpointer o, GAsyncResult *r, GError **e)           \
  {                                                                                          \
    return prefix##_save_finish(o, r, e);                                                    \
  }

DEFINE_WRAPPERS(wx_places)
DEFINE_WRAPPERS(wx_settings)
DEFINE_WRAPPERS(wx_cache)

static gboolean
settings_load(gpointer obj, GError **error)
{
  return wx_settings_load(obj, error);
}

static gboolean
cache_load(gpointer obj, GError **error)
{
  return wx_cache_load(obj, error);
}

static const StoreOps k_places_ops = {
  "places",
  places_create,
  places_mutate,
  wx_places_is_dirty_w,
  wx_places_save_w,
  wx_places_save_async_w,
  wx_places_save_finish_w,
  places_load,
  places_fingerprint,
  WX_PLACES_MAX_FILE_BYTES};
static const StoreOps k_settings_ops = {
  "settings",
  settings_create,
  settings_mutate,
  wx_settings_is_dirty_w,
  wx_settings_save_w,
  wx_settings_save_async_w,
  wx_settings_save_finish_w,
  settings_load,
  settings_fingerprint,
  WX_SETTINGS_MAX_FILE_BYTES};
static const StoreOps k_cache_ops = {
  "cache",
  cache_create,
  cache_mutate,
  wx_cache_is_dirty_w,
  wx_cache_save_w,
  wx_cache_save_async_w,
  wx_cache_save_finish_w,
  cache_load,
  cache_fingerprint,
  WX_CACHE_MAX_FILE_BYTES};

static const StoreOps *const k_all_ops[] = {&k_places_ops, &k_settings_ops, &k_cache_ops};

/* Result of one save_async() call. */
typedef struct {
  const StoreOps *ops;
  gpointer obj;
  guint calls;
  gboolean ok;
  GError *error;
  gboolean dirty_in_callback;
} AsyncState;

static void
on_saved(GObject *source, GAsyncResult *res, gpointer data)
{
  AsyncState *st = data;
  g_assert_true(source == st->obj);
  st->calls++;
  st->dirty_in_callback = st->ops->is_dirty(st->obj);
  g_clear_error(&st->error);
  st->ok = st->ops->save_finish(st->obj, res, &st->error);
}

static void
wait_calls(AsyncState *st, guint n)
{
  while (st->calls < n)
    g_main_context_iteration(NULL, TRUE);
}

static char *
read_all(const char *path)
{
  char *text = NULL;
  GError *err = NULL;
  g_assert_true(g_file_get_contents(path, &text, NULL, &err));
  g_assert_no_error(err);
  return text;
}

/* The object is a new, never-loaded instance: its fingerprint. */
static char *
fresh_fingerprint(const StoreOps *ops)
{
  gpointer o = ops->create("/nonexistent/never-used.json");
  char *fp = ops->fingerprint(o);
  g_object_unref(o);
  return fp;
}

/* ------------------------------------------------------------------------ */
/* Generic tests, run for places, settings and cache                        */
/* ------------------------------------------------------------------------ */

/* The beginning (up to, not including, the closing brace) of the smallest valid document. */
static const char *
doc_prefix(const StoreOps *ops)
{
  if (ops == &k_places_ops)
    return "{\"version\":1,\"places\":[]";
  if (ops == &k_settings_ops)
    return "{\"version\":1";
  return "{\"version\":1,\"entries\":[]";
}

static void
test_store_roundtrip_and_files(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "cfg/weather/data.json");
    gpointer o = ops->create(path);
    g_assert_false(ops->is_dirty(o));
    for (guint i = 0; i < 3; i++)
      ops->mutate(o, i);
    g_assert_true(ops->is_dirty(o));
    GError *err = NULL;
    g_assert_true(ops->save(o, &err));
    g_assert_no_error(err);
    g_assert_false(ops->is_dirty(o));
    g_assert_cmpuint(file_mode(path), ==, 0600);
    g_autofree char *dir = g_path_get_dirname(path);
    g_assert_cmpuint(count_files(dir), ==, 1); /* no temp file left */

    /* The file passes the strict gate (writers never produce what loaders reject). */
    g_autofree char *text = read_all(path);
    g_assert_true(wx_json_check_strict(text, strlen(text), WX_JSON_MAX_DEPTH));
    g_assert_cmpuint(strlen(text), <, ops->max_file_bytes);

    gpointer o2 = ops->create(path);
    g_assert_true(ops->load(o2, &err));
    g_assert_no_error(err);
    g_assert_false(ops->is_dirty(o2));
    g_autofree char *fp1 = ops->fingerprint(o);
    g_autofree char *fp2 = ops->fingerprint(o2);
    g_assert_cmpstr(fp1, ==, fp2);
    g_assert_cmpstr(fp1, !=, "");

    /* Saving a clean object writes again; saving the loaded object writes the same bytes. */
    g_assert_true(ops->save(o2, &err));
    g_autofree char *text2 = read_all(path);
    g_assert_cmpstr(text, ==, text2);
    g_assert_cmpuint(count_files(dir), ==, 1);
    g_object_unref(o);
    g_object_unref(o2);
  }
}

static void
test_store_load_errors(Fixture *f, gconstpointer unused)
{
  (void)unused;
  static const char *const bad[] = {
    "",
    " ",
    "not json at all",
    "[]",
    "null",
    "123",
    "\"text\"",
    "{}",
    "{\"version\":0}",
    "{\"version\":2}",
    "{\"version\":-1}",
    "{\"version\":\"1\"}",
    "{\"version\":1.0}",
    "{\"version\":1.5}",
    "{\"version\":true}",
    "{\"version\":null}",
    "{\"version\":[1]}",
    "{\"version\":9223372036854775808}",
    "{\"version\":1",                          /* truncated */
    "{\"version\":1,}",                        /* trailing comma */
    "{\"version\":1}{",                        /* trailing bytes */
    "{\"version\":1} x",
    "{'version':1}",                           /* single quotes */
    "/* c */ {\"version\":1}",                 /* comments */
    "// c\n{\"version\":1}",
    "\xef\xbb\xbf{\"version\":1}",             /* a byte-order mark */
    "\xff\xfe{\"version\":1}",
    "{\"version\":1,\"x\":\"a\tb\"}",          /* raw control byte in a string */
    "{\"version\":1,\"x\":\"\\x\"}",           /* bad escape */
    "{\"version\":1,\"version\":1,\"x\":tru}",
  };
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "data.json");
    g_autofree char *fresh = fresh_fingerprint(ops);
    gpointer o = ops->create(path);
    guint changed = 0;
    gboolean has_signal = g_signal_lookup("changed", G_OBJECT_TYPE(o)) != 0;
    if (has_signal)
      g_signal_connect(o, "changed", G_CALLBACK(on_changed), &changed);
    GError *err = NULL;

    /* No file: NOENT, nothing else. */
    g_assert_false(ops->load(o, &err));
    g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_NOENT);
    g_clear_error(&err);
    g_assert_false(ops->is_dirty(o));

    for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
      ops->mutate(o, 0); /* the load must replace this */
      put_text(path, bad[i]);
      g_assert_false(ops->load(o, &err));
      g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
      g_clear_error(&err);
      g_autofree char *fp = ops->fingerprint(o);
      g_assert_cmpstr(fp, ==, fresh); /* emptied / defaults, never a crash */
      g_assert_false(ops->is_dirty(o));
    }

    /* The error argument is optional. */
    put_text(path, "garbage");
    g_assert_false(ops->load(o, NULL));

    /* Too large: exactly at the limit is read (and then rejected as JSON), one more is refused. */
    g_autofree char *huge = g_strnfill(ops->max_file_bytes + 1, ' ');
    put_file(path, huge, ops->max_file_bytes + 1);
    g_assert_false(ops->load(o, &err));
    g_assert_error(err, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE);
    g_clear_error(&err);
    put_file(path, huge, ops->max_file_bytes);
    g_assert_false(ops->load(o, &err));
    g_assert_error(err, WX_ERROR, WX_ERROR_PARSE); /* only blanks: read in full, not JSON */
    g_clear_error(&err);

    /* A directory, a FIFO. */
    g_assert_cmpint(g_unlink(path), ==, 0);
    g_assert_cmpint(g_mkdir(path, 0700), ==, 0);
    g_assert_false(ops->load(o, &err));
    g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_INVAL);
    g_clear_error(&err);
    g_assert_cmpint(g_rmdir(path), ==, 0);
    g_assert_cmpint(mkfifo(path, 0600), ==, 0);
    g_assert_false(ops->load(o, &err));
    g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_INVAL);
    g_clear_error(&err);
    g_assert_cmpint(g_unlink(path), ==, 0);

    /* Emptying a non-empty object (places) or resetting (settings) emitted "changed". */
    if (has_signal)
      g_assert_cmpuint(changed, >, 0);
    g_object_unref(o);
  }
}

static void
test_store_hostile_nesting(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "data.json");
    g_autofree char *fresh = fresh_fingerprint(ops);
    gpointer o = ops->create(path);
    GError *err = NULL;

    /* The whole permitted file size of '[': a parse error, not a stack overflow. */
    put_open_brackets(path, ops->max_file_bytes);
    g_assert_false(ops->load(o, &err));
    g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
    g_clear_error(&err);

    /* Prefixes that hid later brackets from a naive depth scan. */
    for (guint i = 0; i < G_N_ELEMENTS(bypass_prefixes); i++) {
      put_prefixed_brackets(path, bypass_prefixes[i], ops->max_file_bytes - 64);
      g_assert_false(ops->load(o, &err));
      g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
      g_clear_error(&err);
    }

    /* Deep nesting inside an otherwise valid document, at and beyond the limit. */
    for (guint depth = 31; depth <= 34; depth++) {
      g_autofree char *deep = nested(depth, '[', ']');
      g_autofree char *doc = g_strconcat(doc_prefix(ops), ", \"x\":", deep, "}", NULL);
      put_text(path, doc);
      gboolean ok = ops->load(o, &err);
      /* depth + 1 for the document object itself: 31 inner levels pass, 32 do not. */
      g_assert_cmpint(ok, ==, depth <= 31);
      if (!ok) {
        g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
        g_clear_error(&err);
      } else {
        g_assert_no_error(err);
      }
    }
    g_autofree char *fp = ops->fingerprint(o);
    g_assert_cmpstr(fp, ==, fresh);
    g_object_unref(o);
  }
}

static void
test_store_save_failure(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    GError *err = NULL;
    /* The target is a directory: the error is reported, the object stays dirty. */
    g_autofree char *dirtarget = path_in(f, "target");
    g_assert_cmpint(g_mkdir_with_parents(dirtarget, 0700), ==, 0);
    gpointer o = ops->create(dirtarget);
    ops->mutate(o, 0);
    g_assert_false(ops->save(o, &err));
    g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_ISDIR);
    g_clear_error(&err);
    g_assert_true(ops->is_dirty(o));
    g_assert_false(ops->save(o, NULL)); /* the error argument is optional */
    g_assert_cmpuint(count_files(f->dir), ==, 1);
    g_assert_cmpint(g_rmdir(dirtarget), ==, 0);
    g_object_unref(o);

    /* Read-only directory: the previous file survives. */
    g_autofree char *rodir = path_in(f, "ro");
    g_assert_cmpint(g_mkdir(rodir, 0700), ==, 0);
    g_autofree char *path = g_build_filename(rodir, "data.json", NULL);
    o = ops->create(path);
    ops->mutate(o, 0);
    g_assert_true(ops->save(o, NULL));
    g_autofree char *before = read_all(path);
    ops->mutate(o, 1);
    if (make_read_only(rodir)) {
      g_assert_false(ops->save(o, &err));
      g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_ACCES);
      g_clear_error(&err);
      g_assert_true(ops->is_dirty(o));
      (void)g_chmod(rodir, 0700);
      g_autofree char *after = read_all(path);
      g_assert_cmpstr(before, ==, after);
      g_assert_cmpuint(count_files(rodir), ==, 1);
    }
    g_assert_true(ops->save(o, NULL));
    g_assert_false(ops->is_dirty(o));
    g_object_unref(o);
    rm_rf(rodir);
  }
}

static void
test_store_save_async(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "cfg/data.json");
    gpointer o = ops->create(path);
    for (guint i = 0; i < 3; i++)
      ops->mutate(o, i);
    g_autofree char *fp_snapshot = ops->fingerprint(o);

    AsyncState st = {ops, o, 0, FALSE, NULL, TRUE};
    AsyncState st2 = {ops, o, 0, FALSE, NULL, TRUE};
    ops->save_async(o, NULL, on_saved, &st);
    /* While one runs a second save, a sync save and a load are refused; nothing is synchronous. */
    ops->save_async(o, NULL, on_saved, &st2);
    g_assert_cmpuint(st.calls + st2.calls, ==, 0);
    GError *err = NULL;
    g_assert_false(ops->save(o, &err));
    g_assert_error(err, G_IO_ERROR, G_IO_ERROR_PENDING);
    g_clear_error(&err);
    g_assert_true(ops->is_dirty(o));
    g_assert_false(ops->load(o, &err));
    g_assert_error(err, G_IO_ERROR, G_IO_ERROR_PENDING);
    g_clear_error(&err);
    g_assert_true(ops->is_dirty(o)); /* a refused load changes nothing */
    g_autofree char *fp_after_load = ops->fingerprint(o);
    g_assert_cmpstr(fp_after_load, ==, fp_snapshot);
    /* Editing after the snapshot is allowed and keeps the object dirty. */
    ops->mutate(o, 3);

    wait_calls(&st, 1);
    wait_calls(&st2, 1);
    g_assert_true(st.ok);
    g_assert_no_error(st.error);
    g_assert_true(st.dirty_in_callback); /* the edit after the snapshot */
    g_assert_false(st2.ok);
    g_assert_error(st2.error, G_IO_ERROR, G_IO_ERROR_PENDING);
    g_clear_error(&st2.error);
    g_assert_true(ops->is_dirty(o));

    /* The file holds the snapshot (3 steps), not the later edit. */
    gpointer o2 = ops->create(path);
    g_assert_true(ops->load(o2, &err));
    g_assert_no_error(err);
    g_autofree char *fp_loaded = ops->fingerprint(o2);
    g_assert_cmpstr(fp_loaded, ==, fp_snapshot);
    g_object_unref(o2);

    /* A new save after completion is accepted and clears the dirty flag. */
    st.calls = 0;
    st.ok = FALSE;
    ops->save_async(o, NULL, on_saved, &st);
    wait_calls(&st, 1);
    g_assert_true(st.ok);
    g_assert_false(st.dirty_in_callback);
    g_assert_false(ops->is_dirty(o));
    g_assert_cmpuint(count_files(f->dir), ==, 1);
    g_autofree char *cfg = path_in(f, "cfg");
    g_assert_cmpuint(count_files(cfg), ==, 1);
    g_assert_cmpuint(file_mode(path), ==, 0600);
    g_object_unref(o);
    rm_rf(cfg);
  }
}

static void
test_store_save_async_failure_and_cancel(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *dir = path_in(f, "ro");
    g_assert_cmpint(g_mkdir(dir, 0700), ==, 0);
    g_autofree char *path = g_build_filename(dir, "data.json", NULL);
    gpointer o = ops->create(path);
    ops->mutate(o, 0);

    /* Cancelled before it starts: nothing is written, the object stays dirty. */
    AsyncState st = {ops, o, 0, FALSE, NULL, FALSE};
    g_autoptr(GCancellable) cancel = g_cancellable_new();
    g_cancellable_cancel(cancel);
    ops->save_async(o, cancel, on_saved, &st);
    wait_calls(&st, 1);
    g_assert_false(st.ok);
    g_assert_error(st.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    g_clear_error(&st.error);
    g_assert_true(ops->is_dirty(o));
    g_assert_cmpuint(count_files(dir), ==, 0);

    /* Not cancelled, directory not writable: the error is reported, the old file survives. */
    g_assert_true(ops->save(o, NULL));
    ops->mutate(o, 1);
    if (make_read_only(dir)) {
      st.calls = 0;
      ops->save_async(o, NULL, on_saved, &st);
      wait_calls(&st, 1);
      g_assert_false(st.ok);
      g_assert_error(st.error, G_FILE_ERROR, G_FILE_ERROR_ACCES);
      g_clear_error(&st.error);
      g_assert_true(ops->is_dirty(o));
      (void)g_chmod(dir, 0700);
      g_assert_cmpuint(count_files(dir), ==, 1);
    }

    /* After a failure a new save is accepted (the in-flight flag was reset). */
    st.calls = 0;
    ops->save_async(o, NULL, on_saved, &st);
    wait_calls(&st, 1);
    g_assert_true(st.ok);
    g_assert_no_error(st.error);
    g_assert_false(ops->is_dirty(o));

    /* Cancelling after the request was made but with a live (never cancelled) token. */
    g_autoptr(GCancellable) live = g_cancellable_new();
    st.calls = 0;
    ops->mutate(o, 2);
    ops->save_async(o, live, on_saved, &st);
    wait_calls(&st, 1);
    g_assert_true(st.ok);
    g_cancellable_cancel(live); /* after completion: nothing happens */
    g_main_context_iteration(NULL, FALSE);
    g_assert_cmpuint(st.calls, ==, 1);
    g_object_unref(o);
    rm_rf(dir);
  }
}

/* GWeakNotify: may run on any thread, so it only sets an atomic flag. */
static void
on_finalized_flag(gpointer data, GObject *where_the_object_was)
{
  (void)where_the_object_was;
  g_atomic_int_set((gint *)data, 1);
}

/* The object may be released by the caller while a save runs: the task keeps it alive. */
static void
test_store_save_async_unref_while_running(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "data.json");
    gpointer o = ops->create(path);
    ops->mutate(o, 0);
    g_autofree char *fp = ops->fingerprint(o);
    gint finalized = 0;
    g_object_weak_ref(o, on_finalized_flag, &finalized);
    ops->save_async(o, NULL, (GAsyncReadyCallback)NULL, NULL);
    ops->save_async(o, NULL, (GAsyncReadyCallback)NULL, NULL); /* PENDING, dropped */
    g_object_unref(o);
    /* The task owns the object until the worker has dropped its last reference too, so the
     * finalisation may run on the worker thread after the main-loop callback: it does not wake
     * this thread, hence the bounded polling instead of a blocking iteration. */
    gint64 deadline = g_get_monotonic_time() + 20 * G_USEC_PER_SEC;
    while (!g_atomic_int_get(&finalized)) {
      g_assert_cmpint(g_get_monotonic_time(), <, deadline);
      g_main_context_iteration(NULL, FALSE);
      g_usleep(500);
    }
    gpointer o2 = ops->create(path);
    g_assert_true(ops->load(o2, NULL));
    g_autofree char *fp2 = ops->fingerprint(o2);
    g_assert_cmpstr(fp, ==, fp2);
    g_object_unref(o2);
    g_assert_cmpint(g_unlink(path), ==, 0);
  }
}

/* Saves from a destroyed context do not leak or crash: repeated create/save/unref cycles. */
static void
test_store_save_async_many(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "data.json");
    gpointer o = ops->create(path);
    AsyncState st = {ops, o, 0, FALSE, NULL, FALSE};
    for (guint i = 0; i < 30; i++) {
      if (i < 12)
        ops->mutate(o, i); /* 12 distinct steps are valid for every class (cap: 16 ids) */
      st.calls = 0;
      ops->save_async(o, NULL, on_saved, &st);
      wait_calls(&st, 1);
      g_assert_true(st.ok); /* the later saves write an unchanged object */
    }
    g_object_unref(o);
  }
}

static void
test_store_stale_temps_removed_by_load(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "data.json");
    g_autofree char *old_tmp = path_in(f, "data.json.wx-tmp-QqQq00");
    g_autofree char *young = path_in(f, "data.json.wx-tmp-YYYY11");
    put_text(old_tmp, "x");
    put_text(young, "y");
    set_mtime_ago(old_tmp, 3600);
    gpointer o = ops->create(path);
    g_assert_false(ops->load(o, NULL)); /* no file */
    g_assert_false(g_file_test(old_tmp, G_FILE_TEST_EXISTS));
    g_assert_true(g_file_test(young, G_FILE_TEST_EXISTS));
    g_assert_cmpint(g_unlink(young), ==, 0);
    g_object_unref(o);
  }
}

/* ------------------------------------------------------------------------ */
/* WxPlaces                                                                 */
/* ------------------------------------------------------------------------ */

static void
assert_places_keys(WxPlaces *pl, const char *const *expected)
{
  guint n = 0;
  while (expected[n] != NULL)
    n++;
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, n);
  for (guint i = 0; i < n; i++) {
    g_autofree char *key = wx_place_key(wx_places_get_place(pl, i));
    g_assert_cmpstr(key, ==, expected[i]);
  }
}

static void
test_places_basic(void)
{
  g_autoptr(WxPlaces) pl = wx_places_new("/nonexistent/never-used.json");
  guint changed = 0;
  g_signal_connect(pl, "changed", G_CALLBACK(on_changed), &changed);
  g_autoptr(WxPlace) miami = make_place("Miami", 25.7617, -80.1918);
  g_autoptr(WxPlace) tampa = make_place("Tampa", 27.9506, -82.4572);
  g_autoptr(WxPlace) orlando = make_place("Orlando", 28.5383, -81.3792);
  g_autoptr(WxPlace) london = make_place("London", 51.5072, -0.1276);

  g_assert_true(wx_places_add(pl, miami));
  g_assert_true(wx_places_add(pl, tampa));
  g_assert_true(wx_places_add(pl, orlando));
  g_assert_true(wx_places_add(pl, london));
  g_assert_cmpuint(changed, ==, 4);
  const char *const order1[] = {"25.7617,-80.1918", "27.9506,-82.4572", "28.5383,-81.3792",
                                "51.5072,-0.1276", NULL};
  assert_places_keys(pl, order1);
  g_assert_null(wx_places_get_place(pl, 4));
  g_assert_null(wx_places_get_place(pl, G_MAXUINT));
  /* The list holds private copies. */
  g_assert_true(wx_places_get_place(pl, 0) != miami);
  g_assert_cmpstr(wx_places_get_place(pl, 0)->name, ==, "Place Miami");
  g_assert_cmpstr(wx_places_get_place(pl, 0)->country_code, ==, "US");
  const WxPlace *p0 = wx_places_get_place(pl, 0);
  const WxPlace *p3 = wx_places_get_place(pl, 3);

  g_assert_cmpint(wx_places_index_of(pl, "27.9506,-82.4572"), ==, 1);
  g_assert_cmpint(wx_places_index_of(pl, "51.5072,-0.1276"), ==, 3);
  g_assert_cmpint(wx_places_index_of(pl, "0.0000,0.0000"), ==, -1);
  g_assert_cmpint(wx_places_index_of(pl, NULL), ==, -1);
  g_assert_cmpint(wx_places_index_of(pl, ""), ==, -1);
  g_assert_cmpint(wx_places_index_of(pl, "../etc"), ==, -1);
  g_assert_cmpint(wx_places_index_of(pl, "25.7617,-80.191"), ==, -1); /* prefix of a key */
  g_assert_cmpint(wx_places_index_of(pl, "25.7617,-80.19180"), ==, -1);
  g_assert_cmpint(wx_places_index_of(pl, "123456789012345678901234567890"), ==, -1); /* > 23 bytes */

  /* Duplicates are rejected without a signal: the same place, the same key, and every place
   * closer than 5 km (Miami -> 0.04 degrees of latitude is 4.4 km). */
  g_autoptr(WxPlace) same_key = make_place("Other name", 25.7617, -80.1918);
  g_autoptr(WxPlace) rounding = make_place("Rounded", 25.76171, -80.19181);
  g_autoptr(WxPlace) near_miami = make_place("Near", 25.8017, -80.1918);
  g_assert_false(wx_places_add(pl, miami));
  g_assert_false(wx_places_add(pl, same_key));
  g_assert_false(wx_places_add(pl, rounding));
  g_assert_false(wx_places_add(pl, near_miami));
  g_assert_cmpuint(changed, ==, 4);
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, 4);

  /* Invalid places are rejected without a critical. */
  WxPlace blank;
  memset(&blank, 0, sizeof blank);
  g_assert_false(wx_places_add(pl, &blank)); /* NULL strings */
  WxPlace bad = *miami;
  bad.lat = 95.0;
  g_assert_false(wx_places_add(pl, &bad));
  bad = *tampa;
  bad.lon = NAN;
  g_assert_false(wx_places_add(pl, &bad));
  g_autofree char *ctrl_name = g_strdup("bad\x01name");
  bad = *london;
  bad.name = ctrl_name;
  bad.lat = 40.0;
  g_assert_false(wx_places_add(pl, &bad));
  g_assert_false(wx_places_add(pl, NULL));
  g_assert_cmpuint(changed, ==, 4);

  /* Moving keeps the very same place objects. */
  g_assert_true(wx_places_move(pl, 0, 2));
  const char *const order2[] = {"27.9506,-82.4572", "28.5383,-81.3792", "25.7617,-80.1918",
                                "51.5072,-0.1276", NULL};
  assert_places_keys(pl, order2);
  g_assert_true(wx_places_get_place(pl, 2) == p0);
  g_assert_true(wx_places_move(pl, 3, 0));
  const char *const order3[] = {"51.5072,-0.1276", "27.9506,-82.4572", "28.5383,-81.3792",
                                "25.7617,-80.1918", NULL};
  assert_places_keys(pl, order3);
  g_assert_true(wx_places_get_place(pl, 0) == p3);
  g_assert_true(wx_places_move(pl, 1, 2));
  const char *const order4[] = {"51.5072,-0.1276", "28.5383,-81.3792", "27.9506,-82.4572",
                                "25.7617,-80.1918", NULL};
  assert_places_keys(pl, order4);
  guint before = changed;
  g_assert_false(wx_places_move(pl, 2, 2));
  g_assert_false(wx_places_move(pl, 4, 0));
  g_assert_false(wx_places_move(pl, 0, 4));
  g_assert_false(wx_places_move(pl, G_MAXUINT, 0));
  g_assert_cmpuint(changed, ==, before);

  g_assert_true(wx_places_remove(pl, "28.5383,-81.3792"));
  g_assert_cmpuint(changed, ==, before + 1);
  g_assert_false(wx_places_remove(pl, "28.5383,-81.3792"));
  g_assert_false(wx_places_remove(pl, NULL));
  g_assert_false(wx_places_remove(pl, "nope"));
  g_assert_false(wx_places_remove(pl, "123456789012345678901234567890"));
  g_assert_cmpuint(changed, ==, before + 1);
  const char *const order5[] = {"51.5072,-0.1276", "27.9506,-82.4572", "25.7617,-80.1918", NULL};
  assert_places_keys(pl, order5);
  /* Everything is order-preserving: re-adding the removed one appends. */
  g_assert_true(wx_places_add(pl, orlando));
  g_assert_cmpstr(wx_places_get_path(pl), ==, "/nonexistent/never-used.json");
}

static void
test_places_duplicate_boundaries(void)
{
  /* 1 degree of latitude is 111.19 km on the model sphere: 0.0449 deg = 4.99 km, 0.0451 = 5.01 km. */
  g_autoptr(WxPlaces) pl = wx_places_new("/nonexistent/never-used.json");
  g_autoptr(WxPlace) a = make_place("A", 10.0, 10.0);
  g_autoptr(WxPlace) just_inside = make_place("B", 10.0449, 10.0);
  g_autoptr(WxPlace) just_outside = make_place("C", 10.0451, 10.0);
  g_assert_true(wx_places_add(pl, a));
  g_assert_false(wx_places_add(pl, just_inside));
  g_assert_true(wx_places_add(pl, just_outside));

  /* Across the antimeridian and over the pole. */
  g_autoptr(WxPlaces) p2 = wx_places_new("/nonexistent/never-used.json");
  g_autoptr(WxPlace) e1 = make_place("E1", 0.0, 179.99);
  g_autoptr(WxPlace) e2 = make_place("E2", 0.0, -179.99);
  g_autoptr(WxPlace) n1 = make_place("N1", 89.99, 0.0);
  g_autoptr(WxPlace) n2 = make_place("N2", 89.99, 180.0);
  g_autoptr(WxPlace) pole1 = make_place("P1", 90.0, 0.0);
  g_autoptr(WxPlace) pole2 = make_place("P2", 90.0, 123.0);
  g_assert_true(wx_places_add(p2, e1));
  g_assert_false(wx_places_add(p2, e2));
  g_assert_true(wx_places_add(p2, n1));
  g_assert_false(wx_places_add(p2, n2));
  g_assert_false(wx_places_add(p2, pole1)); /* 1.1 km from n1 */
  g_assert_cmpuint(wx_places_get_n_places(p2), ==, 2);
  g_autoptr(WxPlaces) p3 = wx_places_new("/nonexistent/never-used.json");
  g_assert_true(wx_places_add(p3, pole1));
  g_assert_false(wx_places_add(p3, pole2)); /* the same point: longitude is meaningless */
}

static void
test_places_capacity(void)
{
  g_autoptr(WxPlaces) pl = wx_places_new("/nonexistent/never-used.json");
  for (guint i = 0; i < WX_PLACE_MAX; i++) {
    g_autoptr(WxPlace) p = grid_place(i);
    g_assert_true(wx_places_add(pl, p));
  }
  g_autoptr(WxPlace) more = grid_place(WX_PLACE_MAX);
  g_assert_false(wx_places_add(pl, more));
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, WX_PLACE_MAX);
  /* A removal makes room again. */
  g_autoptr(WxPlace) first = grid_place(0);
  g_autofree char *key = wx_place_key(first);
  g_assert_true(wx_places_remove(pl, key));
  g_assert_true(wx_places_add(pl, more));
}

static void
test_default_paths(void)
{
  g_autoptr(WxPlaces) pl = wx_places_new(NULL);
  g_autofree char *want = g_build_filename(g_get_user_config_dir(), "weather", "places.json", NULL);
  g_assert_cmpstr(wx_places_get_path(pl), ==, want);
  g_autoptr(WxSettings) st = wx_settings_new(NULL);
  g_autofree char *want_s =
    g_build_filename(g_get_user_config_dir(), "weather", "settings.json", NULL);
  g_assert_cmpstr(wx_settings_get_path(st), ==, want_s);
  g_autoptr(WxCache) c = wx_cache_new(NULL);
  g_autofree char *want_c =
    g_build_filename(g_get_user_cache_dir(), "weather", "forecasts.json", NULL);
  g_assert_cmpstr(wx_cache_get_path(c), ==, want_c);
  /* The path is copied. */
  char *tmp = g_strdup("/tmp/x/y.json");
  g_autoptr(WxPlaces) p2 = wx_places_new(tmp);
  g_free(tmp);
  g_assert_cmpstr(wx_places_get_path(p2), ==, "/tmp/x/y.json");
  /* The empty path is a programmer error. */
  EXPECT_CRITICAL("*path == NULL || path[0] != '\\0'*");
  g_assert_null(wx_places_new(""));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*path == NULL || path[0] != '\\0'*");
  g_assert_null(wx_settings_new(""));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*path == NULL || path[0] != '\\0'*");
  g_assert_null(wx_cache_new(""));
  g_test_assert_expected_messages();
}

static void
test_places_roundtrip_exact(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "cfg/weather/places.json");
  g_autoptr(WxPlaces) pl = wx_places_new(path);
  g_autofree char *quotes = g_strnfill(WX_PLACE_NAME_MAX, '"');
  g_autofree char *slashes = g_strnfill(WX_PLACE_NAME_MAX, '\\');
  struct {
    const char *name, *admin1, *country, *code, *tz;
    double lat, lon;
  } rows[] = {
    {"Zürich Straße 日本 🚀", "Kanton Zürich", "Schweiz", "CH", "Europe/Zurich", 47.3769, 8.5417},
    {"quote \" backslash \\ slash / percent %s", "", "", "", "", -33.8688, 151.2093},
    {"Südpol", "", "Antarctica", "", "Etc/GMT+5", -90.0, 0.0},
    {"Nordpol", NULL, NULL, NULL, NULL, 90.0, 12.5},
    {"Ost", "", "", "", "", 1e-300, 180.0},
    {"West", "", "", "", "", -0.0, -100.0},
    {"Long", "Long", "Long", "US", "America/Argentina/ComodRivadavia", 12.3456789012345678,
     -98.7654321098765432},
    {quotes, quotes, slashes, "DE", "UTC", 50.0, 10.0},
    {slashes, slashes, quotes, "", "", -50.0, -10.0},
  };
  for (guint i = 0; i < G_N_ELEMENTS(rows); i++) {
    g_autoptr(GError) err = NULL;
    g_autoptr(WxPlace) p = wx_place_new(rows[i].name, rows[i].admin1, rows[i].country,
                                        rows[i].code, rows[i].lat, rows[i].lon, rows[i].tz, &err);
    g_assert_no_error(err);
    g_assert_true(wx_places_add(pl, p));
  }
  g_assert_true(wx_places_save(pl, NULL));
  g_autoptr(WxPlaces) back = wx_places_new(path);
  guint dropped = 9;
  GError *err = NULL;
  g_assert_true(wx_places_load(back, &dropped, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(dropped, ==, 0);
  g_assert_cmpuint(wx_places_get_n_places(back), ==, G_N_ELEMENTS(rows));
  for (guint i = 0; i < G_N_ELEMENTS(rows); i++) {
    const WxPlace *a = wx_places_get_place(pl, i), *b = wx_places_get_place(back, i);
    g_assert_cmpstr(a->name, ==, b->name);
    g_assert_cmpstr(a->admin1, ==, b->admin1);
    g_assert_cmpstr(a->country, ==, b->country);
    g_assert_cmpstr(a->country_code, ==, b->country_code);
    g_assert_cmpstr(a->timezone, ==, b->timezone);
    assert_same_double(a->lat, b->lat);
    assert_same_double(a->lon, b->lon);
  }
}

/* The largest places file this module writes stays far below the load limit. */
static void
test_places_max_file_size(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "places.json");
  g_autoptr(WxPlaces) pl = wx_places_new(path);
  g_autofree char *quotes = g_strnfill(WX_PLACE_NAME_MAX, '"');
  for (guint i = 0; i < WX_PLACE_MAX; i++) {
    g_autoptr(GError) err = NULL;
    g_autoptr(WxPlace) p = wx_place_new(quotes, quotes, quotes, "US", -12.345678901234567 + i,
                                        -123.45678901234567 + 2 * i, "America/Argentina/ComodRivadavia",
                                        &err);
    g_assert_no_error(err);
    g_assert_true(wx_places_add(pl, p));
  }
  g_assert_true(wx_places_save(pl, NULL));
  g_autofree char *text = read_all(path);
  g_assert_cmpuint(strlen(text), <, WX_PLACES_MAX_FILE_BYTES / 4);
  g_autoptr(WxPlaces) back = wx_places_new(path);
  g_assert_true(wx_places_load(back, NULL, NULL));
  g_assert_cmpuint(wx_places_get_n_places(back), ==, WX_PLACE_MAX);
}

typedef struct {
  const char *json; /* one element of the "places" array */
  const char *name; /* NULL: the element must be dropped; else the kept name */
} PlaceCase;

static void
test_places_load_partial(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *toolong = g_strnfill(WX_PLACE_NAME_MAX + 1, 'n');
  g_autofree char *long_ok = g_strnfill(WX_PLACE_NAME_MAX, 'n');
  g_autofree char *j_toolong = g_strdup_printf("{\"name\":\"%s\",\"lat\":1,\"lon\":2}", toolong);
  g_autofree char *j_long_ok = g_strdup_printf("{\"name\":\"%s\",\"lat\":3,\"lon\":4}", long_ok);
  const PlaceCase cases[] = {
    {"{\"name\":\"Minimal\",\"lat\":1.5,\"lon\":2.5}", "Minimal"},
    {"{\"name\":\"Full\",\"admin1\":\"A\",\"country\":\"C\",\"country_code\":\"US\","
     "\"lat\":10,\"lon\":20,\"timezone\":\"America/New_York\"}", "Full"},
    {"{\"name\":\"Ints\",\"lat\":-30,\"lon\":-40}", "Ints"},
    {"{\"name\":\"Exp\",\"lat\":5e1,\"lon\":-1.5E+1}", "Exp"},
    {j_long_ok, long_ok},
    {"{\"name\":\"Unicode \\u00e9\\u65e5\",\"lat\":6,\"lon\":7}", "Unicode \xc3\xa9\xe6\x97\xa5"},
    {"{\"name\":\"Extra\",\"lat\":8,\"lon\":9,\"unknown\":[1,2,{\"x\":null}]}", "Extra"},
    /* Wrong shapes. */
    {"5", NULL}, {"\"x\"", NULL}, {"null", NULL}, {"[]", NULL}, {"true", NULL}, {"{}", NULL},
    {"{\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":5,\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":null,\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"B1\",\"lat\":\"1\",\"lon\":2}", NULL},
    {"{\"name\":\"B2\",\"lat\":1,\"lon\":null}", NULL},
    {"{\"name\":\"B3\",\"lon\":2}", NULL},
    {"{\"name\":\"B4\",\"lat\":1}", NULL},
    {"{\"name\":\"B5\",\"lat\":true,\"lon\":2}", NULL},
    {"{\"name\":\"B6\",\"lat\":[1],\"lon\":2}", NULL},
    /* Out-of-range coordinates. */
    {"{\"name\":\"C1\",\"lat\":91,\"lon\":0}", NULL},
    {"{\"name\":\"C2\",\"lat\":-91,\"lon\":0}", NULL},
    {"{\"name\":\"C3\",\"lat\":0,\"lon\":181}", NULL},
    {"{\"name\":\"C4\",\"lat\":0,\"lon\":-180.0001}", NULL},
    {"{\"name\":\"C5\",\"lat\":1e30,\"lon\":0}", NULL},
    {"{\"name\":\"C6\",\"lat\":9223372036854775807,\"lon\":0}", NULL},
    /* Names the core rules refuse. */
    {"{\"name\":\"\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"   \",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"x\\u0001y\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"x\\u007fy\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"x\\u202ey\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"x\\u2066y\",\"lat\":1,\"lon\":2}", NULL},
    {j_toolong, NULL},
    /* Optional members of the wrong type or value. */
    {"{\"name\":\"D1\",\"admin1\":5,\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"D2\",\"country\":null,\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"D3\",\"country_code\":\"us\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"D4\",\"country_code\":\"USA\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"D5\",\"timezone\":\"/etc/passwd\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"D6\",\"timezone\":\"a/../b\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"D7\",\"timezone\":\"-x\",\"lat\":1,\"lon\":2}", NULL},
    {"{\"name\":\"D8\",\"timezone\":7,\"lat\":1,\"lon\":2}", NULL},
    /* Duplicates of kept places: the same coordinates, and within 5 km. */
    {"{\"name\":\"Dup1\",\"lat\":1.5,\"lon\":2.5}", NULL},
    {"{\"name\":\"Dup2\",\"lat\":1.5,\"lon\":2.52}", NULL},
    {"{\"name\":\"Far\",\"lat\":1.5,\"lon\":2.6}", "Far"},
  };
  GString *doc = g_string_new("{\"version\":1,\"places\":[");
  guint kept = 0, dropped_expected = 0;
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_string_append_printf(doc, "%s%s", i > 0 ? "," : "", cases[i].json);
    if (cases[i].name != NULL)
      kept++;
    else
      dropped_expected++;
  }
  g_string_append(doc, "],\"extra\":{\"x\":[]}}");
  g_autofree char *path = path_in(f, "places.json");
  put_text(path, doc->str);
  g_string_free(doc, TRUE);

  g_autoptr(WxPlaces) pl = wx_places_new(path);
  guint changed = 0, dropped = 99;
  g_signal_connect(pl, "changed", G_CALLBACK(on_changed), &changed);
  GError *err = NULL;
  g_assert_true(wx_places_load(pl, &dropped, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(dropped, ==, dropped_expected);
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, kept);
  guint at = 0;
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++)
    if (cases[i].name != NULL)
      g_assert_cmpstr(wx_places_get_place(pl, at++)->name, ==, cases[i].name);
  g_assert_cmpuint(changed, ==, 1);
  g_assert_false(wx_places_is_dirty(pl));

  /* Loading again replaces the content; the n_dropped argument is optional. */
  g_assert_true(wx_places_load(pl, NULL, NULL));
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, kept);
  g_assert_cmpuint(changed, ==, 2);

  /* Empty array: success, empty list, one signal because it was non-empty. */
  put_text(path, "{\"version\":1,\"places\":[]}");
  g_assert_true(wx_places_load(pl, &dropped, NULL));
  g_assert_cmpuint(dropped, ==, 0);
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, 0);
  g_assert_cmpuint(changed, ==, 3);
  g_assert_true(wx_places_load(pl, NULL, NULL));
  g_assert_cmpuint(changed, ==, 3); /* empty -> empty: nothing to announce */

  /* Invalid UTF-8 and a lone surrogate inside a name: the element is dropped (or the document
   * refused), never a crash and never a message. */
  const char *odd[] = {
    "{\"version\":1,\"places\":[{\"name\":\"a\xff\xfe\",\"lat\":1,\"lon\":2},"
    "{\"name\":\"\xc3\x28\",\"lat\":3,\"lon\":4}]}",
    "{\"version\":1,\"places\":[{\"name\":\"\\ud800\",\"lat\":1,\"lon\":2}]}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(odd); i++) {
    put_text(path, odd[i]);
    if (wx_places_load(pl, &dropped, &err)) {
      /* Whatever is kept must be a usable name. */
      for (guint k = 0; k < wx_places_get_n_places(pl); k++)
        g_assert_true(wx_text_is_usable_name(wx_places_get_place(pl, k)->name, WX_PLACE_NAME_MAX));
      g_assert_cmpuint(wx_places_get_n_places(pl), ==, 0);
    } else {
      g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
    }
    g_clear_error(&err);
  }
}

static void
test_places_load_cap(Fixture *f, gconstpointer unused)
{
  (void)unused;
  GString *doc = g_string_new("{\"version\":1,\"places\":[");
  for (guint i = 0; i < 70; i++) {
    g_autoptr(WxPlace) p = grid_place(i);
    g_string_append_printf(doc, "%s{\"name\":\"N%u\",\"lat\":%.4f,\"lon\":%.4f}", i ? "," : "", i,
                           p->lat, p->lon);
  }
  g_string_append(doc, "]}");
  g_autofree char *path = path_in(f, "places.json");
  put_text(path, doc->str);
  g_string_free(doc, TRUE);
  g_autoptr(WxPlaces) pl = wx_places_new(path);
  guint dropped = 0;
  g_assert_true(wx_places_load(pl, &dropped, NULL));
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, WX_PLACE_MAX);
  g_assert_cmpuint(dropped, ==, 20);
  g_assert_cmpstr(wx_places_get_place(pl, 0)->name, ==, "N0");
  g_assert_cmpstr(wx_places_get_place(pl, 49)->name, ==, "N49");
}

static void
test_places_dirty_and_signals(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "pl.json");
  g_autoptr(WxPlaces) pl = wx_places_new(path);
  g_autoptr(WxPlace) a = make_place("A", 10, 10);
  g_autoptr(WxPlace) b = make_place("B", 20, 20);
  guint changed = 0;
  g_signal_connect(pl, "changed", G_CALLBACK(on_changed), &changed);
  g_assert_false(wx_places_is_dirty(pl));
  g_assert_false(wx_places_add(pl, NULL));
  g_assert_false(wx_places_is_dirty(pl));
  g_assert_true(wx_places_add(pl, a));
  g_assert_true(wx_places_is_dirty(pl));
  g_assert_true(wx_places_save(pl, NULL));
  g_assert_false(wx_places_is_dirty(pl));
  g_assert_false(wx_places_add(pl, a)); /* a rejected edit is not an edit */
  g_assert_false(wx_places_is_dirty(pl));
  g_assert_true(wx_places_add(pl, b));
  g_assert_true(wx_places_save(pl, NULL));
  g_assert_true(wx_places_move(pl, 0, 1));
  g_assert_true(wx_places_is_dirty(pl));
  g_assert_true(wx_places_save(pl, NULL));
  g_assert_true(wx_places_remove(pl, "10.0000,10.0000"));
  g_assert_true(wx_places_is_dirty(pl));
  g_assert_cmpuint(changed, ==, 4);
  /* Saving does not announce anything. */
  g_assert_true(wx_places_save(pl, NULL));
  g_assert_cmpuint(changed, ==, 4);
  /* A successful or failed load leaves the list clean. */
  g_autoptr(WxPlaces) w2 = wx_places_new(path);
  g_assert_true(wx_places_load(w2, NULL, NULL));
  g_assert_false(wx_places_is_dirty(w2));
  g_autofree char *missing = path_in(f, "missing.json");
  g_autoptr(WxPlaces) w3 = wx_places_new(missing);
  g_assert_true(wx_places_add(w3, a));
  g_assert_false(wx_places_load(w3, NULL, NULL));
  g_assert_false(wx_places_is_dirty(w3));
  g_assert_cmpuint(wx_places_get_n_places(w3), ==, 0);
}

static void
test_places_preconditions(void)
{
  guint dropped = 77;
  GError *err = NULL;
  g_autoptr(WxPlaces) pl = wx_places_new("/nonexistent/never-used.json");
  g_autoptr(WxPlace) a = make_place("A", 10, 10);
  g_assert_true(wx_places_add(pl, a));

  /* A NULL or wrong-typed self: critical and the documented return value. */
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_null(wx_places_get_path(NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_cmpuint(wx_places_get_n_places(NULL), ==, 0);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_null(wx_places_get_place(NULL, 0));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_cmpint(wx_places_index_of(NULL, "1.0000,1.0000"), ==, -1);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_false(wx_places_add(NULL, a));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_false(wx_places_remove(NULL, "1.0000,1.0000"));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_false(wx_places_move(NULL, 0, 1));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_false(wx_places_is_dirty(NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_false(wx_places_save(NULL, &err));
  g_test_assert_expected_messages();
  g_assert_no_error(err);
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_false(wx_places_load(NULL, &dropped, &err));
  g_test_assert_expected_messages();
  g_assert_cmpuint(dropped, ==, 77); /* untouched */
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  wx_places_save_async(NULL, NULL, NULL, NULL);
  g_test_assert_expected_messages();
  g_assert_false(WX_IS_PLACES(NULL));

  /* A non-NULL error location that already holds an error. */
  GError *taken = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_FAILED, "taken");
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_places_load(pl, &dropped, &taken));
  g_test_assert_expected_messages();
  g_assert_cmpuint(dropped, ==, 77); /* untouched */
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, 1); /* unchanged */
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_places_save(pl, &taken));
  g_test_assert_expected_messages();
  g_clear_error(&taken);

  /* save_finish with a result that is not ours. */
  g_autoptr(GTask) foreign = g_task_new(pl, NULL, NULL, NULL);
  EXPECT_CRITICAL("*g_async_result_is_tagged*");
  g_assert_false(wx_places_save_finish(pl, G_ASYNC_RESULT(foreign), NULL));
  g_test_assert_expected_messages();
  g_autoptr(WxPlaces) other = wx_places_new("/nonexistent/other.json");
  g_autoptr(GTask) foreign2 = g_task_new(other, NULL, NULL, NULL);
  EXPECT_CRITICAL("*g_task_is_valid*");
  g_assert_false(wx_places_save_finish(pl, G_ASYNC_RESULT(foreign2), NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_PLACES*");
  g_assert_false(wx_places_save_finish(NULL, G_ASYNC_RESULT(foreign), NULL));
  g_test_assert_expected_messages();
}

/* The key functions read at most 24 bytes: unterminated 24-byte buffers at a guard page. */
static void
test_key_guard_pages(void)
{
  g_autoptr(WxPlaces) pl = wx_places_new("/nonexistent/never-used.json");
  g_autoptr(WxPlace) miami = make_place("Miami", 25.7617, -80.1918);
  g_assert_true(wx_places_add(pl, miami));
  g_autoptr(WxCache) cache = wx_cache_new("/nonexistent/never-used.json");
  g_autoptr(WxForecast) fc = make_forecast(miami, 3, 0, 0, 0, 0);
  g_assert_true(wx_cache_put(cache, fc, T0 * 1000));
  g_autoptr(WxSettings) st = wx_settings_new("/nonexistent/never-used.json");

  static const char key[] = "25.7617,-80.1918";
  Guard g;
  for (guint first = 0; first < 256; first++) {
    for (gsize n = 24; n <= 24; n++) {
      char *buf = guard_alloc(&g, n);
      memset(buf, '1', n);
      memcpy(buf + 1, key + 1, sizeof key - 2);
      buf[0] = (char)first; /* no NUL anywhere in the 24 bytes unless first == 0 */
      g_assert_cmpint(wx_places_index_of(pl, buf), ==, -1);
      g_assert_false(wx_places_remove(pl, buf));
      WxForecast *got = wx_cache_get(cache, buf, NULL);
      g_assert_null(got);
      g_assert_false(wx_cache_remove(cache, buf));
      g_assert_false(wx_settings_set_selected(st, buf));
      guard_free(&g);
    }
  }
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, 1);
  g_assert_cmpuint(wx_cache_get_n_places(cache), ==, 1);
  g_assert_null(wx_settings_get_selected(st));

  /* A valid key that ends exactly at the guard page (its NUL is the last byte). */
  char *buf = guard_alloc(&g, sizeof key);
  memcpy(buf, key, sizeof key);
  g_assert_cmpint(wx_places_index_of(pl, buf), ==, 0);
  WxForecast *got = wx_cache_get(cache, buf, NULL);
  g_assert_nonnull(got);
  wx_forecast_unref(got);
  g_assert_true(wx_settings_set_selected(st, buf));
  g_assert_cmpstr(wx_settings_get_selected(st), ==, key);
  guard_free(&g);

  /* Provider ids: at most WX_ID_MAX + 1 bytes are read. */
  for (guint first = 0; first < 256; first++) {
    char *ibuf = guard_alloc(&g, WX_ID_MAX + 1);
    memset(ibuf, 'a', WX_ID_MAX + 1);
    ibuf[0] = (char)first;
    g_assert_false(wx_settings_is_provider_disabled(st, ibuf));
    g_assert_false(wx_settings_set_provider_disabled(st, ibuf, TRUE));
    g_assert_false(wx_settings_set_provider_disabled(st, ibuf, FALSE));
    guard_free(&g);
  }
}

/* ------------------------------------------------------------------------ */
/* WxSettings                                                               */
/* ------------------------------------------------------------------------ */

static void
test_settings_basic(void)
{
  g_autoptr(WxSettings) st = wx_settings_new("/nonexistent/never-used.json");
  guint changed = 0;
  g_signal_connect(st, "changed", G_CALLBACK(on_changed), &changed);
  /* Defaults. */
  g_assert_cmpint(wx_settings_get_units(st), ==, WX_UNITS_IMPERIAL);
  g_assert_null(wx_settings_get_selected(st));
  g_assert_false(wx_settings_is_provider_disabled(st, "open-meteo"));
  g_assert_false(wx_settings_is_dirty(st));
  g_assert_cmpstr(wx_settings_get_path(st), ==, "/nonexistent/never-used.json");

  /* Units. */
  g_assert_false(wx_settings_set_units(st, WX_UNITS_IMPERIAL));
  g_assert_cmpuint(changed, ==, 0);
  g_assert_false(wx_settings_is_dirty(st));
  g_assert_true(wx_settings_set_units(st, WX_UNITS_METRIC));
  g_assert_cmpint(wx_settings_get_units(st), ==, WX_UNITS_METRIC);
  g_assert_cmpuint(changed, ==, 1);
  g_assert_true(wx_settings_is_dirty(st));
  g_assert_false(wx_settings_set_units(st, WX_UNITS_METRIC));
  g_assert_cmpuint(changed, ==, 1);

  /* Providers. */
  g_assert_true(wx_settings_set_provider_disabled(st, "nws", TRUE));
  g_assert_true(wx_settings_is_provider_disabled(st, "nws"));
  g_assert_false(wx_settings_is_provider_disabled(st, "NWS")); /* not a valid id */
  g_assert_false(wx_settings_is_provider_disabled(st, "met-no"));
  g_assert_false(wx_settings_set_provider_disabled(st, "nws", TRUE)); /* already */
  g_assert_cmpuint(changed, ==, 2);
  g_assert_true(wx_settings_set_provider_disabled(st, "met-no", TRUE));
  g_assert_true(wx_settings_set_provider_disabled(st, "nws", FALSE));
  g_assert_false(wx_settings_is_provider_disabled(st, "nws"));
  g_assert_true(wx_settings_is_provider_disabled(st, "met-no"));
  g_assert_false(wx_settings_set_provider_disabled(st, "nws", FALSE)); /* already enabled */
  g_assert_cmpuint(changed, ==, 4);
  const char *bad_ids[] = {"", " ", "NWS", "../x", ".", "..", "-a", "_a", "a b", "a/b", "a\n",
                           "caf\xc3\xa9", "this-id-is-way-longer-than-thirty-two-bytes"};
  for (guint i = 0; i < G_N_ELEMENTS(bad_ids); i++) {
    g_assert_false(wx_settings_set_provider_disabled(st, bad_ids[i], TRUE));
    g_assert_false(wx_settings_set_provider_disabled(st, bad_ids[i], FALSE));
    g_assert_false(wx_settings_is_provider_disabled(st, bad_ids[i]));
  }
  g_assert_false(wx_settings_set_provider_disabled(st, NULL, TRUE));
  g_assert_false(wx_settings_is_provider_disabled(st, NULL));
  g_assert_cmpuint(changed, ==, 4);

  /* The list is capped at WX_SETTINGS_MAX_DISABLED; removing makes room. */
  for (guint i = 0; i < WX_SETTINGS_MAX_DISABLED; i++) {
    g_autofree char *id = g_strdup_printf("p%u", i);
    gboolean ok = wx_settings_set_provider_disabled(st, id, TRUE);
    g_assert_cmpint(ok, ==, i < WX_SETTINGS_MAX_DISABLED - 1); /* met-no already holds a slot */
  }
  g_assert_false(wx_settings_is_provider_disabled(st, "p15"));
  g_assert_true(wx_settings_is_provider_disabled(st, "p14"));
  g_assert_true(wx_settings_set_provider_disabled(st, "p0", FALSE));
  g_assert_true(wx_settings_set_provider_disabled(st, "p15", TRUE));
  g_assert_false(wx_settings_set_provider_disabled(st, "p16", TRUE));
  g_assert_false(wx_settings_set_provider_disabled(st, "p16", FALSE)); /* absent: nothing to do */

  /* Selection. */
  guint before = changed;
  g_assert_true(wx_settings_set_selected(st, "25.7617,-80.1918"));
  g_assert_cmpstr(wx_settings_get_selected(st), ==, "25.7617,-80.1918");
  g_assert_false(wx_settings_set_selected(st, "25.7617,-80.1918"));
  g_assert_true(wx_settings_set_selected(st, "-33.8688,151.2093"));
  g_assert_cmpuint(changed, ==, before + 2);
  g_assert_false(wx_settings_set_selected(st, "garbage"));
  g_assert_cmpstr(wx_settings_get_selected(st), ==, "-33.8688,151.2093");
  g_assert_true(wx_settings_set_selected(st, NULL));
  g_assert_null(wx_settings_get_selected(st));
  g_assert_false(wx_settings_set_selected(st, NULL));
  g_assert_cmpuint(changed, ==, before + 3);
}

static void
test_settings_selected_keys(void)
{
  g_autoptr(WxSettings) st = wx_settings_new("/nonexistent/never-used.json");
  const char *good[] = {"25.7617,-80.1918", "-33.8688,151.2093", "0.0000,0.0000", "90.0000,180.0000",
                        "-90.0000,-180.0000", "1.0000,2.0000", "-0.0000,-0.0000", "89.9999,179.9999",
                        "5.1234,-7.9999", "12.3456,100.0000"};
  for (guint i = 0; i < G_N_ELEMENTS(good); i++) {
    g_assert_true(wx_settings_set_selected(st, good[i]));
    g_assert_cmpstr(wx_settings_get_selected(st), ==, good[i]);
    g_assert_true(wx_settings_set_selected(st, NULL));
  }
  const char *bad[] = {
    "", ",", "1,2", "1.0,2.0", "1.0000,2.0", "1.00000,2.0000", ".5000,1.0000", "1.0000;2.0000",
    "1.0000, 2.0000", " 1.0000,2.0000", "1.0000,2.0000 ", "1.0000,2.0000\n", "+1.0000,2.0000",
    "1.0000,+2.0000", "--1.0000,2.0000", "1.0000,2.0000,3.0000", "1.0000", "1.0000,",
    ",2.0000", "91.0000,0.0000", "-91.0000,0.0000", "0.0000,181.0000", "0.0000,-181.0000",
    "1000.0000,0.0000", "0.0000,1000.0000", "90.0001,0.0000", "1e1.0000,2.0000", "nan,nan",
    "inf,inf", "0x1.0000,2.0000", "1.0000,2.000\xc3\xa9", "../../../etc/p,1.0000", "a.0000,1.0000",
    "1.0000,1.0000/", "1.0000,1.0000%00", "\"1.0000,2.0000\"", "1.0000,-",
    "123456789012345678901234", "1.0000,2.0000xxxxxxxxxxxxxxxxxxxxxxxxxxx",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_test_message("%s", bad[i]);
    g_assert_false(wx_settings_set_selected(st, bad[i]));
    g_assert_null(wx_settings_get_selected(st));
  }
  g_assert_true(wx_settings_is_dirty(st)); /* by the accepted keys above, not by the rejected ones */
}

typedef struct {
  const char *json;
  WxUnits units;
  const char *selected; /* NULL: none */
  const char *disabled; /* comma-separated, in the probe set below */
} SettingsCase;

static void
test_settings_load_partial(Fixture *f, gconstpointer unused)
{
  (void)unused;
  /* Only these ids are probed, so cases must use them. */
  static const char *const probe[] = {"a", "b", "ok", "p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7",
                                      "p8", "p9", "p10", "p11", "p12", "p13", "p14", "p15", "p16",
                                      "p17", "p18", "p19"};
  const SettingsCase cases[] = {
    {"{\"version\":1}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"units\":\"metric\"}", WX_UNITS_METRIC, NULL, ""},
    {"{\"version\":1,\"units\":\"imperial\"}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"units\":\"Metric\"}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"units\":\"METRIC\"}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"units\":\"si\"}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"units\":1}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"units\":null}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"units\":[\"metric\"]}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"disabled_providers\":[\"a\",\"b\"]}", WX_UNITS_IMPERIAL, NULL, "a,b"},
    {"{\"version\":1,\"disabled_providers\":[\"a\",\"a\",\"b\",\"a\"]}", WX_UNITS_IMPERIAL, NULL, "a,b"},
    {"{\"version\":1,\"disabled_providers\":[\"A\",\"../x\",\"\",\"a b\",5,null,[],{},true,\"ok\"]}",
     WX_UNITS_IMPERIAL, NULL, "ok"},
    {"{\"version\":1,\"disabled_providers\":\"a\"}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"disabled_providers\":{\"a\":1}}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"disabled_providers\":null}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"disabled_providers\":[]}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"disabled_providers\":[\"p0\",\"p1\",\"p2\",\"p3\",\"p4\",\"p5\",\"p6\",\"p7\","
     "\"p8\",\"p9\",\"p10\",\"p11\",\"p12\",\"p13\",\"p14\",\"p15\",\"p16\",\"p17\",\"p18\",\"p19\"]}",
     WX_UNITS_IMPERIAL, NULL, "p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15"},
    {"{\"version\":1,\"selected\":\"25.7617,-80.1918\"}", WX_UNITS_IMPERIAL, "25.7617,-80.1918", ""},
    {"{\"version\":1,\"selected\":\"1,2\"}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"selected\":\"95.0000,2.0000\"}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"selected\":5}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"selected\":null}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"selected\":\"\"}", WX_UNITS_IMPERIAL, NULL, ""},
    /* An escaped backslash followed by "u0000" is plain text, not a NUL escape. */
    {"{\"version\":1,\"selected\":\"1.0000,2.0000\\\\u0000x\"}", WX_UNITS_IMPERIAL, NULL, ""},
    {"{\"version\":1,\"units\":\"metric\",\"disabled_providers\":[\"b\"],\"selected\":\"-1.5000,2.2500\","
     "\"unknown\":{\"x\":[1,2,3]}}", WX_UNITS_METRIC, "-1.5000,2.2500", "b"},
    {"{\"unknown\":1,\"version\":1,\"units\":\"metric\"}", WX_UNITS_METRIC, NULL, ""},
  };
  g_autofree char *path = path_in(f, "settings.json");
  g_autoptr(WxSettings) st = wx_settings_new(path);
  guint changed = 0;
  g_signal_connect(st, "changed", G_CALLBACK(on_changed), &changed);
  for (guint c = 0; c < G_N_ELEMENTS(cases); c++) {
    g_test_message("%s", cases[c].json);
    /* Start from non-default values: the load must replace them. */
    g_assert_true(wx_settings_set_units(st, WX_UNITS_METRIC) ||
                  wx_settings_get_units(st) == WX_UNITS_METRIC);
    wx_settings_set_provider_disabled(st, "b", TRUE);
    put_text(path, cases[c].json);
    guint before = changed;
    GError *err = NULL;
    g_assert_true(wx_settings_load(st, &err));
    g_assert_no_error(err);
    g_assert_cmpuint(changed, ==, before + 1);
    g_assert_false(wx_settings_is_dirty(st));
    g_assert_cmpint(wx_settings_get_units(st), ==, cases[c].units);
    g_assert_cmpstr(wx_settings_get_selected(st), ==, cases[c].selected);
    guint n_expected = 0, n_found = 0;
    for (const char *p = cases[c].disabled; *p != '\0';) {
      const char *end = strchr(p, ',');
      g_autofree char *id = end ? g_strndup(p, (gsize)(end - p)) : g_strdup(p);
      g_assert_true(wx_settings_is_provider_disabled(st, id));
      n_expected++;
      p = end ? end + 1 : p + strlen(p);
    }
    for (guint i = 0; i < G_N_ELEMENTS(probe); i++)
      n_found += wx_settings_is_provider_disabled(st, probe[i]);
    g_assert_cmpuint(n_found, ==, n_expected);
  }

  /* A failing load resets to the defaults and announces it, once. */
  wx_settings_set_units(st, WX_UNITS_METRIC);
  guint before = changed;
  put_text(path, "garbage");
  g_assert_false(wx_settings_load(st, NULL));
  g_assert_cmpuint(changed, ==, before + 1);
  g_assert_cmpint(wx_settings_get_units(st), ==, WX_UNITS_IMPERIAL);
}

static void
test_settings_preconditions(void)
{
  g_autoptr(WxSettings) st = wx_settings_new("/nonexistent/never-used.json");
  GError *err = NULL;
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_null(wx_settings_get_path(NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_cmpint(wx_settings_get_units(NULL), ==, WX_UNITS_IMPERIAL);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_false(wx_settings_set_units(NULL, WX_UNITS_METRIC));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC*");
  g_assert_false(wx_settings_set_units(st, (WxUnits)7));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC*");
  g_assert_false(wx_settings_set_units(st, (WxUnits)-1));
  g_test_assert_expected_messages();
  g_assert_cmpint(wx_settings_get_units(st), ==, WX_UNITS_IMPERIAL);
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_false(wx_settings_is_provider_disabled(NULL, "nws"));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_false(wx_settings_set_provider_disabled(NULL, "nws", TRUE));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_null(wx_settings_get_selected(NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_false(wx_settings_set_selected(NULL, "1.0000,2.0000"));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_false(wx_settings_is_dirty(NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_false(wx_settings_load(NULL, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_false(wx_settings_save(NULL, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  wx_settings_save_async(NULL, NULL, NULL, NULL);
  g_test_assert_expected_messages();
  g_assert_no_error(err);
  GError *taken = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_FAILED, "taken");
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_settings_load(st, &taken));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_settings_save(st, &taken));
  g_test_assert_expected_messages();
  g_clear_error(&taken);
  g_autoptr(GTask) foreign = g_task_new(st, NULL, NULL, NULL);
  EXPECT_CRITICAL("*g_async_result_is_tagged*");
  g_assert_false(wx_settings_save_finish(st, G_ASYNC_RESULT(foreign), NULL));
  g_test_assert_expected_messages();
  g_autoptr(WxSettings) other = wx_settings_new("/nonexistent/other.json");
  g_autoptr(GTask) foreign2 = g_task_new(other, NULL, NULL, NULL);
  EXPECT_CRITICAL("*g_task_is_valid*");
  g_assert_false(wx_settings_save_finish(st, G_ASYNC_RESULT(foreign2), NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_SETTINGS*");
  g_assert_false(wx_settings_save_finish(NULL, G_ASYNC_RESULT(foreign), NULL));
  g_test_assert_expected_messages();
}

static void
test_settings_roundtrip(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "cfg/weather/settings.json");
  g_autoptr(WxSettings) st = wx_settings_new(path);
  g_assert_true(wx_settings_set_units(st, WX_UNITS_METRIC));
  g_assert_true(wx_settings_set_provider_disabled(st, "nws", TRUE));
  g_assert_true(wx_settings_set_provider_disabled(st, "met-no", TRUE));
  g_assert_true(wx_settings_set_selected(st, "-33.8688,151.2093"));
  g_assert_true(wx_settings_save(st, NULL));
  g_autofree char *text = read_all(path);
  g_assert_cmpstr(text, ==,
                  "{\n  \"version\": 1,\n  \"units\": \"metric\",\n"
                  "  \"disabled_providers\": [\"nws\", \"met-no\"],\n"
                  "  \"selected\": \"-33.8688,151.2093\"\n}\n");
  g_autoptr(WxSettings) back = wx_settings_new(path);
  g_assert_true(wx_settings_load(back, NULL));
  g_assert_cmpint(wx_settings_get_units(back), ==, WX_UNITS_METRIC);
  g_assert_true(wx_settings_is_provider_disabled(back, "nws"));
  g_assert_true(wx_settings_is_provider_disabled(back, "met-no"));
  g_assert_false(wx_settings_is_provider_disabled(back, "open-meteo"));
  g_assert_cmpstr(wx_settings_get_selected(back), ==, "-33.8688,151.2093");

  /* Defaults: no "selected" member, empty list. */
  g_autoptr(WxSettings) def = wx_settings_new(path);
  g_assert_true(wx_settings_save(def, NULL));
  g_autofree char *text2 = read_all(path);
  g_assert_cmpstr(text2, ==,
                  "{\n  \"version\": 1,\n  \"units\": \"imperial\",\n  \"disabled_providers\": []\n}\n");
}

/* ------------------------------------------------------------------------ */
/* WxCache                                                                  */
/* ------------------------------------------------------------------------ */

static gint64
now_ms(void)
{
  return g_get_real_time() / 1000;
}

static void
assert_refcount(WxForecast *f, int expected)
{
  g_assert_true(g_atomic_ref_count_compare(&f->ref_count, expected));
}

static void
test_cache_put_get_age(void)
{
  g_autoptr(WxCache) c = wx_cache_new("/nonexistent/never-used.json");
  g_autoptr(WxPlace) miami = make_place("Miami", 25.7617, -80.1918);
  g_autoptr(WxForecast) f1 = make_forecast(miami, 24, 4, 3, 2, 1);
  g_autoptr(WxForecast) f2 = make_forecast(miami, 24, 4, 3, 2, 2);
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, 0);
  g_assert_false(wx_cache_is_dirty(c));
  g_assert_null(wx_cache_get(c, "25.7617,-80.1918", NULL));

  gint64 age = 12345;
  g_assert_null(wx_cache_get(c, "25.7617,-80.1918", &age));
  g_assert_cmpint(age, ==, 12345); /* untouched on a miss */

  gint64 t = now_ms();
  g_assert_true(wx_cache_put(c, f1, t - 5000));
  g_assert_true(wx_cache_is_dirty(c));
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, 1);
  assert_refcount(f1, 2); /* the caller and the cache */

  WxForecast *got = wx_cache_get(c, "25.7617,-80.1918", &age);
  g_assert_true(got == f1); /* immutable: shared, not copied */
  assert_refcount(f1, 3);
  g_assert_cmpint(age, >=, 5000);
  g_assert_cmpint(age, <, 5000 + 10000);
  wx_forecast_unref(got);
  got = wx_cache_get(c, "25.7617,-80.1918", NULL); /* age is optional */
  wx_forecast_unref(got);

  /* Putting the same forecast again keeps one reference; a replacement releases the old one. */
  g_assert_true(wx_cache_put(c, f1, t - 4000));
  assert_refcount(f1, 2);
  g_assert_true(wx_cache_put(c, f2, t - 1000));
  assert_refcount(f1, 1);
  assert_refcount(f2, 2);
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, 1);
  got = wx_cache_get(c, "25.7617,-80.1918", &age);
  g_assert_true(got == f2);
  g_assert_cmpint(age, >=, 1000);
  g_assert_cmpint(age, <, 11000);
  wx_forecast_unref(got);

  /* The age is clamped at 0 for a time in the future, and large for an old one. */
  g_assert_true(wx_cache_put(c, f2, t + 3600 * 1000));
  got = wx_cache_get(c, "25.7617,-80.1918", &age);
  g_assert_cmpint(age, ==, 0);
  wx_forecast_unref(got);
  g_assert_true(wx_cache_put(c, f2, WX_TIME_MIN_S * 1000));
  got = wx_cache_get(c, "25.7617,-80.1918", &age);
  g_assert_cmpint(age, >, 3600 * 24 * 365 * G_GINT64_CONSTANT(1000));
  wx_forecast_unref(got);
  g_assert_true(wx_cache_put(c, f2, WX_TIME_MAX_S * 1000 - 1));
  got = wx_cache_get(c, "25.7617,-80.1918", &age);
  g_assert_cmpint(age, ==, 0);
  wx_forecast_unref(got);

  /* Removing releases the cache's reference. */
  g_assert_true(wx_cache_remove(c, "25.7617,-80.1918"));
  assert_refcount(f2, 1);
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, 0);
  g_assert_false(wx_cache_remove(c, "25.7617,-80.1918"));
  g_assert_false(wx_cache_remove(c, NULL));
  g_assert_false(wx_cache_remove(c, "nope"));
  g_assert_null(wx_cache_get(c, NULL, &age));
  g_assert_null(wx_cache_get(c, "", &age));
  g_assert_null(wx_cache_get(c, "123456789012345678901234567890", &age));
  /* A forecast in the cache outlives the caller's reference. */
  g_autoptr(WxForecast) f3 = make_forecast(miami, 5, 0, 0, 0, 3);
  g_assert_true(wx_cache_put(c, f3, t));
  assert_refcount(f3, 2);
}

static void
test_cache_limits_reject(void)
{
  g_autoptr(WxCache) c = wx_cache_new("/nonexistent/never-used.json");
  g_autoptr(WxPlace) p = make_place("Limits", 25.0, -80.0);
  gint64 t = now_ms();
  g_autoptr(WxForecast) ok = make_forecast(p, WX_CACHE_MAX_HOURS, WX_CACHE_MAX_QUARTERS,
                                           WX_FORECAST_MAX_DAYS, WX_FORECAST_MAX_SOURCES, 0);
  g_autoptr(WxForecast) many_hours = make_forecast(p, WX_CACHE_MAX_HOURS + 1, 0, 0, 0, 0);
  g_autoptr(WxForecast) many_quarters = make_forecast(p, 3, WX_CACHE_MAX_QUARTERS + 1, 0, 0, 0);
  g_autoptr(WxForecast) max_forecast = make_forecast(p, WX_FORECAST_MAX_HOURS, 0, 0, 0, 0);
  g_assert_false(wx_cache_put(c, many_hours, t));
  g_assert_false(wx_cache_put(c, many_quarters, t));
  g_assert_false(wx_cache_put(c, max_forecast, t));
  g_assert_false(wx_cache_put(c, NULL, t));
  assert_refcount(many_hours, 1);
  const gint64 bad_times[] = {-1, G_MININT64, G_MAXINT64, WX_TIME_MIN_S * 1000 - 1,
                              WX_TIME_MAX_S * 1000, WX_TIME_MAX_S * 1000 + 1, 0};
  for (guint i = 0; i < G_N_ELEMENTS(bad_times); i++)
    g_assert_false(wx_cache_put(c, ok, bad_times[i]));
  assert_refcount(ok, 1);
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, 0);
  g_assert_false(wx_cache_is_dirty(c));
  /* The boundary values are accepted. */
  g_assert_true(wx_cache_put(c, ok, WX_TIME_MIN_S * 1000));
  g_assert_true(wx_cache_put(c, ok, WX_TIME_MAX_S * 1000 - 1));
  g_assert_true(wx_cache_put(c, ok, t));
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, 1);
  /* A rejected put does not disturb the stored entry. */
  g_assert_false(wx_cache_put(c, many_hours, t));
  WxForecast *got = wx_cache_get(c, "25.0000,-80.0000", NULL);
  g_assert_true(got == ok);
  wx_forecast_unref(got);
}

static char *
key_of_grid(guint i)
{
  g_autoptr(WxPlace) p = grid_place(i);
  return wx_place_key(p);
}

static void
put_grid(WxCache *c, guint i)
{
  g_autoptr(WxPlace) p = grid_place(i);
  g_autoptr(WxForecast) f = make_forecast(p, 3, 0, 0, 0, i);
  g_assert_true(wx_cache_put(c, f, T0 * 1000 + i));
}

static gboolean
has_grid(WxCache *c, guint i)
{
  g_autofree char *key = key_of_grid(i);
  WxForecast *f = wx_cache_get(c, key, NULL);
  if (f != NULL)
    wx_forecast_unref(f);
  return f != NULL;
}

static void
test_cache_lru(void)
{
  g_autoptr(WxCache) c = wx_cache_new("/nonexistent/never-used.json");
  for (guint i = 0; i < WX_CACHE_MAX_PLACES; i++)
    put_grid(c, i);
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, WX_CACHE_MAX_PLACES);
  /* Order now (oldest first): 0..49. get(0) touches it: 1..49,0. */
  g_autofree char *k0 = key_of_grid(0);
  WxForecast *f0 = wx_cache_get(c, k0, NULL);
  wx_forecast_unref(f0);
  /* A get does not mark the cache dirty by itself. */
  g_autoptr(WxCache) c2 = wx_cache_new("/nonexistent/never-used.json");
  put_grid(c2, 0);
  g_autoptr(GError) err = NULL;
  g_autofree char *dir = g_dir_make_tmp("wx-lru-XXXXXX", &err);
  g_assert_no_error(err);
  g_autofree char *p2 = g_build_filename(dir, "c.json", NULL);
  g_autoptr(WxCache) c3 = wx_cache_new(p2);
  put_grid(c3, 0);
  g_assert_true(wx_cache_save(c3, NULL));
  g_assert_false(wx_cache_is_dirty(c3));
  WxForecast *tmp = wx_cache_get(c3, k0, NULL);
  wx_forecast_unref(tmp);
  g_assert_false(wx_cache_is_dirty(c3));
  rm_rf(dir);

  put_grid(c, 50); /* evicts 1 */
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, WX_CACHE_MAX_PLACES);
  g_assert_false(has_grid(c, 1)); /* (this lookup of an absent key touches nothing) */
  g_assert_true(has_grid(c, 0));
  /* Order: 2..49,0,50 -> the has_grid() calls touched 0: 2..49,50,0. Replace 2 (touch): 3..49,50,0,2. */
  put_grid(c, 2);
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, WX_CACHE_MAX_PLACES); /* a replacement adds no entry */
  put_grid(c, 51); /* evicts 3 */
  g_assert_false(has_grid(c, 3));
  g_assert_true(has_grid(c, 4));
  g_assert_true(has_grid(c, 2));
  /* Removing frees a slot: no eviction on the next new key. */
  g_autofree char *k5 = key_of_grid(5);
  g_assert_true(wx_cache_remove(c, k5));
  put_grid(c, 52);
  g_assert_true(has_grid(c, 4));
  g_assert_false(has_grid(c, 5));
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, WX_CACHE_MAX_PLACES);
}

/* Builds a forecast with hand-picked extreme values. */
static WxForecast *
make_extreme_forecast(const WxPlace *place)
{
  WxBlendHour hours[6];
  memset(hours, 0, sizeof hours);
  double tiny = 1.2345678901234567e-300;
  for (guint i = 0; i < G_N_ELEMENTS(hours); i++) {
    WxBlendHour *h = &hours[i];
    h->t_s = T0 + (gint64)i * 3600;
    h->temp_c = i == 0 ? -0.0 : i == 1 ? -100.0 : i == 2 ? 70.0 : i == 3 ? -tiny : 0.1 + i;
    h->feels_c = i == 0 ? 69.99999999999999 : NAN;
    h->precip_mm = i == 0 ? 0.0 : i == 1 ? WX_PRECIP_MAX_MM_H : tiny;
    h->precip_mm_max = i == 1 ? 5e-324 : 1.0 / 3.0;
    h->precip_prob = i == 0 ? 100.0 : 0.30000000000000004;
    h->cloud_pct = 55.5;
    h->wind_kmh = WX_WIND_MAX_KMH;
    h->gust_kmh = NAN;
    h->humidity_pct = 99.99999999999999;
    h->temp_spread_c = i == 0 ? -0.0 : 0.0;
    h->n_members = i == 0 ? 0 : 255;
    h->condition = (WxCondition)(WX_COND_COUNT - 1 - i);
    h->is_day = i % 2 == 0;
  }
  WxQuarter quarters[2] = {{T0, -0.0}, {T0 + 900, WX_PRECIP_MAX_MM_H}};
  WxDay days[1];
  memset(days, 0, sizeof days);
  days[0].start_s = T0 - 86400;
  days[0].temp_max_c = 70.0;
  days[0].temp_min_c = -100.0;
  days[0].precip_mm = WX_PRECIP_MAX_MM_DAY;
  days[0].precip_prob_max = NAN;
  days[0].cloud_pct = 0.0;
  days[0].condition = WX_COND_UNKNOWN;
  g_autoptr(WxSourceStatus) s0 = wx_source_status_new("a", "", "", "", WX_SRC_OK, -1, 0, NULL);
  g_autoptr(WxSourceStatus) s1 = wx_source_status_new(
    "b.c_d-e", "Name \"q\" \\ \xc3\xa9\xe6\x97\xa5 \xf0\x9f\x9a\x80", "Attribution / 100%",
    "https://example.org:8443/a/b?c=d&e=%C3%A9#frag", WX_SRC_FAILED, WX_ERROR_UNSUPPORTED,
    G_MAXUINT, NULL);
  g_assert_nonnull(s0);
  g_assert_nonnull(s1);
  WxSourceStatus sources[2] = {*s0, *s1};
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, WX_TIME_MAX_S - 1, hours, G_N_ELEMENTS(hours), quarters, 2,
                                  days, 1, sources, 2, &err);
  g_assert_no_error(err);
  g_assert_nonnull(f);
  return f;
}

static void
test_cache_roundtrip(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "cfg/weather/forecasts.json");
  g_autoptr(WxCache) c = wx_cache_new(path);
  g_autoptr(WxPlace) p1 = make_place("Miami", 25.7617, -80.1918);
  g_autoptr(WxPlace) p2 = make_place("Extreme \"quoted\" \\ \xc3\xbc", -90.0, 180.0);
  g_autoptr(WxPlace) p3 = make_place("Empty", 0.0, 0.0);
  g_autoptr(WxPlace) p4 = make_place("Max", 51.5, -0.12);
  g_autoptr(WxForecast) fa = make_forecast(p1, WX_CACHE_MAX_HOURS, WX_CACHE_MAX_QUARTERS,
                                           WX_FORECAST_MAX_DAYS, WX_FORECAST_MAX_SOURCES, 7);
  g_autoptr(WxForecast) fb = make_extreme_forecast(p2);
  g_autoptr(WxForecast) fc = make_forecast(p3, 0, 0, 0, 0, 0);
  g_autoptr(WxForecast) fd = make_forecast(p4, 1, 1, 1, 1, 9);
  gint64 stamps[4] = {T0 * 1000 + 1, 4133980799999, WX_TIME_MIN_S * 1000, 1};
  stamps[3] = now_ms();
  WxForecast *all[4] = {fa, fb, fc, fd};
  const char *keys[4] = {"25.7617,-80.1918", "-90.0000,180.0000", "0.0000,0.0000", "51.5000,-0.1200"};
  g_assert_true(wx_cache_put(c, fa, stamps[0]));
  g_assert_true(wx_cache_put(c, fb, stamps[1]));
  g_assert_true(wx_cache_put(c, fc, stamps[2]));
  g_assert_true(wx_cache_put(c, fd, stamps[3]));
  GError *err = NULL;
  g_assert_true(wx_cache_save(c, &err));
  g_assert_no_error(err);
  g_assert_false(wx_cache_is_dirty(c));
  g_assert_cmpuint(file_mode(path), ==, 0600);

  g_autoptr(WxCache) back = wx_cache_new(path);
  g_assert_true(wx_cache_load(back, &err));
  g_assert_no_error(err);
  g_assert_false(wx_cache_is_dirty(back));
  g_assert_cmpuint(wx_cache_get_n_places(back), ==, 4);
  for (guint i = 0; i < 4; i++) {
    gint64 age = -1;
    g_autoptr(WxForecast) got = wx_cache_get(back, keys[i], &age);
    g_assert_nonnull(got);
    assert_forecast_equal(all[i], got);
    /* The fetch time survived: the age matches the stamp (the clock moved by at most seconds). */
    gint64 expect_age = MAX(0, now_ms() - stamps[i]);
    g_assert_cmpint(age, >=, expect_age - 10000);
    g_assert_cmpint(age, <=, expect_age);
  }
  /* The stored recency order survives: 4 entries, oldest first = fa. Fill to the cap with
   * 47 more and one more evicts fa first. */
  for (guint i = 0; i < 46; i++)
    put_grid(back, i);
  g_assert_cmpuint(wx_cache_get_n_places(back), ==, 50);
  /* The has/get calls above touched everything; use a fresh load for the order check. */
  g_autoptr(WxCache) order = wx_cache_new(path);
  g_assert_true(wx_cache_load(order, NULL));
  for (guint i = 0; i < 46; i++)
    put_grid(order, i);
  g_assert_cmpuint(wx_cache_get_n_places(order), ==, 50);
  put_grid(order, 46); /* evicts the least recently used of the loaded: fa */
  g_assert_null(wx_cache_get(order, keys[0], NULL));
  g_autoptr(WxForecast) kept = wx_cache_get(order, keys[1], NULL);
  g_assert_nonnull(kept);
}

static void
test_cache_double_precision(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "c.json");
  g_autoptr(WxCache) c = wx_cache_new(path);
  g_autoptr(WxPlace) p = make_place("Random", 33.3, 44.4);
  GRand *r = g_rand_new_with_seed(99);
  WxBlendHour hours[WX_CACHE_MAX_HOURS];
  for (guint i = 0; i < WX_CACHE_MAX_HOURS; i++) {
    WxBlendHour *h = &hours[i];
    memset(h, 0, sizeof *h);
    h->t_s = T0 + (gint64)i * 3600;
    h->temp_c = g_rand_double_range(r, WX_TEMP_MIN_C, WX_TEMP_MAX_C);
    h->feels_c = g_rand_double_range(r, -1e-3, 1e-3);
    h->precip_mm = g_rand_double_range(r, 0, 1e-9);
    h->precip_mm_max = g_rand_double_range(r, 0, WX_PRECIP_MAX_MM_H);
    h->precip_prob = g_rand_double_range(r, 0, 100);
    h->cloud_pct = g_rand_double_range(r, 0, 100);
    h->wind_kmh = g_rand_double_range(r, 0, WX_WIND_MAX_KMH);
    h->gust_kmh = g_rand_double_range(r, 0, WX_WIND_MAX_KMH);
    h->humidity_pct = g_rand_double_range(r, 0, 100);
    h->temp_spread_c = g_rand_double_range(r, 0, WX_TEMP_SPREAD_MAX_C);
    h->condition = WX_COND_RAIN;
  }
  g_rand_free(r);
  GError *err = NULL;
  g_autoptr(WxForecast) fc = wx_forecast_new(p, T0, hours, WX_CACHE_MAX_HOURS, NULL, 0, NULL, 0, NULL, 0, &err);
  g_assert_no_error(err);
  g_assert_true(wx_cache_put(c, fc, T0 * 1000));
  g_assert_true(wx_cache_save(c, NULL));
  g_autoptr(WxCache) back = wx_cache_new(path);
  g_assert_true(wx_cache_load(back, NULL));
  g_autoptr(WxForecast) got = wx_cache_get(back, "33.3000,44.4000", NULL);
  g_assert_nonnull(got);
  assert_forecast_equal(fc, got);
}

/* Replaces the first match of @pattern in @text; asserts that there is one. */
static char *
mutate_re(const char *text, const char *pattern, const char *replacement)
{
  g_autoptr(GError) err = NULL;
  g_autoptr(GRegex) re = g_regex_new(pattern, G_REGEX_DOTALL, 0, &err);
  g_assert_no_error(err);
  g_autoptr(GMatchInfo) mi = NULL;
  g_assert_true(g_regex_match(re, text, 0, &mi));
  gint start, end;
  g_assert_true(g_match_info_fetch_pos(mi, 0, &start, &end));
  GString *out = g_string_new_len(text, start);
  g_string_append(out, replacement);
  g_string_append(out, text + end);
  return g_string_free(out, FALSE);
}

/* The inner text of the single entry the cache writes for @forecast. */
static char *
entry_text(Fixture *f, WxForecast *forecast, gint64 fetched_ms)
{
  g_autofree char *path = path_in(f, "entry.json");
  g_autoptr(WxCache) c = wx_cache_new(path);
  g_assert_true(wx_cache_put(c, forecast, fetched_ms));
  g_assert_true(wx_cache_save(c, NULL));
  g_autofree char *text = read_all(path);
  const char *prefix = "{\"version\":1,\"entries\":[";
  g_assert_true(g_str_has_prefix(text, prefix));
  g_assert_true(g_str_has_suffix(text, "]}\n"));
  return g_strndup(text + strlen(prefix), strlen(text) - strlen(prefix) - 3);
}

static char *
make_doc(const char *const *entries, guint n)
{
  GString *s = g_string_new("{\"version\":1,\"entries\":[");
  for (guint i = 0; i < n; i++)
    g_string_append_printf(s, "%s%s", i ? "," : "", entries[i]);
  g_string_append(s, "]}");
  return g_string_free(s, FALSE);
}

typedef struct {
  const char *pattern; /* regex applied once to the entry text */
  const char *replacement;
  gboolean dropped;    /* the entry must not load */
} Mutation;

static void
test_cache_load_mutations(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autoptr(WxPlace) pa = make_place("A", 10.0, 10.0);
  g_autoptr(WxPlace) pb = make_place("B", 20.0, 20.0);
  g_autoptr(WxForecast) fa = make_forecast(pa, 4, 3, 2, 2, 1);
  g_autoptr(WxForecast) fb = make_forecast(pb, 4, 3, 2, 2, 2);
  g_autofree char *ea = entry_text(f, fa, T0 * 1000);
  g_autofree char *eb = entry_text(f, fb, T0 * 1000);
  const Mutation mutations[] = {
    /* fetch time */
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":-5", TRUE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":0", TRUE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":946684799999", TRUE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":4133980800000", TRUE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":99999999999999999", TRUE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":1.5e12", TRUE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":\"x\"", TRUE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":null", TRUE},
    {"\"fetched_at_ms\":[0-9]+,", "", TRUE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":946684800000", FALSE},
    {"\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":4133980799999", FALSE},
    /* forecast object and its scalar members */
    {"\"forecast\":", "\"forecastx\":", TRUE},
    {"\"forecast\":\\{", "\"forecast\":[],\"fx\":{", TRUE},
    {"\"generated_s\":[0-9]+", "\"generated_s\":\"1\"", TRUE},
    {"\"generated_s\":[0-9]+", "\"generated_s\":5", TRUE},
    {"\"generated_s\":[0-9]+", "\"generated_s\":4133980800", TRUE},
    {"\"generated_s\":[0-9]+,", "", TRUE},
    /* arrays of the wrong type or missing */
    {"\"hours\":\\[", "\"hours\":1,\"hx\":[", TRUE},
    {"\"quarters\":\\[", "\"quarters\":null,\"qx\":[", TRUE},
    {"\"days\":\\[", "\"days\":{},\"dx\":[", TRUE},
    {"\"sources\":\\[", "\"sources\":\"s\",\"sx\":[", TRUE},
    {"\"sources\":\\[", "\"sourcesx\":[", TRUE},
    /* hours */
    {"\\{\"t\":[0-9]+,\"temp\"", "{\"t\":1,\"temp\"", TRUE},
    {"\\{\"t\":[0-9]+,\"temp\"", "{\"t\":\"x\",\"temp\"", TRUE},
    {"\\{\"t\":[0-9]+,\"temp\"", "{\"temp\"", TRUE},
    {"\\{\"t\":[0-9]+,\"temp\"", "{\"t\":1.5,\"temp\"", TRUE},
    {"\"temp\":[^,]+,", "\"temp\":\"hot\",", TRUE},
    {"\"temp\":[^,]+,", "\"temp\":true,", TRUE},
    {"\"temp\":[^,]+,", "\"temp\":[1],", TRUE},
    {"\"temp\":[^,]+,", "", TRUE},
    {"\"spread\":[^,]+,", "\"spread\":{},", TRUE},
    {"\"members\":[0-9]+", "\"members\":256", TRUE},
    {"\"members\":[0-9]+", "\"members\":-1", TRUE},
    {"\"members\":[0-9]+", "\"members\":2.5", TRUE},
    {"\"members\":[0-9]+", "\"members\":255", FALSE},
    {"\"cond\":[0-9]+,\"day\"", "\"cond\":15,\"day\"", TRUE},
    {"\"cond\":[0-9]+,\"day\"", "\"cond\":-1,\"day\"", TRUE},
    {"\"cond\":[0-9]+,\"day\"", "\"cond\":\"rain\",\"day\"", TRUE},
    {"\"cond\":[0-9]+,\"day\"", "\"cond\":14,\"day\"", FALSE},
    {"\"day\":(true|false)", "\"day\":1", TRUE},
    {"\"day\":(true|false)", "\"day\":null", TRUE},
    {"\"day\":(true|false)", "\"day\":\"true\"", TRUE},
    /* numbers out of range are normalised to NAN, not rejected */
    {"\"temp\":[^,]+,", "\"temp\":1e9,", FALSE},
    {"\"temp\":[^,]+,", "\"temp\":-1e300,", FALSE},
    {"\"prob\":[^,]+,", "\"prob\":150,", FALSE},
    {"\"wind\":[^,]+,", "\"wind\":-5,", FALSE},
    {"\"temp\":[^,]+,", "\"temp\":null,", FALSE},
    /* quarters */
    {"\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1,2,3]", TRUE},
    {"\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1]", TRUE},
    {"\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[\"a\",1]", TRUE},
    {"\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[{\"t\":1}", TRUE},
    {"\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1767999900,null]", TRUE},
    {"\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1767999900,-1]", TRUE},
    {"\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1767999900,501]", TRUE},
    {"\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1767999901,1]", TRUE},
    /* days */
    {"\\{\"start\":[0-9]+", "{\"start\":\"x\"", TRUE},
    {"\\{\"start\":[0-9]+", "{\"start\":1.5", TRUE},
    {"\\{\"start\":[0-9]+,", "{", TRUE},
    {"\"tmax\":[^,]+,", "\"tmax\":\"x\",", TRUE},
    {"\"cond\":[0-9]+\\}", "\"cond\":15}", TRUE},
    /* sources */
    {"\"state\":[0-9]+", "\"state\":3", TRUE},
    {"\"state\":[0-9]+", "\"state\":-1", TRUE},
    {"\"error\":-?[0-9]+", "\"error\":8", TRUE},
    {"\"error\":-?[0-9]+", "\"error\":-2", TRUE},
    {"\"error\":-?[0-9]+", "\"error\":\"x\"", TRUE},
    {"\"members\":[0-9]+\\}", "\"members\":4294967296}", TRUE},
    {"\"members\":[0-9]+\\}", "\"members\":-1}", TRUE},
    {"\"url\":\"[^\"]*\"", "\"url\":\"http://example.org/\"", TRUE},
    {"\"url\":\"[^\"]*\"", "\"url\":\"javascript:alert(1)\"", TRUE},
    {"\"url\":\"[^\"]*\"", "\"url\":\"https://user@example.org/\"", TRUE},
    {"\"url\":\"[^\"]*\"", "\"url\":5", TRUE},
    {"\"url\":\"[^\"]*\"", "\"url\":\"\"", FALSE},
    {"\"id\":\"[^\"]*\"", "\"id\":\"../x\"", TRUE},
    {"\"id\":\"[^\"]*\"", "\"id\":\"\"", TRUE},
    {"\"id\":\"[^\"]*\"", "\"id\":\"UPPER\"", TRUE},
    {"\"id\":\"[^\"]*\"", "\"id\":5", TRUE},
    {"\"name\":\"Source 0\"", "\"name\":5", TRUE},
    {"\"attribution\":\"[^\"]*\"", "\"attribution\":null", TRUE},
    {"\"sources\":\\[", "\"sources\":[5,", TRUE},
    {"\"sources\":\\[", "\"sources\":[null,", TRUE},
    /* place */
    {"\"lat\":[^,]+", "\"lat\":91", TRUE},
    {"\"lat\":[^,]+", "\"lat\":\"x\"", TRUE},
    {"\"lon\":[^,]+", "\"lon\":181", TRUE},
    {"\"lon\":[^,]+", "\"lon\":null", TRUE},
    {"\"name\": ?\"Place A\"", "\"name\":\"\"", TRUE},
    {"\"name\": ?\"Place A\"", "\"name\":\"a\\u0001b\"", TRUE},
    {"\"name\": ?\"Place A\"", "\"name\":\"a\\u202eb\"", TRUE},
    {"\"country_code\": ?\"US\"", "\"country_code\":\"us\"", TRUE},
    {"\"timezone\": ?\"America/New_York\"", "\"timezone\":\"/etc/passwd\"", TRUE},
    {"\"place\":\\{", "\"place\":[],\"px\":{", TRUE},
    /* well-formed variations that must still load */
    {"\"admin1\": ?\"Region\"", "\"admin1\":\"R\\u00e9gion \\\"x\\\"\"", FALSE},
  };
  for (guint i = 0; i < G_N_ELEMENTS(mutations); i++) {
    g_test_message("%u: %s -> %s", i, mutations[i].pattern, mutations[i].replacement);
    g_autofree char *bad = mutate_re(ea, mutations[i].pattern, mutations[i].replacement);
    g_assert_cmpstr(bad, !=, ea);
    const char *entries[] = {bad, eb};
    g_autofree char *doc = make_doc(entries, 2);
    g_autofree char *path = path_in(f, "c.json");
    put_text(path, doc);
    g_autoptr(WxCache) c = wx_cache_new(path);
    GError *err = NULL;
    g_assert_true(wx_cache_load(c, &err));
    g_assert_no_error(err);
    g_assert_cmpuint(wx_cache_get_n_places(c), ==, mutations[i].dropped ? 1 : 2);
    g_autoptr(WxForecast) b = wx_cache_get(c, "20.0000,20.0000", NULL); /* the sibling always loads */
    g_assert_nonnull(b);
    assert_forecast_equal(fb, b);
    g_autoptr(WxForecast) a = wx_cache_get(c, "10.0000,10.0000", NULL);
    g_assert_cmpint(a != NULL, ==, !mutations[i].dropped);
    g_assert_false(wx_cache_is_dirty(c));
  }

  /* Out-of-range numbers are NAN after loading. */
  {
    g_autofree char *odd = mutate_re(ea, "\"temp\":[^,]+,", "\"temp\":1e9,");
    g_autofree char *odd2 = mutate_re(odd, "\"prob\":[^,]+,", "\"prob\":150,");
    const char *entries[] = {odd2};
    g_autofree char *doc = make_doc(entries, 1);
    g_autofree char *path = path_in(f, "c.json");
    put_text(path, doc);
    g_autoptr(WxCache) c = wx_cache_new(path);
    g_assert_true(wx_cache_load(c, NULL));
    g_autoptr(WxForecast) a = wx_cache_get(c, "10.0000,10.0000", NULL);
    g_assert_nonnull(a);
    g_assert_true(isnan(a->hours[0].temp_c));
    g_assert_true(isnan(a->hours[0].precip_prob));
    g_assert_false(isnan(a->hours[0].feels_c));
    g_assert_cmpuint(a->n_hours, ==, 4);
  }
}

/* Inserts one more element before @marker, copying the last element of the array just before
 * it and adding @step to its first number. */
static char *
extend_array(const char *text, const char *marker, const char *last_start, gint64 step)
{
  const char *m = strstr(text, marker);
  g_assert_nonnull(m);
  const char *s = NULL;
  for (const char *p = text; p < m; p++)
    if (g_str_has_prefix(p, last_start))
      s = p;
  g_assert_nonnull(s);
  g_autofree char *elem = g_strndup(s, (gsize)(m - s));
  g_autoptr(GRegex) re = g_regex_new("[0-9]{6,}", 0, 0, NULL);
  g_autoptr(GMatchInfo) mi = NULL;
  g_assert_true(g_regex_match(re, elem, 0, &mi));
  gint a, b;
  g_assert_true(g_match_info_fetch_pos(mi, 0, &a, &b));
  g_autofree char *num = g_strndup(elem + a, (gsize)(b - a));
  g_autofree char *bumped = g_strdup_printf("%" G_GINT64_FORMAT, g_ascii_strtoll(num, NULL, 10) + step);
  GString *out = g_string_new_len(text, m - text);
  g_string_append_c(out, ',');
  g_string_append_len(out, elem, a);
  g_string_append(out, bumped);
  g_string_append(out, elem + b);
  g_string_append(out, m);
  return g_string_free(out, FALSE);
}

static void
test_cache_load_oversized_arrays(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autoptr(WxPlace) pa = make_place("A", 10.0, 10.0);
  struct {
    guint hours, quarters, days, sources;
    const char *marker, *last;
    gint64 step;
    gboolean ok;
  } cases[] = {
    {WX_CACHE_MAX_HOURS, 2, 2, 2, "],\"quarters\"", "{\"t\":", 3600, FALSE},
    {WX_CACHE_MAX_HOURS - 1, 2, 2, 2, "],\"quarters\"", "{\"t\":", 3600, TRUE},
    {3, WX_CACHE_MAX_QUARTERS, 2, 2, "],\"days\"", "[", 900, FALSE},
    {3, WX_CACHE_MAX_QUARTERS - 1, 2, 2, "],\"days\"", "[", 900, TRUE},
    {3, 2, WX_FORECAST_MAX_DAYS, 2, "],\"sources\"", "{\"start\":", 86400, FALSE},
    {3, 2, WX_FORECAST_MAX_DAYS - 1, 2, "],\"sources\"", "{\"start\":", 86400, TRUE},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autoptr(WxForecast) fa = make_forecast(pa, cases[i].hours, cases[i].quarters, cases[i].days,
                                             cases[i].sources, 1);
    g_autofree char *ea = entry_text(f, fa, T0 * 1000);
    g_autofree char *big = extend_array(ea, cases[i].marker, cases[i].last, cases[i].step);
    const char *entries[] = {big};
    g_autofree char *doc = make_doc(entries, 1);
    g_autofree char *path = path_in(f, "c.json");
    put_text(path, doc);
    g_autoptr(WxCache) c = wx_cache_new(path);
    g_assert_true(wx_cache_load(c, NULL));
    g_assert_cmpuint(wx_cache_get_n_places(c), ==, cases[i].ok ? 1 : 0);
  }
  /* Sources: 17 do not load (the extension helper cannot bump a string, so build them directly). */
  g_autoptr(WxForecast) fs = make_forecast(pa, 3, 0, 0, WX_FORECAST_MAX_SOURCES, 1);
  g_autofree char *es = entry_text(f, fs, T0 * 1000);
  g_autofree char *eleven = mutate_re(es, "\"sources\":\\[", "\"sources\":[{\"id\":\"zz\",\"name\":\"\","
                                         "\"attribution\":\"\",\"url\":\"\",\"state\":0,\"error\":-1,"
                                         "\"members\":0},");
  const char *entries[] = {eleven};
  g_autofree char *doc = make_doc(entries, 1);
  g_autofree char *path = path_in(f, "c.json");
  put_text(path, doc);
  g_autoptr(WxCache) c = wx_cache_new(path);
  g_assert_true(wx_cache_load(c, NULL));
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, 0);
}

static void
test_cache_load_duplicates_and_cap(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autoptr(WxPlace) pa = make_place("A", 10.0, 10.0);
  g_autoptr(WxForecast) fa1 = make_forecast(pa, 3, 0, 0, 0, 1);
  g_autoptr(WxForecast) fa2 = make_forecast(pa, 4, 0, 0, 0, 2);
  g_autofree char *ea1 = entry_text(f, fa1, T0 * 1000);
  g_autofree char *ea2 = entry_text(f, fa2, T0 * 1000 + 5);
  g_autofree char *path = path_in(f, "c.json");
  {
    const char *entries[] = {ea1, ea2, ea1};
    g_autofree char *doc = make_doc(entries, 3);
    put_text(path, doc);
    g_autoptr(WxCache) c = wx_cache_new(path);
    g_assert_true(wx_cache_load(c, NULL));
    g_assert_cmpuint(wx_cache_get_n_places(c), ==, 1);
    g_autoptr(WxForecast) got = wx_cache_get(c, "10.0000,10.0000", NULL);
    g_assert_cmpuint(got->n_hours, ==, 3); /* the first accepted occurrence wins */
  }

  /* More than WX_CACHE_MAX_PLACES entries: the least recently used (first) are ignored. */
  {
    GPtrArray *entries = g_ptr_array_new_with_free_func(g_free);
    for (guint i = 0; i < 70; i++) {
      g_autoptr(WxPlace) p = grid_place(i);
      g_autoptr(WxForecast) fc = make_forecast(p, 2, 0, 0, 0, i);
      g_ptr_array_add(entries, entry_text(f, fc, T0 * 1000 + i));
    }
    g_autofree char *doc = make_doc((const char *const *)entries->pdata, entries->len);
    put_text(path, doc);
    g_ptr_array_unref(entries);
    g_autoptr(WxCache) c = wx_cache_new(path);
    g_assert_true(wx_cache_load(c, NULL));
    g_assert_cmpuint(wx_cache_get_n_places(c), ==, WX_CACHE_MAX_PLACES);
    for (guint i = 0; i < 70; i++)
      g_assert_cmpint(has_grid(c, i), ==, i >= 20);
    g_assert_false(wx_cache_is_dirty(c));
  }

  /* A duplicate of an entry that was already evicted is still skipped: A, 50 others, A again. */
  {
    GPtrArray *entries = g_ptr_array_new_with_free_func(g_free);
    g_ptr_array_add(entries, g_strdup(ea1));
    for (guint i = 1; i <= 50; i++) {
      g_autoptr(WxPlace) p = grid_place(i);
      g_autoptr(WxForecast) fc = make_forecast(p, 2, 0, 0, 0, i);
      g_ptr_array_add(entries, entry_text(f, fc, T0 * 1000 + i));
    }
    g_ptr_array_add(entries, g_strdup(ea2));
    g_autofree char *doc = make_doc((const char *const *)entries->pdata, entries->len);
    put_text(path, doc);
    g_ptr_array_unref(entries);
    g_autoptr(WxCache) c = wx_cache_new(path);
    g_assert_true(wx_cache_load(c, NULL));
    g_assert_cmpuint(wx_cache_get_n_places(c), ==, WX_CACHE_MAX_PLACES);
    g_assert_null(wx_cache_get(c, "10.0000,10.0000", NULL)); /* A was evicted; the repeat is not loaded */
    g_assert_true(has_grid(c, 1));
    g_assert_true(has_grid(c, 50));
  }

  /* Invalid and duplicate elements do not use up slots: 50 valid entries between 100 bad ones. */
  {
    GPtrArray *entries = g_ptr_array_new_with_free_func(g_free);
    for (guint i = 0; i < 50; i++) {
      for (guint j = 0; j < 2; j++)
        g_ptr_array_add(entries, g_strdup("{\"fetched_at_ms\":-1}"));
      g_autoptr(WxPlace) p = grid_place(i);
      g_autoptr(WxForecast) fc = make_forecast(p, 2, 0, 0, 0, i);
      g_ptr_array_add(entries, entry_text(f, fc, T0 * 1000 + i));
    }
    g_autofree char *doc = make_doc((const char *const *)entries->pdata, entries->len);
    put_text(path, doc);
    g_ptr_array_unref(entries);
    g_autoptr(WxCache) c = wx_cache_new(path);
    g_assert_true(wx_cache_load(c, NULL));
    g_assert_cmpuint(wx_cache_get_n_places(c), ==, 50);
    for (guint i = 0; i < 50; i++)
      g_assert_true(has_grid(c, i));
  }

  /* Non-object elements and a wrong shape of "entries". */
  const char *junk[] = {
    "{\"version\":1,\"entries\":[1,\"x\",null,[],true,{}]}",
    "{\"version\":1,\"entries\":{}}",
    "{\"version\":1,\"entries\":null}",
    "{\"version\":1}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(junk); i++) {
    put_text(path, junk[i]);
    g_autoptr(WxCache) c = wx_cache_new(path);
    GError *err = NULL;
    gboolean ok = wx_cache_load(c, &err);
    g_assert_cmpint(ok, ==, i == 0);
    if (!ok)
      g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
    g_clear_error(&err);
    g_assert_cmpuint(wx_cache_get_n_places(c), ==, 0);
  }
}

/* The largest cache file the module can write is below WX_CACHE_MAX_FILE_BYTES. */
static void
test_cache_max_file_size(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "c.json");
  g_autoptr(WxCache) c = wx_cache_new(path);
  g_autofree char *quotes = g_strnfill(WX_PLACE_NAME_MAX, '"');
  g_autofree char *slashes = g_strnfill(WX_PLACE_NAME_MAX, '\\');
  /* A valid https URL of the maximum length. */
  g_autofree char *tail = g_strnfill(WX_SOURCE_URL_MAX - strlen("https://example.org/"), 'a');
  g_autofree char *url = g_strconcat("https://example.org/", tail, NULL);
  g_assert_cmpuint(strlen(url), ==, WX_SOURCE_URL_MAX);
  double tiny = 1.2345678901234567e-300;
  gsize biggest = 0;
  for (guint i = 0; i < WX_CACHE_MAX_PLACES; i++) {
    g_autoptr(GError) err = NULL;
    g_autoptr(WxPlace) p = wx_place_new(quotes, slashes, quotes, "US", -12.345678901234567 + i,
                                        -123.45678901234567 + 2 * i,
                                        "America/Argentina/ComodRivadavia", &err);
    g_assert_no_error(err);
    WxBlendHour *hours = g_new0(WxBlendHour, WX_CACHE_MAX_HOURS);
    for (guint h = 0; h < WX_CACHE_MAX_HOURS; h++) {
      WxBlendHour *x = &hours[h];
      x->t_s = T0 + (gint64)h * 3600;
      x->temp_c = -tiny;
      x->feels_c = -tiny;
      x->precip_mm = tiny;
      x->precip_mm_max = tiny;
      x->precip_prob = tiny;
      x->cloud_pct = tiny;
      x->wind_kmh = tiny;
      x->gust_kmh = tiny;
      x->humidity_pct = tiny;
      x->temp_spread_c = tiny;
      x->n_members = 255;
      x->condition = WX_COND_COUNT - 1;
      x->is_day = TRUE;
    }
    WxQuarter quarters[WX_CACHE_MAX_QUARTERS];
    for (guint q = 0; q < WX_CACHE_MAX_QUARTERS; q++) {
      quarters[q].t_s = T0 + (gint64)q * 900;
      quarters[q].precip_mm = tiny;
    }
    WxDay days[WX_FORECAST_MAX_DAYS];
    for (guint d = 0; d < WX_FORECAST_MAX_DAYS; d++) {
      days[d].start_s = T0 + (gint64)d * 86400;
      days[d].temp_max_c = -tiny;
      days[d].temp_min_c = -tiny;
      days[d].precip_mm = tiny;
      days[d].precip_prob_max = tiny;
      days[d].cloud_pct = tiny;
      days[d].condition = WX_COND_COUNT - 1;
    }
    WxSourceStatus *owned[WX_FORECAST_MAX_SOURCES];
    WxSourceStatus sources[WX_FORECAST_MAX_SOURCES];
    for (guint s = 0; s < WX_FORECAST_MAX_SOURCES; s++) {
      g_autofree char *id = g_strdup_printf("%031u%c", s, 'z');
      owned[s] = wx_source_status_new(id, quotes, slashes, url, WX_SRC_FAILED, WX_ERROR_UNSUPPORTED,
                                      G_MAXUINT, &err);
      g_assert_no_error(err);
      g_assert_nonnull(owned[s]);
      g_assert_cmpuint(strlen(owned[s]->name), ==, WX_PLACE_NAME_MAX);
      sources[s] = *owned[s];
    }
    g_autoptr(WxForecast) fc = wx_forecast_new(p, WX_TIME_MAX_S - 1, hours, WX_CACHE_MAX_HOURS,
                                               quarters, WX_CACHE_MAX_QUARTERS, days,
                                               WX_FORECAST_MAX_DAYS, sources,
                                               WX_FORECAST_MAX_SOURCES, &err);
    g_assert_no_error(err);
    g_assert_nonnull(fc);
    g_assert_true(wx_cache_put(c, fc, WX_TIME_MAX_S * 1000 - 1));
    g_free(hours);
    for (guint s = 0; s < WX_FORECAST_MAX_SOURCES; s++)
      wx_source_status_free(owned[s]);
    if (i == 0) {
      /* The size of one such forecast, measured on its own. */
      g_autofree char *single = path_in(f, "single.json");
      g_autoptr(WxCache) one = wx_cache_new(single);
      g_assert_true(wx_cache_put(one, fc, WX_TIME_MAX_S * 1000 - 1));
      g_assert_true(wx_cache_save(one, NULL));
      g_autofree char *t1 = read_all(single);
      biggest = strlen(t1);
    }
  }
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, WX_CACHE_MAX_PLACES);
  g_assert_true(wx_cache_save(c, NULL));
  g_autofree char *text = read_all(path);
  g_test_message("worst-case cache file: %zu bytes (one forecast: %zu), limit %d", strlen(text),
                 biggest, WX_CACHE_MAX_FILE_BYTES);
  g_assert_cmpuint(strlen(text), <, (gsize)WX_CACHE_MAX_FILE_BYTES);
  g_assert_true(wx_json_check_strict(text, strlen(text), WX_JSON_MAX_DEPTH));
  /* ... and it loads back in full. */
  g_autoptr(WxCache) back = wx_cache_new(path);
  GError *err = NULL;
  g_assert_true(wx_cache_load(back, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(wx_cache_get_n_places(back), ==, WX_CACHE_MAX_PLACES);
}

static void
test_cache_control_bytes_roundtrip(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "c.json");
  g_autoptr(WxCache) c = wx_cache_new(path);
  /* Every special byte that the core types accept in text: '"', '\\', '/', DEL-free printable
   * ASCII and non-ASCII. Control bytes never reach the writer (the core rejects them). */
  g_autoptr(WxPlace) p = make_place("Q \" B \\ S / P % U \xc3\xbc J \xe6\x97\xa5", 1.5, 2.5);
  g_autoptr(GError) err = NULL;
  g_autoptr(WxSourceStatus) s = wx_source_status_new("a", "n\"a\\me", "at\"tr\\", "https://example.org/\"x",
                                                     WX_SRC_OK, -1, 1, &err);
  g_assert_null(s); /* a quote is not allowed in the URL */
  g_clear_error(&err);
  s = wx_source_status_new("a", "n\"a\\me \x01 ctl \xe2\x80\xae", "at\"tr\\", "", WX_SRC_OK, -1, 1, &err);
  g_assert_no_error(err);
  g_assert_cmpstr(s->name, ==, "n\"a\\me  ctl "); /* controls and bidi overrides are stripped by the core */
  WxSourceStatus srcs[1] = {*s};
  WxBlendHour h;
  memset(&h, 0, sizeof h);
  h.t_s = T0;
  h.condition = WX_COND_CLEAR;
  g_autoptr(WxForecast) fc = wx_forecast_new(p, T0, &h, 1, NULL, 0, NULL, 0, srcs, 1, &err);
  g_assert_no_error(err);
  g_assert_true(wx_cache_put(c, fc, T0 * 1000));
  g_assert_true(wx_cache_save(c, NULL));
  g_autofree char *text = read_all(path);
  g_assert_true(wx_json_check_strict(text, strlen(text), WX_JSON_MAX_DEPTH));
  for (const char *b = text; *b != '\0'; b++)
    g_assert_true((guchar)*b >= 0x20 || *b == '\n'); /* no raw control byte in the file */
  g_autoptr(WxCache) back = wx_cache_new(path);
  g_assert_true(wx_cache_load(back, NULL));
  g_autoptr(WxForecast) got = wx_cache_get(back, "1.5000,2.5000", NULL);
  g_assert_nonnull(got);
  assert_forecast_equal(fc, got);
}

static void
test_cache_preconditions(void)
{
  g_autoptr(WxCache) c = wx_cache_new("/nonexistent/never-used.json");
  g_autoptr(WxPlace) p = make_place("P", 1, 2);
  g_autoptr(WxForecast) fc = make_forecast(p, 3, 0, 0, 0, 0);
  GError *err = NULL;
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_null(wx_cache_get_path(NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_cmpuint(wx_cache_get_n_places(NULL), ==, 0);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_false(wx_cache_put(NULL, fc, T0 * 1000));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_null(wx_cache_get(NULL, "1.0000,2.0000", NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_false(wx_cache_remove(NULL, "1.0000,2.0000"));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_false(wx_cache_is_dirty(NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_false(wx_cache_load(NULL, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_false(wx_cache_save(NULL, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  wx_cache_save_async(NULL, NULL, NULL, NULL);
  g_test_assert_expected_messages();
  g_assert_no_error(err);
  GError *taken = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_FAILED, "taken");
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_cache_load(c, &taken));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_cache_save(c, &taken));
  g_test_assert_expected_messages();
  g_clear_error(&taken);
  g_autoptr(GTask) foreign = g_task_new(c, NULL, NULL, NULL);
  EXPECT_CRITICAL("*g_async_result_is_tagged*");
  g_assert_false(wx_cache_save_finish(c, G_ASYNC_RESULT(foreign), NULL));
  g_test_assert_expected_messages();
  g_autoptr(WxCache) other = wx_cache_new("/nonexistent/other.json");
  g_autoptr(GTask) foreign2 = g_task_new(other, NULL, NULL, NULL);
  EXPECT_CRITICAL("*g_task_is_valid*");
  g_assert_false(wx_cache_save_finish(c, G_ASYNC_RESULT(foreign2), NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*WX_IS_CACHE*");
  g_assert_false(wx_cache_save_finish(NULL, G_ASYNC_RESULT(foreign), NULL));
  g_test_assert_expected_messages();
}

/* The loader works on a snapshot taken at save time: edits after save_async() are not in the file. */
static void
test_cache_snapshot_is_stable(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "c.json");
  g_autoptr(WxCache) c = wx_cache_new(path);
  for (guint i = 0; i < 5; i++)
    put_grid(c, i);
  AsyncState st = {&k_cache_ops, c, 0, FALSE, NULL, FALSE};
  wx_cache_save_async(c, NULL, on_saved, &st);
  /* Mutate everything while the worker may be serialising: replace, remove, evict. */
  for (guint i = 0; i < 5; i++) {
    g_autofree char *k = key_of_grid(i);
    g_assert_true(wx_cache_remove(c, k));
  }
  for (guint i = 10; i < 60; i++)
    put_grid(c, i);
  wait_calls(&st, 1);
  g_assert_true(st.ok);
  g_autoptr(WxCache) back = wx_cache_new(path);
  g_assert_true(wx_cache_load(back, NULL));
  g_assert_cmpuint(wx_cache_get_n_places(back), ==, 5);
  for (guint i = 0; i < 5; i++)
    g_assert_true(has_grid(back, i));
  g_assert_true(wx_cache_is_dirty(c));
}

/* ------------------------------------------------------------------------ */
/* Strict JSON gate: differential test against an independent reference     */
/* ------------------------------------------------------------------------ */

static gboolean
ref_check(const char *t, gsize n, guint max_depth)
{
  guchar stack[32];
  guint depth = 0;
  gsize i = 0;
  while (i < n) {
    guchar c = (guchar)t[i];
    if (c == '"') {
      i++;
      for (;;) {
        if (i >= n)
          return FALSE;
        c = (guchar)t[i];
        if (c == '"') {
          i++;
          break;
        }
        if (c < 0x20)
          return FALSE;
        if (c == '\\') {
          if (i + 1 >= n)
            return FALSE;
          guchar e = (guchar)t[i + 1];
          if (e != 0 && strchr("\"\\/bfnrt", e) != NULL) {
            i += 2;
            continue;
          }
          if (e != 'u' || i + 6 > n)
            return FALSE;
          gboolean all_zero = TRUE;
          for (gsize k = 2; k < 6; k++) {
            if (!g_ascii_isxdigit(t[i + k]))
              return FALSE;
            all_zero = all_zero && t[i + k] == '0';
          }
          if (all_zero)
            return FALSE; /* the escape of U+0000 */
          i += 6;
          continue;
        }
        i++;
      }
      continue;
    }
    if (c == '[' || c == '{') {
      if (depth >= max_depth)
        return FALSE;
      stack[depth++] = c;
      i++;
      continue;
    }
    if (c == ']' || c == '}') {
      if (depth == 0 || stack[depth - 1] != (c == ']' ? '[' : '{'))
        return FALSE;
      depth--;
      i++;
      continue;
    }
    if (c != 0 && strchr(" \t\n\r,:0123456789-+.eEtruflsna", c) != NULL) {
      i++;
      continue;
    }
    return FALSE;
  }
  return depth == 0;
}

static void
test_json_strict_differential(void)
{
  static const char alphabet[] = "[]{}\"\\u0123456789abcdefABCDEF-+.,: \t\n\rtruefalsn'/#xzE";
  static const guchar extra[] = {0x00, 0x01, 0x1f, 0x20, 0x7f, 0x80, 0xc3, 0xff, '\f', '\v'};
  GRand *r = g_rand_new_with_seed(2026);
  guint accepted = 0;
  for (guint iter = 0; iter < 600000; iter++) {
    char buf[40];
    gsize n = (gsize)g_rand_int_range(r, 0, 26);
    gboolean biased = g_rand_boolean(r);
    for (gsize i = 0; i < n; i++) {
      guint pick = g_rand_int_range(r, 0, biased ? 100 : 10);
      if (pick < 8 && biased)
        buf[i] = "[]{}\"\\ ,:"[g_rand_int_range(r, 0, 9)];
      else if (pick < 8)
        buf[i] = (char)extra[g_rand_int_range(r, 0, G_N_ELEMENTS(extra))];
      else
        buf[i] = alphabet[g_rand_int_range(r, 0, (gint)sizeof alphabet - 1)];
    }
    guint depth = (guint)g_rand_int_range(r, 0, 5);
    gboolean a = wx_json_check_strict(buf, n, depth);
    gboolean b = ref_check(buf, n, depth);
    if (a != b) {
      g_autofree char *copy = g_strndup(buf, n); /* ends at a NUL byte: enough for a message */
      g_autofree char *shown = g_strescape(copy, NULL);
      g_test_message("gate says %d, reference says %d for %zu bytes: %s", a, b, n, shown);
    }
    g_assert_cmpint(a, ==, b);
    accepted += a;
  }
  g_test_message("accepted %u of 600000", accepted);
  g_assert_cmpuint(accepted, >, 1000); /* the generator reaches the accepting paths */

  /* Strings assembled from well-formed fragments: accepted exactly when no fragment is the
   * escape of U+0000 (an escaped backslash followed by "u0000" is plain text and is accepted). */
  static const char *const frag[] = {"a",       "\\u00e9", "\\u0001", "\\uD83D", "\\u0000", "\\\\u0000",
                                     "\\\\",    "\\\"",    "\\/",     "\\n",     "\\u00000", "\xc3\xa9",
                                     "'",       "/",       "#",       "\\u0010", "\\uFFFF"};
  guint rejected = 0;
  for (guint iter = 0; iter < 20000; iter++) {
    g_autoptr(GString) doc = g_string_new("{\"k\":[\"");
    gboolean has_nul = FALSE;
    for (gint k = g_rand_int_range(r, 0, 8); k > 0; k--) {
      guint pick = (guint)g_rand_int_range(r, 0, G_N_ELEMENTS(frag));
      g_string_append(doc, frag[pick]);
      has_nul |= strcmp(frag[pick], "\\u0000") == 0 || strcmp(frag[pick], "\\u00000") == 0;
    }
    g_string_append(doc, "\"]}");
    gboolean got = wx_json_check_strict(doc->str, doc->len, 32);
    g_assert_cmpint(got, ==, !has_nul);
    g_assert_cmpint(ref_check(doc->str, doc->len, 32), ==, !has_nul);
    rejected += has_nul;
  }
  g_assert_cmpuint(rejected, >, 1000);
  g_rand_free(r);
}

/* The gate refuses the escape of U+0000 in every position of a string (a key, a value, an array
 * element, at the start, middle and end), however many zeros follow, and nothing else: an
 * escaped backslash before "u0000" is text, and the neighbouring code points are fine. */
static void
test_json_strict_nul_escape(void)
{
  const struct {
    const char *text;
    gboolean ok;
  } table[] = {
    {"[\"\\u0000\"]", FALSE},
    {"[\"a\\u0000b\"]", FALSE},
    {"[\"\\u0000a\"]", FALSE},
    {"[\"a\\u0000\"]", FALSE},
    {"[\"\\u00000\"]", FALSE},
    {"[\"\\u0000\\u0000\"]", FALSE},
    {"{\"\\u0000\":1}", FALSE},
    {"{\"k\":\"\\u0000\"}", FALSE},
    {"{\"k\":{\"j\":[\"x\",\"\\u0000\"]}}", FALSE},
    {"\"\\u0000\"", FALSE},
    {"[\"\\\\\\u0000\"]", FALSE}, /* an escaped backslash, then the escape */
    {"[\"Miami\\u0000\\u001b[31mjunk\"]", FALSE},
    {"[\"\\\\u0000\"]", TRUE},     /* backslash, then the text u0000 */
    {"[\"\\\\\\\\u0000\"]", TRUE}, /* two backslashes, then the text u0000 */
    {"[\"u0000\"]", TRUE},
    {"[\"\\u0001\"]", TRUE},
    {"[\"\\u0010\"]", TRUE},
    {"[\"\\u0100\"]", TRUE},
    {"[\"\\u1000\"]", TRUE},
    {"[\"\\u001f\"]", TRUE},
    {"[\"\\u00e9\\u00E9\\uD83D\\uDE80\"]", TRUE},
    {"[\"\\u000\"]", FALSE},
    {"[\"\\u00\"]", FALSE},
    {"[\"\\u\"]", FALSE},
    {"[\"\\u000g\"]", FALSE},
    {"[\"\\U0000\"]", FALSE},
    {"[\"\\u0000", FALSE},
  };
  for (guint i = 0; i < G_N_ELEMENTS(table); i++) {
    g_test_message("%s", table[i].text);
    g_assert_cmpint(wx_json_check_strict(table[i].text, strlen(table[i].text), 32), ==,
                    table[i].ok);
    g_assert_cmpint(ref_check(table[i].text, strlen(table[i].text), 32), ==, table[i].ok);
  }

  /* Reads stay inside the buffer for every prefix of the interesting documents. */
  static const char *const docs[] = {"[\"\\u0000\"]", "[\"\\u0001\\u0000\"]", "{\"\\u0000\":\"\\u0000\"}"};
  Guard g;
  for (guint d = 0; d < G_N_ELEMENTS(docs); d++) {
    gsize len = strlen(docs[d]);
    for (gsize n = 0; n <= len; n++) {
      char *buf = guard_alloc(&g, len);
      char *start = buf + len - n;
      memcpy(start, docs[d], n);
      g_assert_cmpint(wx_json_check_strict(start, n, 32), ==, ref_check(start, n, 32));
      guard_free(&g);
    }
  }
}

/* ------------------------------------------------------------------------ */
/* The escape of U+0000 in every kind of loaded string                      */
/* ------------------------------------------------------------------------ */

/* Loads @text into a seeded object and checks the outcome of any rejected file: a parse error,
 * the empty / default content, a clean object, and (the test aborts on any GLib message) no
 * warning or critical. */
static void
expect_rejected(const StoreOps *ops, const char *path, const char *text, const char *label)
{
  g_test_message("%s: %s", ops->name, label);
  g_autofree char *fresh = fresh_fingerprint(ops);
  put_text(path, text);
  gpointer o = ops->create(path);
  ops->mutate(o, 0); /* the load must replace this */
  GError *err = NULL;
  g_assert_false(ops->load(o, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&err);
  g_autofree char *fp = ops->fingerprint(o);
  g_assert_cmpstr(fp, ==, fresh);
  g_assert_false(ops->is_dirty(o));
  g_object_unref(o);
}

static void
test_store_nul_escape_settings(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "settings.json");
  const struct {
    const char *label;
    const char *text;
  } bad[] = {
    {"units", "{\"version\":1,\"units\":\"metric\\u0000junk\"}"},
    {"units, whole value", "{\"version\":1,\"units\":\"\\u0000\"}"},
    {"units, case-less zeros", "{\"version\":1,\"units\":\"metric\\u00000\"}"},
    {"disabled provider", "{\"version\":1,\"disabled_providers\":[\"a\\u0000b\"]}"},
    {"disabled provider next to valid ones",
     "{\"version\":1,\"disabled_providers\":[\"ok\",\"a\\u0000\",\"fine\"]}"},
    {"selected", "{\"version\":1,\"selected\":\"25.7617,-80.1918\\u0000x\"}"},
    {"selected, escape inside the digits", "{\"version\":1,\"selected\":\"25.76\\u000017,-80.1918\"}"},
    {"unknown member value", "{\"version\":1,\"x\":\"\\u0000\"}"},
    {"member name", "{\"version\":1,\"un\\u0000its\":\"metric\"}"},
    {"version member name", "{\"vers\\u0000ion\":1}"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++)
    expect_rejected(&k_settings_ops, path, bad[i].text, bad[i].label);

  /* The same text with an escaped backslash is ordinary data and loads (the value is invalid,
   * so the default stays). */
  put_text(path, "{\"version\":1,\"units\":\"metric\\\\u0000junk\"}");
  g_autoptr(WxSettings) st = wx_settings_new(path);
  g_assert_true(wx_settings_load(st, NULL));
  g_assert_cmpint(wx_settings_get_units(st), ==, WX_UNITS_IMPERIAL);
  /* And the cleanly escaped neighbours load normally. */
  put_text(path, "{\"version\":1,\"units\":\"metric\",\"selected\":\"1.5000,2.5000\\u0031\"}");
  g_assert_true(wx_settings_load(st, NULL));
  g_assert_cmpint(wx_settings_get_units(st), ==, WX_UNITS_METRIC);
}

static void
test_store_nul_escape_places(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "places.json");
  const char *valid = "{\"name\":\"Fine\",\"lat\":1.5,\"lon\":2.5}";
  const struct {
    const char *label;
    const char *element;
  } bad[] = {
    {"name", "{\"name\":\"Miami\\u0000\\u001b[31mjunk\",\"lat\":25.7617,\"lon\":-80.1918}"},
    {"name, whole value", "{\"name\":\"\\u0000\",\"lat\":25.7617,\"lon\":-80.1918}"},
    {"admin1", "{\"name\":\"Miami\",\"admin1\":\"Flo\\u0000rida\",\"lat\":25.7617,\"lon\":-80.1918}"},
    {"country", "{\"name\":\"Miami\",\"country\":\"\\u0000US\",\"lat\":25.7617,\"lon\":-80.1918}"},
    {"country code", "{\"name\":\"Miami\",\"country_code\":\"U\\u0000\",\"lat\":25.7617,\"lon\":-80.1918}"},
    {"timezone", "{\"name\":\"Miami\",\"timezone\":\"America/New_York\\u0000\",\"lat\":25.7617,\"lon\":-80.1918}"},
    {"member name", "{\"na\\u0000me\":\"Miami\",\"lat\":25.7617,\"lon\":-80.1918}"},
    {"unknown member", "{\"name\":\"Miami\",\"lat\":25.7617,\"lon\":-80.1918,\"x\":[\"\\u0000\"]}"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    /* The valid sibling before and after does not rescue the file: the gate refuses all of it. */
    g_autofree char *doc = g_strdup_printf("{\"version\":1,\"places\":[%s,%s,%s]}", valid,
                                           bad[i].element, valid);
    expect_rejected(&k_places_ops, path, doc, bad[i].label);
  }
  expect_rejected(&k_places_ops, path,
                  "{\"version\":1,\"pla\\u0000ces\":[{\"name\":\"A\",\"lat\":1,\"lon\":2}]}",
                  "places member name");

  /* The escaped-backslash form is ordinary text: the element loads with that name. */
  put_text(path, "{\"version\":1,\"places\":[{\"name\":\"Miami\\\\u0000junk\",\"lat\":1,\"lon\":2}]}");
  g_autoptr(WxPlaces) pl = wx_places_new(path);
  g_assert_true(wx_places_load(pl, NULL, NULL));
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, 1);
  g_assert_cmpstr(wx_places_get_place(pl, 0)->name, ==, "Miami\\u0000junk");
}

static void
test_store_nul_escape_cache(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autoptr(WxPlace) pa = make_place("A", 10.0, 10.0);
  g_autoptr(WxPlace) pb = make_place("B", 20.0, 20.0);
  g_autoptr(WxForecast) fa = make_forecast(pa, 4, 3, 2, 2, 1);
  g_autoptr(WxForecast) fb = make_forecast(pb, 4, 3, 2, 2, 2);
  g_autofree char *ea = entry_text(f, fa, T0 * 1000);
  g_autofree char *eb = entry_text(f, fb, T0 * 1000);
  g_autofree char *path = path_in(f, "c.json");
  const struct {
    const char *label, *pattern, *replacement;
  } bad[] = {
    {"source id", "\"id\":\"src0\"", "\"id\":\"src0\\u0000x\""},
    {"source id, whole value", "\"id\":\"src0\"", "\"id\":\"\\u0000\""},
    {"source name", "\"name\":\"Source 0\"", "\"name\":\"Source 0\\u0000\\u001b[31mjunk\""},
    {"source attribution", "\"attribution\":\"Data from source 0\"", "\"attribution\":\"Data\\u0000\""},
    {"source url", "\"url\":\"https://example.org/data\\?a=1&b=2\"", "\"url\":\"https://example.org/\\u0000\""},
    {"place name", "\"name\": ?\"Place A\"", "\"name\":\"Place A\\u0000junk\""},
    {"place admin1", "\"admin1\": ?\"Region\"", "\"admin1\":\"\\u0000Region\""},
    {"place timezone", "\"timezone\": ?\"America/New_York\"", "\"timezone\":\"America\\u0000/New_York\""},
    {"entry member name", "\"forecast\":", "\"fore\\u0000cast\":"},
    {"place member name", "\"place\":", "\"pla\\u0000ce\":"},
    {"number member name", "\"generated_s\":", "\"generated\\u0000_s\":"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_autofree char *mut = mutate_re(ea, bad[i].pattern, bad[i].replacement);
    const char *entries[] = {eb, mut, eb};
    g_autofree char *doc = make_doc(entries, G_N_ELEMENTS(entries));
    expect_rejected(&k_cache_ops, path, doc, bad[i].label);
  }

  /* The document-level members as well. */
  expect_rejected(&k_cache_ops, path, "{\"version\":1,\"entr\\u0000ies\":[]}", "entries member name");
  expect_rejected(&k_cache_ops, path, "{\"version\":1,\"entries\":[],\"x\":\"\\u0000\"}", "trailing member");

  /* A key that carries the escaped backslash form is data, not a NUL: the file loads (the entry
   * is dropped as the field is invalid for the core rules, nothing else). */
  g_autofree char *ok_form = mutate_re(ea, "\"name\":\"Source 0\"", "\"name\":\"Source\\\\u0000 0\"");
  const char *entries[] = {eb, ok_form};
  g_autofree char *doc = make_doc(entries, G_N_ELEMENTS(entries));
  put_text(path, doc);
  g_autoptr(WxCache) c = wx_cache_new(path);
  g_assert_true(wx_cache_load(c, NULL));
  g_assert_cmpuint(wx_cache_get_n_places(c), ==, 2);
  g_autoptr(WxForecast) got = wx_cache_get(c, "10.0000,10.0000", NULL);
  g_assert_nonnull(got);
  g_assert_cmpstr(got->sources[0].name, ==, "Source\\u0000 0");
}

/* ------------------------------------------------------------------------ */
/* Fuzzing the loaders with mutated valid files                             */
/* ------------------------------------------------------------------------ */

static void
mutate_bytes(GRand *r, GByteArray *b)
{
  static const guchar structural[] = {'"', '\\', '[', ']', '{', '}', ',', ':', '-', '0', '9', 'e',
                                      '.', 'n', 't', 0x00, 0x01, 0x1f, 0x7f, 0xff, 0xc3, 0x80};
  guint rounds = 1 + (guint)g_rand_int_range(r, 0, 4);
  for (guint k = 0; k < rounds && b->len > 0; k++) {
    guint pos = (guint)g_rand_int_range(r, 0, (gint)b->len);
    switch (g_rand_int_range(r, 0, 8)) {
    case 0: /* random byte */
      b->data[pos] = (guchar)g_rand_int_range(r, 0, 256);
      break;
    case 1: /* structural byte */
      b->data[pos] = structural[g_rand_int_range(r, 0, G_N_ELEMENTS(structural))];
      break;
    case 2: /* delete a range */
    {
      guint want = (guint)g_rand_int_range(r, 1, 40);
      g_byte_array_remove_range(b, pos, MIN(want, b->len - pos));
    }
      break;
    case 3: { /* duplicate a range */
      guint want = (guint)g_rand_int_range(r, 1, 60);
      guint len = MIN(want, b->len - pos);
      guint old = b->len;
      g_byte_array_set_size(b, old + len);
      memmove(b->data + pos + len, b->data + pos, old - pos);
      break; /* bytes [pos, pos + len) now appear twice */
    }
    case 4: /* truncate */
      g_byte_array_set_size(b, pos);
      break;
    case 5: { /* insert structural bytes */
      guchar x = structural[g_rand_int_range(r, 0, G_N_ELEMENTS(structural))];
      g_byte_array_set_size(b, b->len + 1);
      memmove(b->data + pos + 1, b->data + pos, b->len - pos - 1);
      b->data[pos] = x;
      break;
    }
    case 6: /* digit change */
      b->data[pos] = (guchar)('0' + g_rand_int_range(r, 0, 10));
      break;
    default: /* flip one bit */
      b->data[pos] ^= (guchar)(1u << g_rand_int_range(r, 0, 8));
      break;
    }
  }
}

static void
test_store_fuzz(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *seed_path = path_in(f, "seed.json");
    gpointer o = ops->create(seed_path);
    for (guint i = 0; i < 4; i++)
      ops->mutate(o, i);
    g_assert_true(ops->save(o, NULL));
    g_object_unref(o);
    g_autofree char *seed_text = read_all(seed_path);
    gsize seed_len = strlen(seed_text);
    g_autofree char *fresh = fresh_fingerprint(ops);
    g_autofree char *path = path_in(f, "fuzz.json");
    GRand *r = g_rand_new_with_seed(777 + k);
    guint ok_loads = 0, partial = 0;
    for (guint iter = 0; iter < 4000; iter++) {
      GByteArray *b = g_byte_array_new();
      g_byte_array_append(b, (const guint8 *)seed_text, (guint)seed_len);
      mutate_bytes(r, b);
      put_file(path, (const char *)b->data, b->len);
      g_byte_array_unref(b);

      gpointer l = ops->create(path);
      GError *err = NULL;
      gboolean ok = ops->load(l, &err); /* never a critical or a warning (fatal under g_test) */
      if (!ok) {
        g_assert_nonnull(err);
        g_assert_true(g_error_matches(err, WX_ERROR, WX_ERROR_PARSE));
        g_clear_error(&err);
        g_autofree char *fp = ops->fingerprint(l);
        g_assert_cmpstr(fp, ==, fresh);
      } else {
        g_assert_no_error(err);
        ok_loads++;
        g_autofree char *fp = ops->fingerprint(l);
        if (strcmp(fp, fresh) != 0)
          partial++;
        /* What loaded can be saved and loads back identically. */
        g_assert_true(ops->save(l, NULL));
        gpointer l2 = ops->create(path);
        g_assert_true(ops->load(l2, NULL));
        g_autofree char *fp2 = ops->fingerprint(l2);
        g_assert_cmpstr(fp, ==, fp2);
        g_object_unref(l2);
      }
      g_object_unref(l);
    }
    g_rand_free(r);
    g_test_message("%s: %u loads succeeded, %u with content", ops->name, ok_loads, partial);
    g_assert_cmpuint(ok_loads, >, 100);
  }
}

/* ------------------------------------------------------------------------ */
/* Remaining fileio preconditions                                           */
/* ------------------------------------------------------------------------ */

static void
test_fileio_preconditions(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "x.bin");
  GError *err = NULL;
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0'*");
  g_assert_false(wx_file_write_atomic(NULL, "x", 1, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0'*");
  g_assert_false(wx_file_write_atomic("", "x", 1, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*data != NULL || len == 0*");
  g_assert_false(wx_file_write_atomic(path, NULL, 1, &err));
  g_test_assert_expected_messages();
  g_assert_no_error(err);
  g_assert_false(g_file_test(path, G_FILE_TEST_EXISTS));
  GError *taken = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_FAILED, "taken");
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_file_write_atomic(path, "x", 1, &taken));
  g_test_assert_expected_messages();
  g_assert_false(g_file_test(path, G_FILE_TEST_EXISTS));

  put_text(path, "abc");
  g_autofree char *got = g_strdup("sentinel");
  gsize len = 55;
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0'*");
  g_assert_false(wx_file_read_bounded(NULL, 10, &got, &len, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0'*");
  g_assert_false(wx_file_read_bounded("", 10, &got, &len, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*contents != NULL*");
  g_assert_false(wx_file_read_bounded(path, 10, NULL, &len, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*max_bytes < G_MAXSIZE / 4*");
  g_assert_false(wx_file_read_bounded(path, G_MAXSIZE / 4, &got, &len, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_file_read_bounded(path, 10, &got, &len, &taken));
  g_test_assert_expected_messages();
  g_assert_cmpstr(got, ==, "sentinel"); /* untouched by a violated precondition */
  g_assert_cmpuint(len, ==, 55);
  g_clear_error(&taken);
  /* The length is optional. */
  g_clear_pointer(&got, g_free);
  g_assert_true(wx_file_read_bounded(path, 10, &got, NULL, NULL));
  g_assert_cmpstr(got, ==, "abc");

  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0'*");
  wx_file_remove_stale_temps(NULL);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0'*");
  wx_file_remove_stale_temps("");
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*text != NULL || len == 0*");
  g_assert_false(wx_json_check_strict(NULL, 1, 4));
  g_test_assert_expected_messages();
}

/* ------------------------------------------------------------------------ */
/* wx-store-json: the shared loader pieces                                  */
/* ------------------------------------------------------------------------ */

static void
test_store_json_helpers(Fixture *f, gconstpointer unused)
{
  (void)unused;
  /* Node readers tolerate NULL and wrong types. */
  gint64 i = 5;
  double d = 5.0;
  gboolean b = TRUE;
  g_assert_false(wx_store_node_i64(NULL, &i));
  g_assert_false(wx_store_node_double(NULL, TRUE, &d));
  g_assert_false(wx_store_node_bool(NULL, &b));
  g_assert_null(wx_store_node_string(NULL));
  g_assert_null(wx_store_node_object(NULL));
  g_assert_null(wx_store_node_array(NULL));
  g_assert_cmpint(i, ==, 5);
  g_assert_cmpfloat(d, ==, 5.0);
  g_assert_true(b);

  g_autoptr(JsonParser) p = json_parser_new();
  g_assert_true(json_parser_load_from_data(
    p, "[1, 2.5, \"s\", true, null, {}, [], -0.0, 1e2]", -1, NULL));
  JsonArray *a = json_node_get_array(json_parser_get_root(p));
  JsonNode *n_int = json_array_get_element(a, 0), *n_dbl = json_array_get_element(a, 1),
           *n_str = json_array_get_element(a, 2), *n_bool = json_array_get_element(a, 3),
           *n_null = json_array_get_element(a, 4), *n_obj = json_array_get_element(a, 5),
           *n_arr = json_array_get_element(a, 6), *n_negz = json_array_get_element(a, 7),
           *n_exp = json_array_get_element(a, 8);
  g_assert_true(wx_store_node_i64(n_int, &i));
  g_assert_cmpint(i, ==, 1);
  g_assert_false(wx_store_node_i64(n_dbl, &i));
  g_assert_false(wx_store_node_i64(n_exp, &i)); /* 1e2 is not an integer token */
  g_assert_false(wx_store_node_i64(n_str, &i));
  g_assert_false(wx_store_node_i64(n_null, &i));
  g_assert_true(wx_store_node_double(n_int, FALSE, &d));
  g_assert_cmpfloat(d, ==, 1.0);
  g_assert_true(wx_store_node_double(n_dbl, FALSE, &d));
  g_assert_cmpfloat(d, ==, 2.5);
  g_assert_true(wx_store_node_double(n_negz, FALSE, &d));
  g_assert_true(signbit(d));
  g_assert_false(wx_store_node_double(n_str, TRUE, &d));
  g_assert_false(wx_store_node_double(n_bool, TRUE, &d));
  g_assert_false(wx_store_node_double(n_null, FALSE, &d));
  g_assert_true(wx_store_node_double(n_null, TRUE, &d));
  g_assert_true(isnan(d));
  g_assert_false(wx_store_node_double(n_obj, TRUE, &d));
  g_assert_true(wx_store_node_bool(n_bool, &b));
  g_assert_true(b);
  g_assert_false(wx_store_node_bool(n_int, &b));
  g_assert_cmpstr(wx_store_node_string(n_str), ==, "s");
  g_assert_null(wx_store_node_string(n_int));
  g_assert_null(wx_store_node_string(n_null));
  g_assert_nonnull(wx_store_node_object(n_obj));
  g_assert_null(wx_store_node_object(n_arr));
  g_assert_nonnull(wx_store_node_array(n_arr));
  g_assert_null(wx_store_node_array(n_obj));

  /* The root check. */
  g_autoptr(JsonParser) q = json_parser_new();
  GError *err = NULL;
  g_assert_true(json_parser_load_from_data(q, "{\"version\":3,\"x\":1}", -1, NULL));
  g_assert_nonnull(wx_store_root_object(json_parser_get_root(q), "doc", 3, &err));
  g_assert_no_error(err);
  g_assert_null(wx_store_root_object(json_parser_get_root(q), "doc", 4, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
  g_assert_nonnull(strstr(err->message, "doc"));
  g_clear_error(&err);
  g_assert_null(wx_store_root_object(NULL, "doc", 3, NULL));
  g_assert_null(wx_store_root_object(n_arr, "doc", 3, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&err);

  g_autoptr(GError) pend = wx_store_pending_error("doc");
  g_assert_error(pend, G_IO_ERROR, G_IO_ERROR_PENDING);

  /* wx_store_load_json preconditions. */
  g_autofree char *path = path_in(f, "x.json");
  put_text(path, "{\"version\":1}");
  JsonParser *loaded = (JsonParser *)path; /* must be reset to NULL even on a violation */
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0' && what != NULL && parser != NULL*");
  g_assert_false(wx_store_load_json(NULL, 100, "doc", &loaded, &err));
  g_test_assert_expected_messages();
  g_assert_null(loaded);
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0' && what != NULL && parser != NULL*");
  g_assert_false(wx_store_load_json("", 100, "doc", &loaded, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0' && what != NULL && parser != NULL*");
  g_assert_false(wx_store_load_json(path, 100, NULL, &loaded, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*path != NULL && path[0] != '\\0' && what != NULL && parser != NULL*");
  g_assert_false(wx_store_load_json(path, 100, "doc", NULL, &err));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*max_bytes < G_MAXSIZE / 4*");
  g_assert_false(wx_store_load_json(path, G_MAXSIZE / 4, "doc", &loaded, &err));
  g_test_assert_expected_messages();
  GError *taken = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_FAILED, "taken");
  EXPECT_CRITICAL("*error == NULL || *error == NULL*");
  g_assert_false(wx_store_load_json(path, 100, "doc", &loaded, &taken));
  g_test_assert_expected_messages();
  g_clear_error(&taken);
  g_assert_no_error(err);
  g_assert_true(wx_store_load_json(path, 100, "doc", &loaded, &err));
  g_assert_nonnull(loaded);
  g_object_unref(loaded);
  /* The error messages carry the document name. */
  put_text(path, "nope");
  g_assert_false(wx_store_load_json(path, 100, "mydoc", &loaded, &err));
  g_assert_null(loaded);
  g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
  g_assert_true(g_str_has_prefix(err->message, "mydoc:"));
  g_clear_error(&err);
}

/* ------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------ */
/* File modes and links, thread hand-off, main contexts                     */
/* ------------------------------------------------------------------------ */

static void assert_file_text(const char *path, const char *want);

static void
test_fileio_modes_and_links(Fixture *f, gconstpointer unused)
{
  (void)unused;
  GError *err = NULL;
  /* An existing directory keeps its mode; directories created on the way are 0700. */
  g_autofree char *shared = path_in(f, "shared");
  g_assert_cmpint(g_mkdir(shared, 0755), ==, 0);
  g_assert_cmpint(g_chmod(shared, 0755), ==, 0);
  g_autofree char *path = g_build_filename(shared, "a", "b", "file.json", NULL);
  g_assert_true(wx_file_write_atomic(path, "one", 3, &err));
  g_assert_no_error(err);
  g_autofree char *dir_a = g_build_filename(shared, "a", NULL);
  g_autofree char *dir_b = g_build_filename(shared, "a", "b", NULL);
  g_assert_cmpuint(file_mode(shared), ==, 0755);
  g_assert_cmpuint(file_mode(dir_a), ==, 0700);
  g_assert_cmpuint(file_mode(dir_b), ==, 0700);
  g_assert_cmpuint(file_mode(path), ==, 0600);
  /* The mode of an existing file is not preserved: the result is private. */
  g_assert_cmpint(g_chmod(path, 0644), ==, 0);
  g_assert_true(wx_file_write_atomic(path, "two", 3, &err));
  g_assert_cmpuint(file_mode(path), ==, 0600);
  assert_file_text(path, "two");
  g_assert_cmpuint(file_mode(dir_b), ==, 0700); /* an existing directory is not touched */

  /* A symbolic link at the destination is replaced, its target is not written. */
  g_autofree char *real = path_in(f, "real.txt");
  g_autofree char *link = path_in(f, "link.txt");
  put_text(real, "real");
  g_assert_cmpint(symlink("real.txt", link), ==, 0);
  g_assert_true(wx_file_write_atomic(link, "replaced", 8, &err));
  GStatBuf st;
  g_assert_cmpint(g_lstat(link, &st), ==, 0);
  g_assert_true(S_ISREG(st.st_mode));
  assert_file_text(link, "replaced");
  assert_file_text(real, "real");

  /* Reading follows a symbolic link (documented). */
  g_autofree char *link2 = path_in(f, "link2.txt");
  g_assert_cmpint(symlink("real.txt", link2), ==, 0);
  g_autofree char *got = NULL;
  gsize len = 0;
  g_assert_true(wx_file_read_bounded(link2, 100, &got, &len, &err));
  g_assert_cmpstr(got, ==, "real");
}

static void
test_places_load_failure_effects(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "missing.json");
  g_autoptr(WxPlaces) pl = wx_places_new(path);
  g_autoptr(WxPlace) a = make_place("A", 10, 10);
  g_assert_true(wx_places_add(pl, a));
  guint changed = 0, dropped = 7;
  g_signal_connect(pl, "changed", G_CALLBACK(on_changed), &changed);
  GError *err = NULL;
  /* A failing load empties the list, announces that once and reports 0 dropped elements. */
  g_assert_false(wx_places_load(pl, &dropped, &err));
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_NOENT);
  g_clear_error(&err);
  g_assert_cmpuint(dropped, ==, 0);
  g_assert_cmpuint(changed, ==, 1);
  g_assert_cmpuint(wx_places_get_n_places(pl), ==, 0);
  g_assert_false(wx_places_is_dirty(pl));
  dropped = 7;
  g_assert_false(wx_places_load(pl, &dropped, NULL)); /* empty -> empty: no signal */
  g_assert_cmpuint(dropped, ==, 0);
  g_assert_cmpuint(changed, ==, 1);

  /* While a save runs the refused load still reports 0 dropped elements. */
  g_autofree char *path2 = path_in(f, "pl2.json");
  g_autoptr(WxPlaces) p2 = wx_places_new(path2);
  g_assert_true(wx_places_add(p2, a));
  AsyncState st = {&k_places_ops, p2, 0, FALSE, NULL, FALSE};
  wx_places_save_async(p2, NULL, on_saved, &st);
  dropped = 77;
  g_assert_false(wx_places_load(p2, &dropped, &err));
  g_assert_error(err, G_IO_ERROR, G_IO_ERROR_PENDING);
  g_clear_error(&err);
  g_assert_cmpuint(dropped, ==, 0);
  g_assert_cmpuint(wx_places_get_n_places(p2), ==, 1);
  wait_calls(&st, 1);
  g_assert_true(st.ok);
}

/* The callback runs in the thread-default main context of the thread that called save_async(),
 * and the cancellable may be released by the caller at once (the task holds its own reference). */
static void
test_store_save_async_context(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "ctx.json");
    GMainContext *ctx = g_main_context_new();
    g_main_context_push_thread_default(ctx);
    gpointer o = ops->create(path);
    ops->mutate(o, 0);
    AsyncState st = {ops, o, 0, FALSE, NULL, FALSE};
    GCancellable *c = g_cancellable_new();
    ops->save_async(o, c, on_saved, &st);
    g_object_unref(c); /* the task keeps the token alive */
    /* The default context never sees the completion ... */
    for (guint i = 0; i < 5; i++)
      g_assert_false(g_main_context_iteration(NULL, FALSE) && st.calls > 0);
    /* ... only the pushed one delivers it. */
    while (st.calls == 0)
      g_main_context_iteration(ctx, TRUE);
    g_assert_true(st.ok);
    g_assert_cmpuint(st.calls, ==, 1);
    g_main_context_pop_thread_default(ctx);
    g_main_context_unref(ctx);
    g_object_unref(o);
    g_assert_cmpint(g_unlink(path), ==, 0);
  }
}

typedef struct {
  const StoreOps *ops;
  gpointer obj;
  GThread *signal_thread;
  gboolean loaded;
  gboolean done;
} LoadJob;

static void
on_changed_record_thread(gpointer obj, gpointer data)
{
  (void)obj;
  LoadJob *job = data;
  job->signal_thread = g_thread_self();
}

static void
load_worker(GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable)
{
  (void)source;
  (void)cancellable;
  LoadJob *job = task_data;
  job->loaded = job->ops->load(job->obj, NULL);
  g_task_return_boolean(task, TRUE);
}

static void
load_done(GObject *source, GAsyncResult *res, gpointer data)
{
  (void)source;
  (void)res;
  ((LoadJob *)data)->done = TRUE;
}

/* The start-up pattern of the application: load() on a GTask worker thread, hand-off through the
 * task completion, use on the main thread. The "changed" signal of the load is emitted on the
 * worker thread, as documented in the headers. */
static void
test_store_load_on_worker_thread(Fixture *f, gconstpointer unused)
{
  (void)unused;
  for (guint k = 0; k < G_N_ELEMENTS(k_all_ops); k++) {
    const StoreOps *ops = k_all_ops[k];
    g_test_message("%s", ops->name);
    g_autofree char *path = path_in(f, "load.json");
    gpointer w = ops->create(path);
    for (guint i = 0; i < 3; i++)
      ops->mutate(w, i);
    g_assert_true(ops->save(w, NULL));
    g_autofree char *want = ops->fingerprint(w);
    g_object_unref(w);

    LoadJob job = {ops, ops->create(path), NULL, FALSE, FALSE};
    if (g_signal_lookup("changed", G_OBJECT_TYPE(job.obj)) != 0)
      g_signal_connect(job.obj, "changed", G_CALLBACK(on_changed_record_thread), &job);
    GTask *task = g_task_new(NULL, NULL, load_done, &job);
    g_task_set_task_data(task, &job, NULL);
    g_task_run_in_thread(task, load_worker);
    g_object_unref(task);
    while (!job.done)
      g_main_context_iteration(NULL, TRUE);
    g_assert_true(job.loaded);
    if (g_signal_lookup("changed", G_OBJECT_TYPE(job.obj)) != 0) {
      g_assert_nonnull(job.signal_thread);
      g_assert_true(job.signal_thread != g_thread_self()); /* emitted on the worker */
    }
    g_autofree char *got = ops->fingerprint(job.obj);
    g_assert_cmpstr(got, ==, want); /* usable on the main thread after the hand-off */
    g_object_unref(job.obj);
    g_assert_cmpint(g_unlink(path), ==, 0);
  }
}

/* ------------------------------------------------------------------------ */
/* wx-fileio under injected system-call failures                            */
/* ------------------------------------------------------------------------ */

static void
assert_file_text(const char *path, const char *want)
{
  g_autofree char *got = read_all(path);
  g_assert_cmpstr(got, ==, want);
}

static void
test_fileio_write_faults(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "data.bin");
  const char payload[] = "0123456789abcdef";
  GError *err = NULL;

  /* Interrupted and short writes are retried until everything is written. */
  faults.write_eintr = 3;
  faults.write_one_byte = 5;
  g_assert_true(wx_file_write_atomic(path, payload, sizeof payload - 1, &err));
  memset(&faults, 0, sizeof faults);
  g_assert_no_error(err);
  assert_file_text(path, payload);
  g_assert_cmpuint(count_files(f->dir), ==, 1);

  /* Each failing step reports its error, removes the temporary file and keeps the old content. */
  const struct {
    const char *what;
    int *slot;
    int errnum;
    GFileError code;
  } failures[] = {
    {"write", &faults.write_errno, ENOSPC, G_FILE_ERROR_NOSPC},
    {"write", &faults.write_errno, EIO, G_FILE_ERROR_IO},
    {"fsync", &faults.fsync_errno, EIO, G_FILE_ERROR_IO},
    {"close", &faults.close_errno, EIO, G_FILE_ERROR_IO},
  };
  for (guint i = 0; i < G_N_ELEMENTS(failures); i++) {
    g_test_message("%s %d", failures[i].what, failures[i].errnum);
    *failures[i].slot = failures[i].errnum;
    gboolean ok = wx_file_write_atomic(path, "replacement", 11, &err);
    memset(&faults, 0, sizeof faults);
    g_assert_false(ok);
    g_assert_error(err, G_FILE_ERROR, (int)failures[i].code);
    g_clear_error(&err);
    assert_file_text(path, payload);
    g_assert_cmpuint(count_files(f->dir), ==, 1);
  }
  /* A failure of fsync() and a failure of close() together: the first error is reported. */
  faults.fsync_errno = EIO;
  faults.close_errno = ENOSPC;
  g_assert_false(wx_file_write_atomic(path, "replacement", 11, &err));
  memset(&faults, 0, sizeof faults);
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_IO);
  g_clear_error(&err);
  g_assert_cmpuint(count_files(f->dir), ==, 1);
  /* The error argument is optional, also on the failure paths. */
  faults.write_errno = ENOSPC;
  g_assert_false(wx_file_write_atomic(path, "replacement", 11, NULL));
  memset(&faults, 0, sizeof faults);
  assert_file_text(path, payload);

  /* The directory fsync that makes the rename durable is best effort: a directory that cannot
   * be opened for reading (mode 0300) does not turn a successful write into an error. */
  g_autofree char *wdir = path_in(f, "wo");
  g_assert_cmpint(g_mkdir(wdir, 0700), ==, 0);
  g_autofree char *wfile = g_build_filename(wdir, "x.bin", NULL);
  g_assert_cmpint(g_chmod(wdir, 0300), ==, 0);
  gboolean ok = wx_file_write_atomic(wfile, "w", 1, &err);
  g_assert_cmpint(g_chmod(wdir, 0700), ==, 0);
  g_assert_no_error(err);
  g_assert_true(ok);
  assert_file_text(wfile, "w");
}

static void
test_fileio_read_faults(Fixture *f, gconstpointer unused)
{
  (void)unused;
  g_autofree char *path = path_in(f, "r.txt");
  put_text(path, "0123456789");
  g_autofree char *got = NULL;
  gsize len = 99;
  GError *err = NULL;

  /* Interrupted reads are retried. */
  faults.read_eintr = 3;
  g_assert_true(wx_file_read_bounded(path, 100, &got, &len, &err));
  memset(&faults, 0, sizeof faults);
  g_assert_no_error(err);
  g_assert_cmpstr(got, ==, "0123456789");
  g_assert_cmpuint(len, ==, 10);
  g_clear_pointer(&got, g_free);

  /* A failing read() or fstat() is reported and nothing is returned. */
  faults.read_errno = EIO;
  g_assert_false(wx_file_read_bounded(path, 100, &got, &len, &err));
  memset(&faults, 0, sizeof faults);
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_IO);
  g_clear_error(&err);
  g_assert_null(got);
  g_assert_cmpuint(len, ==, 0);
  faults.fstat_errno = EIO;
  g_assert_false(wx_file_read_bounded(path, 100, &got, &len, &err));
  memset(&faults, 0, sizeof faults);
  g_assert_error(err, G_FILE_ERROR, G_FILE_ERROR_IO);
  g_clear_error(&err);
  g_assert_null(got);

  /* A file whose size is unknown to fstat() (st_size 0) is read by growing the buffer, and the
   * limit holds however much it delivers. */
  const char *proc = "/proc/self/cmdline";
  if (!g_file_test(proc, G_FILE_TEST_IS_REGULAR)) {
    g_test_skip("/proc is not available");
    return;
  }
  g_assert_true(wx_file_read_bounded(proc, 1 << 20, &got, &len, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(len, >, 1);
  g_assert_cmpint(got[len], ==, '\0');
  gsize full = len;
  g_clear_pointer(&got, g_free);
  g_assert_true(wx_file_read_bounded(proc, full, &got, &len, &err)); /* exactly at the limit */
  g_assert_cmpuint(len, ==, full);
  g_clear_pointer(&got, g_free);
  g_assert_false(wx_file_read_bounded(proc, full - 1, &got, &len, &err)); /* one byte over */
  g_assert_error(err, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE);
  g_clear_error(&err);
  g_assert_null(got);
  g_assert_cmpuint(len, ==, 0);
  g_assert_false(wx_file_read_bounded(proc, 0, &got, &len, &err)); /* the empty limit */
  g_assert_error(err, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE);
  g_clear_error(&err);

  /* /proc/self/mem is a regular file whose first read fails with EIO. */
  if (g_file_test("/proc/self/mem", G_FILE_TEST_IS_REGULAR)) {
    g_assert_false(wx_file_read_bounded("/proc/self/mem", 1000, &got, &len, &err));
    g_assert_nonnull(err);
    g_assert_true(err->domain == G_FILE_ERROR);
    g_assert_null(got);
    g_clear_error(&err);
  }
}

#define ADD_FIXTURE(name, fn) \
  g_test_add(name, Fixture, NULL, fixture_set_up, fn, fixture_tear_down)

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);

  ADD_FIXTURE("/fileio/roundtrip", test_fileio_roundtrip);
  ADD_FIXTURE("/fileio/read-limits", test_fileio_read_limits);
  ADD_FIXTURE("/fileio/write-failures", test_fileio_write_failures);
  ADD_FIXTURE("/fileio/stale-temps", test_fileio_stale_temps);
  ADD_FIXTURE("/fileio/stale-temps-symlinks", test_fileio_stale_temps_symlinks);
  ADD_FIXTURE("/fileio/preconditions", test_fileio_preconditions);
  ADD_FIXTURE("/fileio/write-faults", test_fileio_write_faults);
  ADD_FIXTURE("/fileio/read-faults", test_fileio_read_faults);
  ADD_FIXTURE("/fileio/modes-and-links", test_fileio_modes_and_links);
  g_test_add_func("/fileio/json-depth", test_json_strict);
  g_test_add_func("/fileio/json-strict-random", test_json_strict_random);
  g_test_add_func("/fileio/json-strict-guard-page", test_json_strict_guard_page);
  g_test_add_func("/fileio/json-strict-differential", test_json_strict_differential);
  g_test_add_func("/fileio/json-strict-nul-escape", test_json_strict_nul_escape);
  g_test_add_func("/fileio/json-append-string", test_json_append_string);
  g_test_add_func("/fileio/json-append-string-null", test_json_append_string_null_args);
  g_test_add_func("/fileio/json-append-double", test_json_append_double);
  ADD_FIXTURE("/store-json/helpers", test_store_json_helpers);

  g_test_add_func("/store/default-paths", test_default_paths);
  g_test_add_func("/store/key-guard-pages", test_key_guard_pages);
  ADD_FIXTURE("/store/roundtrip", test_store_roundtrip_and_files);
  ADD_FIXTURE("/store/load-errors", test_store_load_errors);
  ADD_FIXTURE("/store/hostile-nesting", test_store_hostile_nesting);
  ADD_FIXTURE("/store/save-failure", test_store_save_failure);
  ADD_FIXTURE("/store/save-async", test_store_save_async);
  ADD_FIXTURE("/store/save-async-failure-and-cancel", test_store_save_async_failure_and_cancel);
  ADD_FIXTURE("/store/save-async-unref-while-running", test_store_save_async_unref_while_running);
  ADD_FIXTURE("/store/save-async-many", test_store_save_async_many);
  ADD_FIXTURE("/store/save-async-context", test_store_save_async_context);
  ADD_FIXTURE("/store/load-on-worker-thread", test_store_load_on_worker_thread);
  ADD_FIXTURE("/store/stale-temps", test_store_stale_temps_removed_by_load);
  ADD_FIXTURE("/store/fuzz", test_store_fuzz);
  ADD_FIXTURE("/store/nul-escape-settings", test_store_nul_escape_settings);
  ADD_FIXTURE("/store/nul-escape-places", test_store_nul_escape_places);
  ADD_FIXTURE("/store/nul-escape-cache", test_store_nul_escape_cache);

  g_test_add_func("/places/basic", test_places_basic);
  g_test_add_func("/places/duplicate-boundaries", test_places_duplicate_boundaries);
  g_test_add_func("/places/capacity", test_places_capacity);
  g_test_add_func("/places/preconditions", test_places_preconditions);
  ADD_FIXTURE("/places/roundtrip-exact", test_places_roundtrip_exact);
  ADD_FIXTURE("/places/max-file-size", test_places_max_file_size);
  ADD_FIXTURE("/places/load-partial", test_places_load_partial);
  ADD_FIXTURE("/places/load-cap", test_places_load_cap);
  ADD_FIXTURE("/places/dirty-and-signals", test_places_dirty_and_signals);
  ADD_FIXTURE("/places/load-failure-effects", test_places_load_failure_effects);

  g_test_add_func("/settings/basic", test_settings_basic);
  g_test_add_func("/settings/selected-keys", test_settings_selected_keys);
  g_test_add_func("/settings/preconditions", test_settings_preconditions);
  ADD_FIXTURE("/settings/load-partial", test_settings_load_partial);
  ADD_FIXTURE("/settings/roundtrip", test_settings_roundtrip);

  g_test_add_func("/cache/put-get-age", test_cache_put_get_age);
  g_test_add_func("/cache/limits-reject", test_cache_limits_reject);
  g_test_add_func("/cache/lru", test_cache_lru);
  g_test_add_func("/cache/preconditions", test_cache_preconditions);
  ADD_FIXTURE("/cache/roundtrip", test_cache_roundtrip);
  ADD_FIXTURE("/cache/double-precision", test_cache_double_precision);
  ADD_FIXTURE("/cache/load-mutations", test_cache_load_mutations);
  ADD_FIXTURE("/cache/load-oversized-arrays", test_cache_load_oversized_arrays);
  ADD_FIXTURE("/cache/load-duplicates-and-cap", test_cache_load_duplicates_and_cap);
  ADD_FIXTURE("/cache/max-file-size", test_cache_max_file_size);
  ADD_FIXTURE("/cache/control-bytes-roundtrip", test_cache_control_bytes_roundtrip);
  ADD_FIXTURE("/cache/snapshot-is-stable", test_cache_snapshot_is_stable);

  return g_test_run();
}
