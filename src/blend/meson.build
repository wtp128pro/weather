blend_inc = include_directories('.')

blend_lib = static_library(
  'wx-blend',
  'wx-weights.c',
  'wx-blend.c',
  'wx-condition.c',
  'wx-rain.c',
  'wx-daily.c',
  include_directories: blend_inc,
  dependencies: core_dep,
)

blend_dep = declare_dependency(
  include_directories: blend_inc,
  link_with: blend_lib,
  dependencies: core_dep,
)

test_blend = executable(
  'test-blend',
  'test-blend.c',
  dependencies: blend_dep,
)

# Explicit: the default 30 s is too tight under sanitizers/valgrind on a loaded machine.
test('blend', test_blend, suite: 'blend', timeout: 120)
