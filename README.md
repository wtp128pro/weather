# Weather

Weather is a small GTK4 desktop weather app written in C11 (GTK 4, libsoup 3,
json-glib). You add places by searching for them; for each place it shows the
current conditions, when rain starts or ends, the cloud cover, an hourly
forecast and a daily forecast. Every forecast is a blend of several free
sources. It needs no account or API key, sends no telemetry and never
determines your location by itself. It is the sibling of the `stocks` desktop
app and shares its structure, build tooling and packaging.

Licence: GPL-3.0-or-later (see `COPYING`). Version 0.1.0.
Source: https://github.com/wtp128pro/weather

## Features

- Several free providers, no keys: Open-Meteo, the US National Weather Service
  (api.weather.gov, United States only) and MET Norway. The provider list is
  extensible (a provider implements the `WxProvider` interface and is added to
  the registry); each one can be switched off in the sources popover.
- Per-variable blending: temperature, wind, cloud cover, humidity, rain amount
  and rain chance each have their own weights per source and model. In the US
  region the weights also depend on the forecast horizon (four bands); outside
  it the table is flat: one weight per variable and model, the same at every
  horizon (see "Accuracy statement" below).
- Florida and US focus: for places inside the code's bounding boxes of the
  contiguous United States (boxes that also cover parts of Canada, Mexico and
  the Caribbean) the blend uses the NWS forecast and the HRRR and NBM models
  (the latter two through Open-Meteo), and Open-Meteo also supplies a
  15-minute rain nowcast (HRRR) for the next two hours. Everywhere there is
  an hourly forecast and a daily forecast. The detail pane always shows the
  24-hour rain-chance bars (from the hourly forecast) and, when a nowcast
  exists, the next-two-hours chart next to them; the 48-hour hourly cards
  follow below.
- Multi-location: search any city worldwide (Open-Meteo geocoding), keep up to
  50 places, switch between them in the sidebar.
- Rain and cloud timing in plain language, for example "Raining now,
  easing around 5 PM" or "No rain expected for the next 48 hours". "Dry" is
  only claimed when the forecast knows the rain of the whole 48 hours; a
  forecast that is too old to cover the present moment (or that has gaps or
  unknown amounts) makes no rain claim ("No rain data").
- Today: the High and Low of today stay visible until local midnight. The
  blended forecast starts one hour before the moment it was blended, so they
  cover the hours of today from there on; when that is not the start of the
  day the label says so ("High 80° · Low 65° (from 2 PM)").
- Units: imperial by default (degrees F, mph, inches); one switch changes to
  metric (degrees C, km/h, millimetres).
- A local cache keeps the last forecast visible offline; stale places are
  marked.

## Data sources, licences and attribution (read this)

The app shows each source's attribution in the sources popover and links to
it. The texts below are the ones the code uses.

| Source | Shown as | Licence and terms |
| --- | --- | --- |
| Open-Meteo (forecast and geocoding) | "Weather data by Open-Meteo.com", link https://open-meteo.com/ ; licence line "Open-Meteo data is licensed CC BY 4.0" (https://creativecommons.org/licenses/by/4.0/) | CC BY 4.0: the attribution link is required. The free API is for non-commercial use and has rate limits. |
| MET Norway (api.met.no locationforecast) | "Data from MET Norway", link https://api.met.no/ ; licence line "MET Norway data: CC BY 4.0 / NLOD" (https://api.met.no/doc/License) | NLOD / CC BY 4.0. Requests must carry an identifying User-Agent; the app sends one and asks for a given place at most once per 10 minutes (`WX_METNO_MIN_REFRESH_S` = 600), tracked in memory for the running process and only for the 32 most recently requested places (`WX_METNO_CACHE_MAX`). |
| NWS (api.weather.gov) | "Source: NOAA/National Weather Service", link https://www.weather.gov/ ; licence line "NOAA/National Weather Service data is US government work, credited as a courtesy" | US government data, public domain. The API wants a User-Agent with contact information; the app sends one. Covers the United States only; elsewhere the NWS provider reports the place as unsupported and is skipped. |

