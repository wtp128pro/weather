# The refresh policy is pure logic (GLib + core only): no GTK, no main loop.
sched_inc = include_directories('.')

sched_lib = static_library(
  'wx-scheduler',
  'wx-scheduler.c',
  include_directories: sched_inc,
  dependencies: core_dep,
)

sched_dep = declare_dependency(
  include_directories: sched_inc,
  link_with: sched_lib,
  dependencies: core_dep,
)

# Offline, no display: the scheduler is driven with a fake clock.
test_scheduler = executable(
  'test-scheduler',
  'test-scheduler.c',
  dependencies: sched_dep,
)

test('scheduler', test_scheduler, suite: 'sched')
