gio_dep = dependency('gio-2.0', version: '>= 2.68')
json_dep = dependency('json-glib-1.0', version: '>= 1.10.0')

storage_inc = include_directories('.')

storage_lib = static_library(
  'wx-storage',
  'wx-fileio.c',
  'wx-store-json.c',
  'wx-places.c',
  'wx-settings.c',
  'wx-cache.c',
  include_directories: storage_inc,
  dependencies: [core_dep, glib_dep, gio_dep, json_dep],
)

storage_dep = declare_dependency(
  include_directories: storage_inc,
  link_with: storage_lib,
  dependencies: [core_dep, glib_dep, gio_dep, json_dep],
)

test_storage = executable(
  'test-storage',
  'test-storage.c',
  dependencies: storage_dep,
)

# Explicit: the default 30 s is too tight under sanitizers/valgrind on a loaded machine.
test('storage', test_storage, suite: 'storage', timeout: 120)