Every request carries the User-Agent
`weather-app/0.1 (github.com/wtp128pro/weather)`.

Weather is not affiliated with, endorsed by or sponsored by Open-Meteo, MET
Norway or NOAA.

## Accuracy statement

"Highly accurate" is the design goal of this app, not a measured result. The
blend weights (per variable and per source and model; in the US region also
per horizon band of 0-3 h, 3-18 h, 18-72 h and from 72 h, elsewhere flat over
the horizon) are documented heuristics, rules of thumb
written down in `src/blend/wx-weights.c`. They are not statistics and were
not fitted to forecast-verification data. No accuracy measurement of this app
or of the blend was performed, so no accuracy figure is claimed; the app says
so in the sources popover too. Treat the forecast as you would any single
free forecast.

## Security model

Described here is only what the code does.

- Network: all traffic goes through one module (`src/net/wx-http.c`). It
  makes read-only GET requests over HTTPS; plain HTTP is accepted only to
  127.0.0.1, ::1 and localhost, which exists for the offline tests. TLS
  certificates are always verified. Each provider talks to one fixed host
  (api.open-meteo.com and geocoding-api.open-meteo.com, api.weather.gov,
  api.met.no); the path of a request cannot change the host. Redirects are
  never followed. No cookie, credential, API key or referrer is sent.
- Limits: a response body is capped at 4 MiB after decoding (a larger one is
  refused), an attempt times out after 10 s, a whole operation after 45 s,
  there are at most 2 retries (only after network errors, time-outs and HTTP
  5xx), and at most 16 requests are in flight at once per HTTP client (there
  are four: one each for Open-Meteo forecasts, Open-Meteo geocoding, NWS and
  MET Norway, so up to 64 overall). HTTP 429 is reported as a rate limit and
  not retried.
- External data is parsed defensively: numbers are range-checked, values
  outside the physical range are discarded, and text is sanitised before it is
  shown. Attribution links are shown only if they are `https://` URLs of
  bounded length.
- No API keys, no accounts and no telemetry: the only outgoing requests are
  the forecast and place-search requests for the places you add, plus the
  User-Agent above.
- No location detection: places come from your search only (no GPS, no IP
  geolocation).
- Storage: plain files under the XDG directories, no sandbox is used. The app
  writes `places.json` and `settings.json` in `$XDG_CONFIG_HOME/weather/`
  (default `~/.config/weather/`) and `forecasts.json` in
  `$XDG_CACHE_HOME/weather/` (default `~/.cache/weather/`). Files are written
  to a temporary file, fsync()ed and renamed into place, with mode 0600; the
  directories it creates have mode 0700. Files are read with size limits
  (1 MiB for places, 8 MiB for the cache) and a JSON nesting limit.
- Hardened build flags (set in `meson.build`, each only if the compiler
  supports it): `-fstack-protector-strong`, `-Wformat=2 -Wformat-security`,
  `-D_FORTIFY_SOURCE=2` when the build is optimised and the flag is not
  already set, and the linker options `-z relro -z now`.

## Install

### From the signed RPM repository (Fedora, recommended)

The RPMs and the repository metadata are signed. The repository serves
Fedora 44 (`x86_64` and source) only. With dnf5:

```sh
sudo dnf config-manager addrepo --from-repofile=https://wtp128pro.github.io/weather/weather.repo
sudo dnf install weather
```

or, without the plugin:

```sh
sudo curl -fsSLo /etc/yum.repos.d/weather.repo https://wtp128pro.github.io/weather/weather.repo
curl -fsSLo RPM-GPG-KEY-weather https://wtp128pro.github.io/weather/RPM-GPG-KEY-weather
gpg --show-keys RPM-GPG-KEY-weather          # compare the fingerprint below
sudo rpm --import RPM-GPG-KEY-weather
sudo dnf install weather
```

The signing key is

