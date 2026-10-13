%global app_id io.github.wtp128pro.Weather

Name:           weather
Version:        0.1.0
Release:        1%{?dist}
Summary:        GTK4 desktop weather app that blends several free forecast sources

# The program and its icons are GPL-3.0-or-later; the AppStream metainfo file is CC0-1.0.
License:        GPL-3.0-or-later AND CC0-1.0
URL:            https://github.com/wtp128pro/weather
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildRequires:  gcc
BuildRequires:  meson
BuildRequires:  pkgconfig(gtk4) >= 4.14
BuildRequires:  pkgconfig(libsoup-3.0)
BuildRequires:  pkgconfig(json-glib-1.0) >= 1.10.0
BuildRequires:  pkgconfig(glib-2.0) >= 2.68
BuildRequires:  pkgconfig(gio-2.0) >= 2.68
# glib-compile-resources (compiles the CSS into the binary)
BuildRequires:  glib2-devel
# %%check
BuildRequires:  desktop-file-utils
BuildRequires:  libappstream-glib
BuildRequires:  appstream
BuildRequires:  xorg-x11-server-Xvfb

Requires:       hicolor-icon-theme

%description
Weather is a small GTK4 desktop application. It keeps a list of places you add
by searching worldwide and shows for each the current conditions, when rain
starts or ends, an hourly and a daily forecast, and in the contiguous United
States (a bounding box that also covers parts of Canada, Mexico and the
Caribbean) a 15-minute rain forecast for the next two hours. Imperial units
are the default; a switch changes to metric.

Each forecast blends several free sources without API keys: Open-Meteo, the US
National Weather Service (United States only) and MET Norway. The blend weights
are documented rules of thumb, not statistics measured from past accuracy; no
accuracy figure is claimed. A local cache keeps the last forecast visible when
offline. The program sends no telemetry and does not determine your location.

Weather is not affiliated with, endorsed by or sponsored by Open-Meteo, MET
Norway or NOAA.

%prep
%autosetup

%build
%meson
%meson_build

%install
%meson_install

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{app_id}.desktop
appstream-util validate-relax --nonet %{buildroot}%{_metainfodir}/%{app_id}.metainfo.xml
# The GUI tests need an X display; none of the tests uses the network.
# GTK_IM_MODULE=simple keeps GTK from connecting to an input-method daemon.
GTK_IM_MODULE=simple GTK_A11Y=none xvfb-run -a %{shrink:%meson_test}

%files
%license COPYING
%doc README.md
%{_bindir}/weather
%{_datadir}/applications/%{app_id}.desktop
%{_metainfodir}/%{app_id}.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/%{app_id}.svg
%{_datadir}/icons/hicolor/symbolic/apps/%{app_id}-symbolic.svg

%changelog
* Tue Oct 13 2026 wtp128pro - 0.1.0-1
- Initial package
