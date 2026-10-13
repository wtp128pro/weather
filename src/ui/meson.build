gnome = import('gnome')

gtk_dep = dependency('gtk4', version: '>= 4.14', include_type: 'system')
gio_dep = dependency('gio-2.0', version: '>= 2.68')

ui_inc = include_directories('.')

# style.css is compiled into the binary; the app reads no resource from disk.
ui_resources = gnome.compile_resources(
  'wx-ui-resources',
  'weather.gresource.xml',
  source_dir: meson.current_source_dir(),
  c_name: 'wx_ui',
)

# Generated resource code is not ours to keep warning-free under -Wpedantic.
ui_resources_lib = static_library(
  'wx-ui-resources',
  ui_resources[0],
  c_args: ['-Wno-overlength-strings'],
  dependencies: gio_dep,
)

ui_deps = [
  core_dep,
  net_dep,
  providers_dep,
  blend_dep,
  service_dep,
  storage_dep,
  sched_dep,
  widgets_dep,
  gtk_dep,
]

ui_lib = static_library(
  'wx-ui',
  'wx-row.c',
  'wx-detail.c',
  'wx-sources.c',
  'wx-picker.c',
  'wx-window.c',
  ui_resources[1],
  c_args: ['-DWX_APP_VERSION="@0@"'.format(meson.project_version())],
  include_directories: ui_inc,
  link_with: ui_resources_lib,
  dependencies: ui_deps,
)

# wx-app.c is the only caller of the three save functions, so it is a library of its own: the
# test of the window builds its own copy of it (see below).
ui_app_args = ['-DWX_APP_VERSION="@0@"'.format(meson.project_version())]

ui_app_lib = static_library(
  'wx-ui-app',
  'wx-app.c',
  ui_resources[1],
  c_args: ui_app_args,
  include_directories: ui_inc,
  dependencies: ui_deps,
)

ui_dep = declare_dependency(
  include_directories: ui_inc,
  link_with: [ui_lib, ui_app_lib],
  sources: ui_resources[1],
  dependencies: ui_deps,
)

weather_exe = executable(
  'weather',
  'main.c',
  dependencies: ui_dep,
  install: true,
)

# GUI tests: they need a display (run under xvfb-run) and exit 77, "skipped", when GTK cannot
# initialise. They use the TEST-ONLY fake providers of the net module and loopback-free fakes of
# their own: nothing touches the network, and the XDG directories are redirected into a temp root
# (see test-support.h). The windows come and go on the shared display and change which window is
# active there, so the GUI tests run one after the other.
ui_test_env = {
  'GTK_A11Y': 'none',
  'GTK_IM_MODULE': 'simple',
  'GSETTINGS_BACKEND': 'memory',
}

# test-window counts the saves the application starts and finishes (see "Saves in flight" in
# test-window.c). It links its own copy of wx-app.c, compiled with the three save functions
# renamed by the PREPROCESSOR to counting functions that the test defines (which call the real
# ones). Unlike link-time interposition (--wrap), this cannot be bypassed by LTO or by IPA clones
# of the callee, whatever CFLAGS / b_lto say, and the production code carries no test hook. The
# first test of test-window (save-counter-self-check) fails, naming the kind of save, if a kind
# is ever not counted.
test_window_app_lib = static_library(
  'wx-ui-app-counted-saves',
  'wx-app.c',
  ui_resources[1],
  c_args: ui_app_args + [
    '-Dwx_places_save_async=wx_test_counted_wx_places_save_async',
    '-Dwx_settings_save_async=wx_test_counted_wx_settings_save_async',
    '-Dwx_cache_save_async=wx_test_counted_wx_cache_save_async',
  ],
  include_directories: ui_inc,
  dependencies: ui_deps,
)

test_window_ui_dep = declare_dependency(
  include_directories: ui_inc,
  link_with: [ui_lib, test_window_app_lib],
  sources: ui_resources[1],
  dependencies: ui_deps,
)

test_window = executable(
  'test-window',
  'test-window.c',
  dependencies: [test_window_ui_dep, net_testing_dep],
)

# The binary test needs the real executable (SIGTERM / SIGINT end it cleanly). The tests that need
# minutes of wall time shift the process clocks instead of waiting (see test-window.c).
window_env = ui_test_env + {'WX_WEATHER_BIN': weather_exe.full_path()}

test(
  'window',
  test_window,
  suite: 'ui',
  timeout: 300,
  is_parallel: false,
  env: window_env,
  depends: weather_exe,
)

test_picker = executable(
  'test-picker',
  'test-picker.c',
  dependencies: [ui_dep, net_testing_dep],
)

test(
  'picker',
  test_picker,
  suite: 'ui',
  timeout: 180,
  is_parallel: false,
  env: ui_test_env,
)

test_sources = executable(
  'test-sources',
  'test-sources.c',
  dependencies: [ui_dep, net_testing_dep],
)

test(
  'sources',
  test_sources,
  suite: 'ui',
  timeout: 120,
  is_parallel: false,
  env: ui_test_env,
)

test_detail = executable(
  'test-detail',
  'test-detail.c',
  dependencies: [ui_dep, net_testing_dep],
)

test(
  'detail',
  test_detail,
  suite: 'ui',
  timeout: 120,
  is_parallel: false,
  env: ui_test_env,
)