```
Weather Release Signing Key <wtp128pro@users.noreply.github.com>
RSA 4096, created 2026-10-11, expires 2029-10-10
Fingerprint: 6C3D CB7D 86FE 6795 DC72  5E97 FC6A DF53 F5A8 E21F
```

Compare the fingerprint with the one `dnf` shows when it asks you to confirm
the key, with the key file `packaging/rpm/RPM-GPG-KEY-weather` in this
repository and with https://wtp128pro.github.io/weather/. To check a
downloaded package by hand: `rpm -K weather-*.rpm` must print
`digests signatures OK` (an unsigned package also exits 0 but prints only
`digests OK`).

### Build from source

Dependencies (pkg-config names): `gtk4` >= 4.14, `libsoup-3.0`,
`json-glib-1.0` >= 1.10.0, `glib-2.0` >= 2.68 (with `glib-compile-resources`),
plus Meson >= 1.0, Ninja and a C11 compiler. On Fedora:

```sh
sudo dnf install gcc meson ninja-build gtk4-devel libsoup3-devel json-glib-devel glib2-devel
# to run the whole test suite as well:
sudo dnf install desktop-file-utils libappstream-glib appstream xorg-x11-server-Xvfb
```

```sh
meson setup build              # configure (debugoptimized, warning_level=3)
meson compile -C build         # builds build/src/ui/weather
meson install -C build         # default prefix /usr/local
```

`meson install` installs exactly five files: `bin/weather`, the desktop entry,
the AppStream metainfo file, and the full-colour and the symbolic icon. It does
not refresh icon or desktop-entry caches.

### Makefile

`make` (or `make help`) wraps Meson and needs GNU make >= 3.82. Targets:

- `build` (alias `all`): configure `BUILDDIR` (default `build`) if needed and
  compile.
- `test`: `meson test` with no display variable set, so the GUI tests that
  need a display are skipped and no window opens.
- `check`: the whole suite, GUI tests included, under Xvfb inside
  `unshare -rmn` with a private `/tmp` and loopback only; safe on a desktop.
  The checkout and `BUILDDIR` must not be under `/tmp`.
- `release`: a release build in `RELEASE_BUILDDIR` (default `build-release`),
  with buildtype, debug level, optimisation and prefix enforced and verified.
- `install`: `release`, a verified scratch install (exactly 5 files, modes
  0755/0644, stripped binary), then `meson install --strip` into `PREFIX`
  (default `~/.local`, honours `DESTDIR`), then icon-cache and desktop-database
  refresh. Refuses to run as root and never uses sudo.
- `uninstall`: removes the files the last install logged
  (`RELEASE_BUILDDIR/meson-logs/install-log.txt`), without rebuilding.
- `rpm`: source and binary RPMs of git `HEAD` (not the working tree), built
  under `unshare -rmn` with `RPMTOP` (default `~/.cache/weather-rpmbuild`) as
  topdir; the checkout and `RPMTOP` must not be under `/tmp`.
- `clean`: remove `BUILDDIR`. `distclean`: remove `BUILDDIR`,
  `RELEASE_BUILDDIR` and `RPMTOP` (only if it was made by `make rpm`); run
  `make uninstall` first. Both refuse an empty name, `/`, the checkout,
  `$HOME` and directories that are not what they should be.

### Run

```sh
build/src/ui/weather           # from the build directory
weather                        # after installing
```

The application id is `io.github.wtp128pro.Weather`.

### Test

```sh
GTK_IM_MODULE=simple GTK_A11Y=none xvfb-run -a meson test -C build
```

`GTK_IM_MODULE=simple` keeps the GUI tests from connecting to your real
input-method daemon. No test uses the network (the HTTP, provider and service
tests use a loopback fake server), and the tests redirect the XDG directories
into a temporary directory, so your real settings, places and cache are never
touched. The `data` suite checks the packaging files: `app-id`
(`data/check-app-id.sh`, comparing the application id in `src/ui/wx-app.h`
with the desktop entry, metainfo, icon names and GResource paths) always runs;
`desktop-file-validate`, `appstreamcli validate --no-net` and
`appstream-util validate-relax --nonet` run only if the tool is installed.

