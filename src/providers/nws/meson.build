nws_inc = include_directories('.')
nws_sources = files('wx-nws.c')

nws_lib = static_library(
  'wx-nws',
  nws_sources,
  include_directories: nws_inc,
  dependencies: [net_dep],
)

nws_dep = declare_dependency(
  include_directories: nws_inc,
  link_with: nws_lib,
  dependencies: [net_dep],
)

# Test flavour: the same source compiled with -DWX_NWS_TESTING (a replaceable clock, see
# wx-nws-testing.h). Only the test executable links it; the library above and the application
# contain none of it.
nws_testing_lib = static_library(
  'wx-nws-testing',
  nws_sources,
  c_args: ['-DWX_NWS_TESTING'],
  include_directories: nws_inc,
  dependencies: [net_dep],
)

nws_testing_dep = declare_dependency(
  include_directories: nws_inc,
  link_with: nws_testing_lib,
  dependencies: [net_dep],
)

# Offline: parsers over the captured fixtures and hostile bodies, and the provider against a
# loopback fake server. Nothing here touches the Internet.
test_nws = executable(
  'test-nws',
  'test-nws.c',
  c_args: ['-DWX_NWS_FIXTURE_DIR="' + meson.current_source_dir() / 'fixtures' + '"'],
  dependencies: [nws_testing_dep, net_testing_dep],
)

test('nws', test_nws, suite: 'providers', timeout: 120)
