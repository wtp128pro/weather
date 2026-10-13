metno_inc = include_directories('.')

metno_sources = ['wx-metno.c']

metno_lib = static_library(
  'wx-metno',
  metno_sources,
  include_directories: metno_inc,
  dependencies: [net_dep],
)

metno_dep = declare_dependency(
  include_directories: metno_inc,
  link_with: metno_lib,
  dependencies: [net_dep],
)

# Test flavour: the same source compiled with -DWX_METNO_TESTING, which adds the
# clock hook of wx-metno-testing.h (it lets the tests pass the 10-minute floor,
# Expires times and the 429 throttle without waiting). Only the test
# executables link it; the library above and anything built from it contain
# no writable function pointer.
metno_testing_lib = static_library(
  'wx-metno-testing',
  metno_sources,
  c_args: ['-DWX_METNO_TESTING'],
  include_directories: metno_inc,
  dependencies: [net_dep],
)

metno_testing_dep = declare_dependency(
  include_directories: metno_inc,
  link_with: metno_testing_lib,
  dependencies: [net_dep],
)

# Offline: the parser runs on captured fixtures and hostile synthetic bodies;
# the request layer, cache and throttle run against a loopback fake server.
# Nothing here touches the Internet.
test_metno = executable(
  'test-metno',
  'test-metno.c',
  dependencies: metno_testing_dep,
)

test(
  'metno',
  test_metno,
  args: [meson.current_source_dir() / 'fixtures'],
  suite: 'providers',
  timeout: 180,
)

# The production flavour (no clock hook) as the application links it.
test_metno_production = executable(
  'test-metno-production',
  'test-metno-production.c',
  dependencies: metno_dep,
)

test(
  'metno-production',
  test_metno_production,
  args: [meson.current_source_dir() / 'fixtures'],
  suite: 'providers',
)