## Refresh policy

- A refresh happens only while the window is visible and the network is
  available. Rounds (every place) run when the window becomes visible, when it
  regains focus, when the network returns and every 10 minutes
  (`WX_SCHED_PERIOD_US`) while those conditions hold; a newly added place is
  fetched at once.
- A place with a successful fetch younger than 2 minutes is skipped by an
  event round, one younger than 9 minutes by a periodic round. At most 3
  refreshes (places being fetched) are in flight (`WX_SCHED_MAX_INFLIGHT`);
  each refresh asks every enabled source that covers the place, and a
  source makes one or two HTTP requests (Open-Meteo two inside the
  contiguous-US boxes, MET Norway one, NWS a place lookup that is remembered
  and the grid forecast).
- A failed fetch keeps the cached data on screen, marks the place stale, and
  is retried by the next round; nothing retries it by itself.
- A manual refresh of a place is not started earlier than 10 seconds after its
  latest request started or succeeded (`WX_APP_REFRESH_MIN_GAP_S`), and not
  earlier than 60 seconds after a refresh failed with a rate limit
  (`WX_APP_RATE_LIMIT_COOLDOWN_S`). During that cool-down nothing asks the
  place again (the scheduler's rounds skip it too); when it has ended, the
  place is fetched once more at once, so a place whose sources keep
  answering with a rate limit is retried about every 60 seconds.
- Only a rate limit of a server (HTTP 429, or a pause a provider keeps after
  one) starts that cool-down. A provider's own refusal to send a request
  (MET Norway's once-per-10-minutes-per-place floor, or a provider's cap on
  requests in flight) is no failure of a server: it never outranks another
  source's real error in the message shown for the place, and when it is all
  that remains the refresh fails with "no data" and without a cool-down, so
  the place is simply tried again by the next round.
- Independently, MET Norway is asked at most once per 10 minutes per place
  (in memory for the running process, for the 32 most recently requested
  places) and NWS pauses for 5 seconds after an HTTP 429.
- Changes to places and settings are saved 3 seconds after the first change
  and at exit.

## Packaging and signing (maintainer)

`make rpm` builds the source and binary RPM from `packaging/rpm/weather.spec`
(Source0 is the tag archive; `make rpm` instead archives `HEAD`). The spec's
`%check` runs `desktop-file-validate`, `appstream-util validate-relax --nonet`
and the Meson test suite under `xvfb-run`; the RPM is built with Fedora's
`%meson` (`buildtype=plain`, Fedora's flags). The spec `Version` must equal the
`version:` in `meson.build`; `make rpm` refuses a mismatch.

Releases are signed by `tools/sign-release.sh IN_DIR OUT_DIR` with a dedicated
RSA 4096 key kept in its own `GNUPGHOME` (default
`~/.gnupg-weather-signing`; `SIGN_KEY` defaults to the fingerprint above). Given
the unsigned `*.rpm` and `*.tar.gz` files it:

1. signs every RPM with `rpmsign --addsign` and verifies each with `rpm -K`
   against a scratch rpmdb that trusts only that key;
2. writes `SHA256SUMS` and detached signatures for it and the tarball, and
   verifies them;
3. builds the dnf repository tree (`fedora/<N>/<arch>/`, `fedora/<N>/SRPMS/`)
   with `createrepo_c` and signs each `repodata/repomd.xml`
   (`repo_gpgcheck=1` in `weather.repo`);
4. refuses to run if `packaging/rpm/RPM-GPG-KEY-weather` is not the exported
   public key of `SIGN_KEY`.

Publishing: attach `OUT_DIR/release/*` to the GitHub release `v0.1.0` of
https://github.com/wtp128pro/weather and make the content of `OUT_DIR/site/`
the `gh-pages` branch (GitHub Pages, https://wtp128pro.github.io/weather/). Only
the public key is ever published. The key expires on 2029-10-10 and must be
extended or replaced before then; a replacement means a new
`packaging/rpm/RPM-GPG-KEY-weather`, a re-signed repository and a release note.
