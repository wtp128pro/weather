gio_dep = dependency('gio-2.0', version: '>= 2.68')
gobject_dep = dependency('gobject-2.0', version: '>= 2.68')
soup_dep = dependency('libsoup-3.0', version: '>= 3.0')
# >= 1.10: json-glib 1.10 added the parser's nesting-depth cap; older versions
# overflow the stack on deeply nested input, and this module parses untrusted
# JSON (wx-json.c additionally enforces its own, much lower, depth limit).
json_dep = dependency('json-glib-1.0', version: '>= 1.10.0')

net_deps = [core_dep, gio_dep, gobject_dep, soup_dep, json_dep]

net_inc = include_directories('.')

net_lib = static_library(
  'wx-net',
  'wx-http.c',
  'wx-json.c',
  'wx-provider.c',
  'wx-registry.c',
  include_directories: net_inc,
  dependencies: net_deps,
)

net_dep = declare_dependency(
  include_directories: net_inc,
  link_with: net_lib,
  dependencies: net_deps,
)

# TEST-ONLY: fake WxProvider / WxGeocoder implementations for the tests of the
# modules above this one. Never linked into the application.
net_testing_lib = static_library(
  'wx-net-testing',
  'wx-fake-provider.c',
  include_directories: net_inc,
  dependencies: net_dep,
)

net_testing_dep = declare_dependency(
  include_directories: net_inc,
  link_with: net_testing_lib,
  dependencies: net_dep,
)

# Offline: the request layer (retries, timeouts, caps, cancellation) runs
# against a loopback fake server. Nothing here touches the Internet. The
# whole-operation deadline test takes 45 s of wall time by design, so it is a
# test of its own and runs in parallel with the rest.
test_http = executable(
  'test-http',
  'test-http.c',
  dependencies: net_dep,
)

test(
  'http',
  test_http,
  args: ['-x', '/http/deadline'],
  suite: 'net',
  timeout: 180,
)

test(
  'http-deadline',
  test_http,
  args: ['-p', '/http/deadline'],
  suite: 'net',
  timeout: 180,
)

test_registry = executable(
  'test-registry',
  'test-registry.c',
  dependencies: net_testing_dep,
)

test('registry', test_registry, suite: 'net')
