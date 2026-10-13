service_deps = [core_dep, net_dep, blend_dep]

service_inc = include_directories('.')

service_sources = ['wx-service.c']

service_lib = static_library(
  'wx-service',
  service_sources,
  include_directories: service_inc,
  dependencies: service_deps,
)

service_dep = declare_dependency(
  include_directories: service_inc,
  link_with: service_lib,
  dependencies: service_deps,
)

# Test flavour: the same source compiled with -DWX_SERVICE_TESTING, which adds the
# replaceable refresh deadline of wx-service-testing.h (it lets the tests cross the 30-second
# deadline in a fraction of a second). Only test-service links it; the library above and
# anything built from it contain no hook and no writable variable.
service_testing_lib = static_library(
  'wx-service-testing',
  service_sources,
  c_args: ['-DWX_SERVICE_TESTING'],
  include_directories: service_inc,
  dependencies: service_deps,
)

service_testing_dep = declare_dependency(
  include_directories: service_inc,
  link_with: service_testing_lib,
  dependencies: service_deps,
)

# Offline: the service runs against the fake providers and geocoder of the net module and against
# hand-written misbehaving ones. Nothing here touches the network.
test_service = executable(
  'test-service',
  'test-service.c',
  dependencies: [service_testing_dep, net_testing_dep],
)

test('service', test_service, suite: 'service', timeout: 180)

# The production flavour (no deadline hook) as the application links it: the real 30-second
# deadline takes 30 s of wall time by design, so this is a test of its own and runs in parallel
# with the rest.
test_service_production = executable(
  'test-service-production',
  'test-service-production.c',
  dependencies: [service_dep, net_testing_dep],
)

test('service-production', test_service_production, suite: 'service', timeout: 120)
