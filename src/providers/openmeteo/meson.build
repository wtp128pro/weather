openmeteo_inc = include_directories('.')

openmeteo_lib = static_library(
  'wx-openmeteo',
  'wx-openmeteo.c',
  include_directories: openmeteo_inc,
  dependencies: net_dep,
)

openmeteo_dep = declare_dependency(
  include_directories: openmeteo_inc,
  link_with: openmeteo_lib,
  dependencies: net_dep,
)

# Offline: the parsers run on captured fixtures and hostile synthetic bodies;
# the request layer runs against a loopback fake server. Nothing here touches
# the Internet.
test_openmeteo = executable(
  'test-openmeteo',
  'test-openmeteo.c',
  dependencies: openmeteo_dep,
)

test(
  'openmeteo',
  test_openmeteo,
  args: [meson.current_source_dir() / 'fixtures'],
  suite: 'providers',
  timeout: 180,
)

# The exhaustive sweep (every Unicode scalar value, plus a defined set of raw
# byte sequences: all 2-byte pairs, all 3-byte sequences refused by the decoder
# with lead E0..EF,
# and sampled 4-, 5- and 6-byte forms; see the test; through the public search API,
# millions of loopback requests: minutes) is
# skipped by the test above. Run it with
#   meson test --benchmark --suite providers-exhaustive
# or by hand: test-openmeteo fixtures -m slow -p /openmeteo/geocoder/scalar-sweep-exhaustive
benchmark(
  'openmeteo-exhaustive',
  test_openmeteo,
  args: [
    meson.current_source_dir() / 'fixtures',
    '-m', 'slow',
    '-p', '/openmeteo/geocoder/scalar-sweep-exhaustive',
  ],
  suite: 'providers-exhaustive',
  timeout: 7200,
)
