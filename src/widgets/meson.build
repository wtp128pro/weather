gtk_dep = dependency('gtk4', version: '>= 4.14', include_type: 'system')

widgets_inc = include_directories('.')

format_sources = ['wx-format.c', 'wx-icons.c']
widget_sources = ['wx-rain-chart.c', 'wx-hour-strip.c', 'wx-day-list.c', 'wx-widget-util.c']

# GTK-free part: text formatting and icon names. It uses wx_forecast_now() of the pure blend module
# (the current conditions of a forecast), so that the texts and the "Now" card show the same
# interpolated values as the header of the detail pane.
format_lib = static_library(
  'wx-format',
  format_sources,
  include_directories: widgets_inc,
  dependencies: [core_dep, blend_dep],
)

format_dep = declare_dependency(
  include_directories: widgets_inc,
  link_with: format_lib,
  dependencies: [core_dep, blend_dep],
)

widgets_lib = static_library(
  'wx-widgets',
  widget_sources,
  include_directories: widgets_inc,
  dependencies: [format_dep, gtk_dep],
)

widgets_dep = declare_dependency(
  include_directories: widgets_inc,
  link_with: widgets_lib,
  dependencies: [format_dep, gtk_dep],
)

# Test flavour: the same sources, with wx-format.c compiled with -DWX_FORMAT_TESTING (zone load
# counter and loader / clock hooks, see wx-format-testing.h). Only the test executables link it; the
# production libraries above and anything built from them contain none of it.
format_testing_lib = static_library(
  'wx-format-testing',
  format_sources,
  c_args: ['-DWX_FORMAT_TESTING'],
  include_directories: widgets_inc,
  dependencies: [core_dep, blend_dep],
)

format_testing_dep = declare_dependency(
  include_directories: widgets_inc,
  link_with: format_testing_lib,
  dependencies: [core_dep, blend_dep],
)

widgets_testing_lib = static_library(
  'wx-widgets-testing',
  widget_sources,
  include_directories: widgets_inc,
  dependencies: [format_testing_dep, gtk_dep],
)

widgets_testing_dep = declare_dependency(
  include_directories: widgets_inc,
  link_with: widgets_testing_lib,
  dependencies: [format_testing_dep, gtk_dep],
)

test_format = executable(
  'test-format',
  'test-format.c',
  dependencies: format_testing_dep,
)
test('format', test_format, suite: 'widgets')

test_widgets = executable(
  'test-widgets',
  'test-widgets.c',
  dependencies: widgets_testing_dep,
)
# The suite waits for real redraws (about 20 s, 26 s under ASan+UBSan): well above the default 30 s.
test('widgets', test_widgets, suite: 'widgets', timeout: 120)
