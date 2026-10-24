# Weather for macOS

A native macOS port of the GTK4/C weather app in this repository (see the
top-level `README.md`). The Mac app is written in Swift with SwiftUI and has
the same features: you add places by searching for them, and for each place
it shows the current conditions, when rain starts or ends, the cloud cover,
an hourly forecast and a daily forecast, blended from several free sources.
It needs no account or API key, sends no telemetry and never determines your
location by itself.

Licence: GPL-3.0-or-later (see `COPYING` at the top of the repository).
Version 0.1.0, bundle identifier `io.github.wtp128pro.Weather`.

The C code is the reference. Where the port behaves differently, the
difference is listed in this file (sections "Security model" and "Other
documented differences from the C app"). `FEATURES.md` in this directory maps
every feature of the GTK app to its C source, its Swift code and its test.

Read this before relying on the port:

- During the port the app was built and its tests were run, but the app was
  never launched (launching a sandboxed app writes into `~/Library`, which the
  porting run was not allowed to touch). Launching it, and every interactive
  behaviour, is a manual check for the maintainer (see "Run").
- Several differences from the C app were accepted by automated decisions of
  the porting run, not by the maintainer. They are marked "machine-accepted"
  below, and the maintainer is asked to confirm them at sign-off.

## Requirements

- macOS 27 (the deployment target is macOS 27.0).
- Xcode 27.1. The project (`Weather.xcodeproj`) uses project format
  `objectVersion = 90`, the format Xcode 27.1 writes; older Xcode versions
  were not tried. The commands below were run with Xcode 27.1 (build
  27A9275) on macOS 27.0.1.
- No Apple Developer account. The app is signed "to run locally" (an ad-hoc
  signature, `CODE_SIGN_IDENTITY = "-"`, no team), for the Mac that built it.
  It is not notarized and is not meant for distribution.
- Nothing else. The code uses Apple frameworks only (SwiftUI, AppKit,
  Foundation, Network, Observation, OSLog, Compression, Security,
  Synchronization and, for the tests, Swift Testing); there are no packages
  to fetch. It is built in Swift 6 language mode.
- A full checkout of the repository for the tests: some tests compare the
  copied fixtures in `macos/WeatherCoreTests/Fixtures/` with the C fixtures in
  `src/providers/*/fixtures/` and fail if `src/` is missing.

## Build

From the top of the repository:

```sh
xcodebuild -project macos/Weather.xcodeproj -scheme Weather -destination 'platform=macOS' -derivedDataPath build-macos build
```

This builds the Debug configuration of the app and its framework. The app is
`build-macos/Build/Products/Debug/Weather.app`. For the Release
configuration (app in `build-macos/Build/Products/Release/Weather.app`):

```sh
xcodebuild -project macos/Weather.xcodeproj -scheme Weather -destination 'platform=macOS' -configuration Release -derivedDataPath build-macos build
```

About `-derivedDataPath`: without it, `xcodebuild` (and Xcode itself) keeps
build products and indexes in `~/Library/Developer/Xcode/DerivedData/Weather-<hash>/`,
including for `xcodebuild -list` and `-showBuildSettings`. With it, everything
goes to the directory you name. `build-macos/` is already ignored by the
repository's `.gitignore` (the `/build*/` rule) and does not clash with the
Meson build directory `build/` of the C app. Delete it to start from a clean
build. `-derivedDataPath` does not stop every write under `~/Library`:
`xcodebuild` still appends a line to
`~/Library/Logs/CoreSimulator/CoreSimulator.log` on each run, and Foundation
tools keep caches under `~/Library/Caches` unless `CFFIXED_USER_HOME` points
elsewhere.

You can also open `macos/Weather.xcodeproj` in Xcode 27.1, choose the scheme
**Weather** and **My Mac**, and use Product > Build (not tried during the
port). Xcode then uses its default derived-data folder.

Signing needs no setup: the project sets `CODE_SIGN_STYLE = Automatic` with the
ad-hoc identity and no `DEVELOPMENT_TEAM`.

## Test

From the top of the repository:

```sh
xcodebuild -project macos/Weather.xcodeproj -scheme Weather -destination 'platform=macOS' -derivedDataPath build-macos test
```

To run one suite, add `-only-testing:WeatherCoreTests/<Suite>`, for example:

```sh
xcodebuild -project macos/Weather.xcodeproj -scheme Weather -destination 'platform=macOS' -derivedDataPath build-macos test -only-testing:WeatherCoreTests/SmokeTests
```

What the tests are:

- One test bundle, `WeatherCoreTests`, written with Swift Testing. It tests the
  `WeatherCore` framework: core types, blend, scheduler, storage, HTTP client,
  the three providers and the geocoder, registry, service, formatting, the app
  model and the view models. The test cases are ports of the C test suites'
  behavioural assertions, with the C fixtures; ported cases cite their C test
  path (for example `/blend/median/basic`) in their name or in a `// C:`
  comment. Some tests were added by the port (for example the platform rows
  of the HTTP client).
- The bundle is unhosted: it runs in Xcode's test tool, not inside the app,
  and so outside the App Sandbox. A test hosted in the sandboxed app cannot
  open the loopback listener the HTTP tests need.
- No test uses the real network. The HTTP, provider and service tests talk to
  a fake server on 127.0.0.1. The storage and app-model tests are given
  per-test temporary directories as their storage root, never the app's
  container or your real `~/Library` (the bundle is unsandboxed, so this is a
  rule of the tests, not a sandbox guarantee).
- The SwiftUI views and the app shell (the `Weather` target) have no
  automated tests. Their logic lives in the view models, which are tested,
  and the views are compiled with their previews.

Results of the commands above, run on 2026-10-23 (derived data in a scratch
directory instead of `build-macos`, and `CFFIXED_USER_HOME` set to a scratch
directory so that Foundation's per-user caches stay out of `~/Library`):

- `build` on empty derived data: `** BUILD SUCCEEDED **` (about 16 s);
- the one-suite command: 9 tests in 1 suite passed, `** TEST SUCCEEDED **`;
- the full `test` command: "Test run with 1113 tests in 45 suites passed
  after 165.736 seconds", `** TEST SUCCEEDED **`, exit 0 (`HTTPClientTests`:
  80 tests, including `reservedEscapesReachTheWireAsCWritesThem`). A first
  full run in a copy of `macos/` without `src/` beside it failed the two NWS
  fixture comparisons (see "Requirements");
- `build` again after `test`: `** BUILD SUCCEEDED **`, and the app's
  entitlements were back to the three listed under "Sandbox and signing";
- the Release `build` on empty derived data: `** BUILD SUCCEEDED **`, with
  the same three entitlements.

The time differs between machines and with machine load: the suite includes
timing-sensitive tests on the loopback server, and some suites run
serialized.

The tests also have a slow mode (the `WEATHER_SLOW_TESTS` environment
variable, see `WeatherCoreTests/Support/TestSupport.swift`). It is not one of
the documented commands and was not run for this README. Its exhaustive
geocoder sweep does not finish within the suite's 10-minute limit: about
4.45 million loopback requests, about 2.3 hours.

## Run

Not executed while writing this README (see the note at the top). Build
first; if you ran the tests with the same `-derivedDataPath`, build again,
because the test command re-signs the app with testing entitlements (see
"Sandbox and signing"):

```sh
open build-macos/Build/Products/Debug/Weather.app
```

Or, in Xcode, Product > Run (⌘R) with the scheme **Weather** (not tried
during the port).

On first launch macOS creates the app's sandbox container,
`~/Library/Containers/io.github.wtp128pro.Weather/`. The places, the settings
and the forecast cache live there (see "Storage" below). The app opens one
window, "Weather", 1040 × 720 points by default.

Shortcuts: ⌘N opens "Add a City…" (the place search), ⌘R refreshes the
selected place, ⌘U switches between imperial and metric units, ⌘Q quits.
Closing the window (⌘W) also quits, as in the C app. The menus are the
standard macOS ones (see "macOS platform conventions").

Manual checks, because nothing interactive was run in a launched app during
the port:

- launch with no places (the first-run page and its city chips); no first-run
  flash for a returning user;
- ⌘N opens the picker, and a second ⌘N brings it to the front;
- ⌘R is enabled only with a selected, idle place while online;
- ⌘U and the toolbar °F/°C button;
- the sources popover and About;
- the row menu (Move up, Move down, Remove);
- drag reorder (move cursor, blue drop line);
- the sidebar cannot collapse;
- minimise, hide or cover the window: no refresh; bring it back: a round;
- Wi-Fi off: the Offline marker, and Refresh disabled;
- ⌘Q, closing the window and `kill -TERM` all exit promptly with the places
  saved;
- the window frame is restored on relaunch;
- no New Window or tab items in any menu;
- a second activation (Dock icon, `open -a`) presents the same single window;
- toolbar order Add | Refresh, °F/°C, sources, and the four tooltips and
  VoiceOver labels;
- Command-click on the selected row and a click on empty list space never
  leave the list without a highlighted row; arrow keys move the selection; the
  selection survives a relaunch;
- the sidebar cannot be hidden: drag the divider to the left edge; there is no
  View > Hide Sidebar item and no ⌃⌘S; no flicker when it springs back;
- ⌥⌘S (SwiftUI's hidden Toggle Sidebar): the sidebar slides out and comes
  straight back;
- drag the divider to the far right;
- closing the main window while the picker is open closes the picker and
  quits; ⌘W quits;
- Quit from the Dock menu and at logout saves the places;
- ⌘N right after launch opens a working picker, and so does the Window menu's
  picker item during the load;
- VoiceOver: a row is one element with Move up, Move down and Remove actions,
  and the list is labelled "Saved places";
- dropping text from another app onto a row is ignored;
- the window cannot shrink below 820 points wide;
- long names truncate on one line;
- launching offline shows "Offline", not "Stale";
- "Updated N min ago" ticks while the window is visible and stops while it is
  minimised or hidden;
- a refresh round when the window regains focus;
- a refresh round when the network returns;
- `kill -INT` exits promptly with the places saved, like `kill -TERM`;
- the picker's close request (`dismiss()` from the picker's view model)
  closes the real picker window;
- a double-click on a picker row (the list's primary action).

## Project layout

```
macos/
  Weather.xcodeproj/          Xcode 27.1 project (objectVersion 90)
    xcshareddata/xcschemes/Weather.xcscheme
                              the shared scheme: builds Weather, tests WeatherCoreTests
  Weather/                    app target "Weather" (SwiftUI, main-actor by default)
    WeatherApp.swift          @main: one Window scene, the picker window, menu commands
    Shell/                    lifecycle (load, network monitor, signals, bounded quit), window,
                              sidebar, rows, menu commands, window observer
    Detail/                   detail pane and the rain charts (drawn in a SwiftUI Canvas)
    Picker/                   "Add a City…" window (search field and results) and the first-run page
    Sources/                  sources popover and About panel
    AppIcon.icon/             Icon Composer icon made from the C app's SVG
  WeatherCore/                framework target "WeatherCore" (no UI)
    Core/                     value types, geo boxes, text sanitising, time parsing, clock
    Blend/                    weighted-median blend, weights, nowcast, conditions, daily, rain
    Net/                      HTTP client (URLSession), HTTP policy, strict JSON, provider protocol, registry
    Providers/                Open-Meteo (forecast, nowcast, geocoding), NWS, MET Norway
    Service/                  fan-out to the providers, member selection, error ranking
    Sched/                    refresh scheduler
    Storage/                  places, settings and forecast cache files; atomic file I/O
    Format/                   English 12-hour formatting and condition symbols
    App/                      AppModel (composition root, persistence), RefreshEngine, AppEnvironment
    ViewModels/               row, detail, chart, sources, picker and first-run view models
  WeatherCoreTests/           unhosted Swift Testing bundle (Support/ has the loopback server)
    Fixtures/                 copies of the C provider fixtures
  FEATURES.md                 feature traceability table (GTK app -> C source -> Swift -> test)
  README.md                   this file
```

The three folders are synchronized folders of the project: every file added
under `Weather/`, `WeatherCore/` or `WeatherCoreTests/` is compiled into that
target without editing `project.pbxproj`.

The app target imports `WeatherCore`. Everything below the user interface
(blend, providers, storage, refresh policy) is in `WeatherCore`. The blend
takes the current time as an explicit argument, and the timed parts
(scheduler, refresh engine, HTTP deadlines, provider floors) read an injected
clock (`WxClock`), so the tests can drive them with fake time.

## Security model

Described here is only what the code does on macOS. It follows the C app's
security model (top-level `README.md`), with the macOS mechanisms named. The
differences that remain are listed after it, item by item.

### Network

- All traffic goes through one module, `WeatherCore/Net/`
  (`HTTPClient.swift`, `HTTPClientTransfer.swift`, `HTTPPolicy.swift`), on an
  ephemeral `URLSession`. It makes read-only GET requests over HTTPS. Plain
  HTTP is accepted only to 127.0.0.1, ::1 and localhost, which exists for the
  offline tests.
- TLS certificates are verified by the system: the server-trust challenge gets
  `URLSession`'s default handling. A client-certificate challenge is refused
  and every other authentication challenge is cancelled, so no credential is
  ever sent.
- Each provider has one fixed https base URL, a constant in its source file:
  `https://api.open-meteo.com` and `https://geocoding-api.open-meteo.com`
  (`OpenMeteoShared.swift`), `https://api.weather.gov` (`NWSProvider.swift`)
  and `https://api.met.no` (`METNorwayParse.swift`). The client checks the
  scheme, host and port of every request URL against that origin, so the path
  of a request cannot change the host.
- Redirects are never followed: the redirect delegate answers `nil`, so a 3xx
  answer is the final response and is reported as an HTTP error (except 304,
  which is a success when `If-Modified-Since` was sent).
- No cookie, credential, API key or referrer is sent: the session has no
  cookie storage (`httpShouldSetCookies = false`, accept policy `.never`), no
  credential storage and no URL cache (`urlCache = nil`,
  `.reloadIgnoringLocalCacheData`).
- Request headers: `User-Agent: weather-app/0.1 (github.com/wtp128pro/weather)`,
  `Accept`, `Accept-Encoding: gzip`, `If-Modified-Since` when a validator is
  sent (MET Norway only), and `Accept-Language: *` (see DECISIONS #30 below);
  `Host` and `Connection` come from `URLSession`.

### Limits

- A response body is capped at 4 MiB after decoding (`HTTPPolicy.maxBodyBytes`;
  counted as the decoded bytes arrive, and a declared `Content-Length` above
  the cap is refused from the head).
- An attempt times out after 10 s (`HTTPPolicy.timeoutMs`), a whole operation
  after 45 s (`HTTPPolicy.totalDeadlineMs`). The 10 s limit is the client's own
  deadline on an injected clock and covers the head and the body; the
  `URLSession` idle and resource timers are set far beyond it.
- At most 2 retries (`HTTPPolicy.maxRetries`), only after network errors,
  per-attempt time-outs and HTTP 5xx, with a back-off of 1 s doubled per
  attempt. Retries are counted in client attempts; see the "429 and the retry
  count" qualifier below for what this means on the wire.
- At most 16 operations are outstanding per HTTP client
  (`HTTPPolicy.maxInflight`); the next one fails at once with a rate-limit
  error and no traffic. There are four clients (Open-Meteo forecasts,
  Open-Meteo geocoding, NWS, MET Norway), so up to 64 overall. Each session
  opens at most 2 connections per host (`httpMaximumConnectionsPerHost = 2`,
  libsoup's default in the C app).
- HTTP 429 is reported as a rate limit and is not retried, for the 429 heads
  the client sees (see the qualifier below).

### Parsing, privacy and location

- External data is parsed defensively, as in the C code: numbers are
  range-checked, values outside the physical range are discarded, text is
  sanitised before it is shown, and attribution links are shown only if they
  are `https://` URLs of bounded length. These rules are ports of the C code,
  pinned by the ported tests.
- No API keys, no accounts and no telemetry: the only outgoing requests are
  the forecast and place-search requests for the places you add.
- No location detection: places come from your search only. The app does not
  use Core Location and has no location entitlement.

### Storage

- The app runs in the App Sandbox, so its files are in its container. The
  files and formats are the C app's: `places.json` and `settings.json` in
  `~/Library/Containers/io.github.wtp128pro.Weather/Data/Library/Application Support/weather/`
  and `forecasts.json` in
  `~/Library/Containers/io.github.wtp128pro.Weather/Data/Library/Caches/weather/`.
  The app asks `FileManager` for the Application Support and Caches folders
  (`ShellState.storageRoot()`), which inside the sandbox are the container's.
  That mapping was observed with a sandboxed probe app during the port; the
  Weather app itself was not launched. The C app's XDG directories are not
  used.
- Files are written to a new temporary file in the same directory (created
  with mode 0600 by `mkostemp`), flushed with `fcntl(F_FULLFSYNC)` (the macOS
  flush to stable storage; `fsync(2)` only on file systems that do not support
  it) and renamed into place with `rename(2)`. The directories it creates have
  mode 0700. See `WeatherCore/Storage/FileIO.swift`.
- Files are read with size limits (1 MiB for places, 64 KiB for settings,
  8 MiB for the cache) and a JSON nesting limit (32).

### Sandbox and signing

- App Sandbox on (`ENABLE_APP_SANDBOX = YES`) with outgoing network
  connections as the only resource (`ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`;
  no incoming connections, no user-selected file access). The
  entitlements are generated from these build settings; there is no
  `.entitlements` file. An app made by the `build` command above, in Debug
  and in Release (`-configuration Release`), is signed with exactly
  `com.apple.security.app-sandbox`, `com.apple.security.network.client` and
  `com.apple.security.get-task-allow`. Xcode adds `get-task-allow` to the
  Release build too, because the project leaves
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` at its default; whether setting it to
  `NO` removes the entitlement was not tried. The Release build carries no
  temporary exception. `get-task-allow` grants no sandbox capability, but it
  lets a debugger running as the same user attach to the app (DECISIONS #67).
- Caution: the scheme builds the app for testing too, so `xcodebuild test`
  re-signs `Weather.app` in the same derived-data folder with Xcode's testing
  exceptions:
  `com.apple.security.temporary-exception.files.absolute-path.read-only` for
  `/` (read access to the whole disk) and
  `com.apple.security.temporary-exception.mach-lookup.global-name` for
  `com.apple.testmanagerd`, `com.apple.dt.testmanagerd.runner` and
  `com.apple.coresymbolicationd`. Run the `build` command again before you
  run the app (see "Run"); check with
  `codesign -d --entitlements - build-macos/Build/Products/Debug/Weather.app`.
- No App Transport Security exceptions: the Info.plist is generated and has no
  `NSAppTransportSecurity` keys.
- Ad-hoc signature, no team. The hardened runtime is not enabled in the
  project (`ENABLE_HARDENED_RUNTIME` is not set; the signature flags of the
  Debug and the Release app are `0x2(adhoc)`).
- The C app's compiler hardening flags (`meson.build`) have no counterpart in
  the Xcode project; the port contains no C or Objective-C sources.

### Documented differences of the URLSession transport

The maintainer chose `URLSession` as the transport (DECISIONS #10), so
Apple's CFNetwork parses the HTTP responses, not libsoup. Where CFNetwork
decides differently from the C client, the difference is listed here with
its consequence. All of these were machine-accepted at critical gates
(DECISIONS #30, #34, #36, #40, #45, #46, #57, #65, #76 and #78) and await the
maintainer's confirmation at sign-off. Each is pinned by a test where loopback
allows it: a "platform row", or a test labelled `NEW U13-Nn`, in
`WeatherCoreTests/Net/HTTPClientTests.swift` and `HTTPClientWireTests.swift`
(suite `HTTPClientTests`, 80 tests, including
`reservedEscapesReachTheWireAsCWritesThem`). Items that cannot be tested on
loopback say so.

The decisions record that the N-items need a broken or hostile server
response. #34 item 1 also occurs when a connection fails, item 9 when a
server advertises HTTP/3, and D5 on HTTP/2, which api.met.no and
api.weather.gov used in a live probe. Where an item says "no public-API fix
found among" a list, only the listed signals were tried.

The porting run's contract sweep (155 rows: 68 same, 11 fixed now, 52 pinned
difference, 14 not testable, 10 cross-reference) lists the C HTTP contract
rule by rule. It is not a fuzz of the response grammar, so the list below is
not known to be complete.

#### DECISIONS #30: request headers and gzip

- `Accept-Language: *` on every request. `URLSession` would otherwise send
  the user's languages; no public-API way to remove the header was found
  among the request and session header settings. Consequence: one extra
  header, the same on every install, so no locale is disclosed (C sends no
  `Accept-Language`).
- Gzip strictness. When the first `Content-Encoding` element is `gzip` (or
  `x-gzip`), CFNetwork inflates the body itself and checks neither the stream
  end, nor the CRC, nor bytes after the member (C: NETWORK or PARSE).
  Consequence: a correctly framed answer whose gzip stream is cut, corrupt or
  followed by extra bytes is a transport success with whatever the system
  decoder produced, and it reaches the strict JSON parser (a JSON prefix then
  fails PARSE with no retry). In detail:
  - a cut of 20 or more encoded bytes that CFNetwork decodes to nothing is an
    EMPTY success, for both Content-Length and close-delimited framing (C:
    NETWORK after 3 requests); later cuts give a prefix, a flipped byte gives
    a corrupted body, and bytes after the member give the full member;
  - a cut of 1-19 encoded bytes of an HTTP/1.1 Content-Length or
    close-delimited body is NETWORK after 3 requests, as in C;
  - chunked cuts that CFNetwork decodes to nothing are NETWORK after 3
    requests, as in C; a chunked cut that CFNetwork decodes to a prefix is a
    success with that prefix (L6, DECISIONS #57: a member whose DEFLATE data
    decodes from its first bytes, cut at 12-19 bytes, gives 1-8 bytes after 1
    request; C: NETWORK after 3 requests);
  - D5 (DECISIONS #57): the 20-byte rule counts encoded bytes, and on HTTP/2
    `URLSession`'s count adds 9 bytes per DATA frame header, so a gzip body of
    11-19 encoded bytes in one frame passes the rule and becomes an EMPTY or
    prefix success after 1 request (C: NETWORK after 3 requests). The rule is
    exact only for HTTP/1.1 Content-Length or close-delimited bodies. Not
    testable on loopback.

#### DECISIONS #34: CFNetwork behaviour (items 1-7 and 9)

1. In-task re-sends. CFNetwork re-sends a request inside one task, with no
   back-off, when the connection fails before any response byte or the head
   is one it refuses. Each re-send is charged to the C client's budget of 3
   requests, counted from `URLSessionTaskMetrics`. That is observed
   behaviour, not an Apple guarantee. Consequence: there are never more than
   3 client attempts, but a re-send series inside a later attempt gives 4-5
   wire requests per operation on HTTP/1.1 (C: 3), and up to 9 per attempt
   and 11 per operation on HTTP/2 (probe only, not testable on loopback).
   After an attempt that contained a re-send, the next back-off is 2B (B is
   the 1 s back-off base).
2. A chunked body missing only its final chunk is accepted (C: NETWORK after
   3 requests, `src/net/test-http.c:2645-2646`, `:2664-2665`). Consequence: the
   cut body is used, and a JSON body cut at a chunk boundary fails as PARSE
   with no retry.
3. Two `Content-Length` lines with different text: NETWORK after 3 requests
   (C: success, PARSE, or the status's outcome). Consequence: up to 2 more
   requests than C and a network error instead of C's outcome; a 429 there
   starts no pause or cool-down.
4. Chunked framing plus a `Content-Length` whose value does not begin with a
   negative decimal number: NETWORK after 3 requests (C reads the chunked
   body). CFNetwork reads a prefix: `-1x`, `-01` and `-1 ` are carried;
   `5`, `5x`, an empty value, `abc`, `-0`, `-00` and `+5` are refused (as
   restated by DECISIONS #36). Consequence: answers C accepts fail after 3
   requests.
5. `Transfer-Encoding` values `xchunked`, `chunkedd` and `chunked;x` are
   accepted as chunked (C: PARSE), widened by #36 N8 to any comma-free value
   containing `chunked`. Consequence: answers C refuses are read.
6. 204 or 205 with `Transfer-Encoding`, cut after the head: NETWORK after 3
   requests (C: success). Consequence: an answer C accepts fails after 3
   requests.
7. A connection may be reused after a rejected response (C: a new
   connection). Consequence: the next request may go over the connection that
   carried the rejected answer.
9. `URLSession` may move an https origin to HTTP/3 when the server
   advertises it (Alt-Svc); the origin's certificate is still verified. Not
   probed; not testable on loopback. Consequence: the transport protocol can
   differ from the one the tests exercise.

Item 8 of DECISIONS #34 was retired by DECISIONS #36: the outcome and request
count of a withheld head are now those of C, and only its timing differs (N3
below). The related case of a head followed by no body byte at all is N16.

#### 429 and the retry count (qualifier for the security and refresh goals)

- "429 is not retried" holds for the 429 heads the client sees. A 429 head
  that CFNetwork refuses (two differing `Content-Length` lines, #34 item 3) or
  reads as HTTP/0.9 (a status line after 1-2 leading CR/LF, or an
  `ICY`/`200OK`/`HTTP/1.01` form, N1) is reported as NETWORK after 3
  requests, so neither the NWS 5 s pause nor the 60 s cool-down starts.
- A 429 head that CFNetwork withholds (no `Content-Type`, a stalled body, an
  open connection) is reported as RATE_LIMITED only at the 10 s attempt
  time-out, so the pause and the cool-down start up to about 10 s late (N3).
- A 429 head followed by no body byte on a kept-open connection ends as
  TIMEOUT after 3 requests (about 33-35 s), with no pause and no cool-down
  (N16; C: RATE_LIMITED after 1 request).
- A 429 whose head straddles the attempt deadline, or arrives after the
  deadline following an interim 1xx head received in time, is honoured after
  1 request where C times out after 3 (N13 and its extension).
- A withheld 5xx ends as HTTP after 3 requests at about 33-35 s instead of
  about 3 s, and as TIMEOUT "operation deadline exceeded" when 35 s or more of
  the operation are already used.
- The definition-of-done goals for the security model ("at most 2 retries on
  network/time-out/5xx, 429 not retried") and for the refresh policy ("60 s
  rate-limit cool-down", "NWS 5 s pause after 429") are therefore met at the
  client level only, for the heads CFNetwork hands over. That is how the C
  contract counts retries: `WX_HTTP_MAX_RETRIES` counts client attempts, and
  `src/net/wx-http.h:196-197` leaves libsoup's own 421 re-send out of the
  count. They are not met on the wire in every case (see #34 item 1).

#### DECISIONS #36: N1-N10 (with #40 for N9)

- N1 status-line grammar. `ICY 200 OK`, `ICY200 OK`, `HTTP/1.1 200OK`,
  `HTTP/1.01`, `HTTP/01.1`, or 1-2 CR LF / LF before the status line: NETWORK
  after 3 requests, a 429 included (C: success or the status's own outcome).
  `http/1.1`, `Http/1.1`, `HTTP/2.0` or `HTTP/3.0` on HTTP/1.1, a leading
  blank or tab, a NUL in the reason phrase: success (C: NETWORK after 3
  requests). Consequence: answers C accepts are retried and fail, and answers
  C refuses are used. Removable only by hand-parsing the raw bytes CFNetwork
  delivers in its HTTP/0.9 fallback, which DECISIONS #10 rules out; for the
  forms CFNetwork accepts, no public-API fix found among `networkProtocolName`
  and the response fields.
- N2 head size limit. The 100 KiB head limit holds to the byte for CRLF
  heads, with these gaps: (a) a head ended by bare LF lines is accepted at
  102401 line bytes (C refuses it); (b) interim 1xx heads are added to the
  final head's count (C limits each head), so some answers C accepts fail
  with NETWORK after 3 requests; `didReceiveInformationalResponse` was not
  tried; (c) there is no early head-memory bound: the limit is checked only
  after CFNetwork has received and buffered the whole head and any body read
  so far, and CFNetwork accepted a 64 MiB head in a probe (about 152 MB peak
  memory; 356 MB observed as the upper cost), so until the refusal the
  memory a hostile head can take is bounded only by CFNetwork and the 10 s
  attempt time-out (CFNetwork's own head limit was not measured beyond that);
  (d) HTTP/2 heads are not limited by the client (not testable on loopback).
  Consequence: a head C refuses may be used, an answer C accepts may fail,
  and memory and time to the refusal are not bounded early.
- N3 withheld-head timing. CFNetwork withholds every head until at least its
  first body byte, and a head without `Content-Type` longer, until the body is
  sniffed. A withheld head on an open connection is judged at the attempt
  deadline's wake-up instead of at once: the same outcome and request count
  as C, later. Consequence: see the 429 and 5xx timings above. Polling
  `URLSessionTask.response` during an attempt does not expose the withheld
  head.
- N4 server-sent `Transfer-Encoding: Identity` with a gzip body CFNetwork
  inflates: close-delimited and non-empty, success; chunk-framed, NETWORK
  after 3 requests (C: PARSE after 1 request). Consequence: an answer C
  refuses is used or retried.
- N5 header syntax CFNetwork normalises or keeps verbatim (restated by
  DECISIONS #57). A blank or tab before the colon of `Content-Length`,
  `Transfer-Encoding` or `Content-Encoding` is honoured (C ignores the line);
  a bare CR ends a value (C makes it a space); a NUL in a line and a CR CR LF
  blank line give success (C: NETWORK after 3 requests); a `Last-Modified`
  folded with a tab, several blanks or trailing blanks keeps CFNetwork's fold
  whitespace, so it is dropped or `a    b` (C: `a b`). Consequence: a broken
  head is framed, decoded or read differently, and a validator may differ.
- N6 chunk framing. A chunk extension with a value, sizes written `0x3`,
  `+3` or ` 3`, bytes after a chunk's data, a damaged later chunk-size line:
  NETWORK after 3 requests (C reads the body). A chunk-size line longer than
  128 bytes is read (C: NETWORK after 3 requests). Consequence: non-standard
  framing C reads is retried and fails, and one C refuses is read.
- N7 a `101 Switching Protocols` head to a GET: HTTP error after 1 request (C
  skips it like any 1xx). Consequence: the request fails.
- N8 `Transfer-Encoding` values `chunked gzip`, `gzip chunked`, quoted,
  `chunked=1`, `achunkedb`, `chunked identity`, obs-folded: accepted (C:
  PARSE after 1 request). Consequence: answers C refuses are read.
- N9 repeated `Last-Modified` / `Expires` lines (rule (b), DECISIONS #40,
  amending #36). `URLSession` joins repeated header lines with ", ".
  `lastHeaderLine` (`HTTPClientTransfer.swift`) cuts the value at ", " into
  items (a weekday name and the piece after it form one item) and returns the
  last item only when there are two or more items and every item is an HTTP
  date; otherwise it returns the value unchanged. So every single line that
  is not a date list comes back exactly as C reads it
  (`src/providers/metno/test-metno.c:4054`, "sent back as it came").
  Consequences: repeated `Last-Modified` lines that are not all dates give the
  joined value (`a` + `b` gives `a, b`; C accepts NULL, `a` or `b`,
  `src/net/test-http.c:4611-4612`, pinned as a platform row), dropped when
  over 64 bytes or not ASCII; repeated `Expires` lines with a non-date first
  line give 0, so MET Norway uses its 600 s floor instead of `Expires`; a
  single line made only of comma-joined HTTP dates gives its last date (C:
  the whole line). Production impact: none known (the providers' validators
  are single HTTP dates, and only MET Norway sends `If-Modified-Since`).
  Sign-off asks the maintainer to confirm this reversal of #36's first choice.
- N10 transport error messages are a fixed English phrase plus the
  `URLError` code (C embeds libsoup/GIO text). The error codes are the same.
  Consequence: different message text.

#### DECISIONS #45 and #46: N11-N16

- N11 duplicate `Host` response header (two `Host` lines, also in a 1xx
  head): the head is used: 200 success after 1 request, 429 RATE_LIMITED
  after 1, 503 HTTP after 3 (C: NETWORK after 3 requests). Consequence: a
  broken head C retries is accepted, and a 429 there starts a pause C would
  not start. No public-API fix found among `value(forHTTPHeaderField:)`,
  `allHeaderFields` and `countOfResponseHeaderBytesReceived`.
- N12 HTTP/1.0 headers named in `Connection` (`Content-Length`,
  `Content-Encoding`, `Transfer-Encoding`, `Last-Modified`, `Expires`): libsoup
  removes them, CFNetwork keeps and uses them. Consequence: some answers C
  accepts fail with PARSE after 1 request, others give a different body or
  validators. No public-API fix found among `networkProtocolName`,
  `allHeaderFields` and `CFHTTPMessageCopyVersion`.
- N13 (`NEW U13-N13`, DECISIONS #45, #57, #65, #76, #78): a response head
  that straddles the attempt deadline (first byte before the attempt deadline,
  completion after the attempt deadline before the late wake-up) is judged as
  if complete: by its status (a 429 is RATE_LIMITED after 1 request, a 503
  HTTP after 3, a 204 a success, where C gives TIMEOUT after 3 requests) or,
  under L7 (DECISIONS #76, #78), when it fails one of the three head rules in
  `finalOutcome` — `> 100 KiB` head -> `NETWORK` after 3 requests (`NETWORK x3`),
  HTTP/0.9 status-line fallback `headBytes == 0` -> `NETWORK` after 3 requests
  (`NETWORK x3`), or server-sent `Transfer-Encoding: Identity` -> `PARSE`
  after 1 request (`PARSE x1`) — by that head rule as if complete, where C
  gives `TIMEOUT` after 3 requests (`TIMEOUT x3`). Pinned in
  `lateDeliveredHeadsAreDatedByTheirArrival` at
  `HTTPClientWireTests.swift:1729-1744`, mutant `O1` red (`garbled` in-time/late
  at `:1703-1704`). By contrast, under L8 (DECISIONS #76, #78), a head whose
  first byte arrives after the attempt deadline and that fails any of those
  three head rules now returns `TIMEOUT x3` as in C
  (`HTTPClientTransfer.swift:691`, pinned at
  `HTTPClientWireTests.swift:1697-1704, :1722-1728`, mutant `L` red).
  Extension (DECISIONS #57, #76, #78, sweep L3 and L8): the same first-byte
  dating applies when an interim 1xx head arrives in time and the final head
  arrives after the attempt deadline before the wake-up (the final head gets
  whatever verdict it carries, including `RATE_LIMITED x1` for 429, `204`
  success, or the three head rules `PARSE x1` / `NETWORK x3`, where C gives
  `TIMEOUT x3`; pinned at `HTTPClientWireTests.swift:1769-1778`, mutant `O1`
  red). Consequence: request counts are 1 (for 429, 204, or server-sent
  `Transfer-Encoding: Identity`) or 3 (for 503, `> 100 KiB` head, or HTTP/0.9
  fallback `headBytes == 0`) vs C's 3 requests (`TIMEOUT x3`); a 429 is
  honoured where C times out, a 204 succeeds, `Identity` fails `PARSE x1`, and
  `> 100 KiB` or HTTP/0.9 fallback heads fail `NETWORK x3` instead of
  `TIMEOUT x3` (no 429 path weakened). No public-API fix found among the
  transaction dates (fetchStart through responseEnd), the byte counts,
  task.response, countOfBytesReceived, and didReceive(response:) (only a
  body-dependent upper bound; probe-p7/p1.log, p3.log) for the time the head
  was complete, and, for the extension, among `responseStartDate`,
  `responseEndDate` and `didReceiveInformationalResponse`; the final
  `didReceive(response:)` time was not tried; it would only give an upper
  bound (DECISIONS #65 corrects #57 on this point).
- N14 401/407/421 decided from the head (narrowed by #45 and #57): a 401/407
  whose authentication scheme CFNetwork handles, or a 401/407/421 with a
  `Content-Encoding` that CFNetwork hands over at once, with a stalled body or
  one cut on a kept-alive connection, fails fast: HTTP after 1 request (C
  reads the body first: TIMEOUT or NETWORK after 3 requests). An HTTP/1.0
  401/407/421 cut short without a `Connection` header gives NETWORK after 3
  requests (C: HTTP after 1). Consequence: fewer requests than C in most
  cases, more in the HTTP/1.0 one; no credential is ever sent. No public-API
  fix found among the four challenge dispositions (DECISIONS #46).
- N15 a chunked body labelled gzip, of 20 or more payload bytes, that
  CFNetwork decodes to nothing: NETWORK after 3 requests (C: success with an
  empty body for a valid empty member; PARSE after 1 request with bytes after
  the member). Consequence: an answer C accepts fails after 3 requests. No
  public-API fix found among `countOfResponseBodyBytesReceived` and
  `countOfResponseBodyBytesAfterDecoding`.
- N16 a head followed by no body byte on a kept-open connection: never handed
  over, so it ends as the attempt deadline's TIMEOUT after 3 requests, about
  33-35 s (C: the status's outcome at once). Consequences: a 429 there gets no
  NWS pause and no 60 s cool-down; a 205 without a body byte or a 204 with
  `Transfer-Encoding: chunked` fails where C succeeds; a 503 is TIMEOUT after 3
  (C: HTTP after 3). A head whose body is complete when it arrives
  (`Content-Length: 0`, or a small body) is handed over at once, with C's
  outcome (DECISIONS #46 tripwire). No public-API fix found among
  `transactionMetrics.last.response`, `task.response`, the delegate callbacks
  and the byte counts.

#### DECISIONS #57: fix-pass residuals

The N13 extension, L6, D5 and the N5 widening are described above. Also:

- N17 a 401 without an authentication challenge CFNetwork handles and
  without a `Content-Encoding`, whose chunked body is cut inside a chunk:
  HTTP "HTTP 401 Unauthorized" after 1 request (C: NETWORK after 3 requests);
  407 and 421 bodies give C's outcome. Consequence: fewer requests and a
  different error code for such a broken 401. No public-API fix found among
  the task's error, `countOfResponseBodyBytesReceived` and
  `countOfResponseBodyBytesAfterDecoding`.

#### Host names with non-ASCII characters (DECISIONS #68 D-O2)

A non-ASCII host goes through a port of GLib's `g_hostname_to_ascii`
(`HTTPPolicy.swift`), but NFKC normalisation uses Foundation's
(`precomposedStringWithCompatibilityMapping`). On macOS 27.0.1 that differs
from GLib for rare inputs: Tibetan vowel-sign order, uncomposed Hangul jamo,
and a supplementary-plane character followed by a combining mark (498 of
150,000 exotic multi-character hosts and 3 of 193,056 single-scalar hosts in
the measurement; for example a private-use U+F0041 + U+0301 host is accepted
where GLib rejects it). Consequence for the shipped app: none. The four
provider base URLs are ASCII constants, and NFKC never yields ASCII, so the
HTTPS-only and loopback checks cannot be bypassed. The comment in
`HTTPPolicy.swift` attributes the gap to Unicode-version table differences; the
measured cause is Foundation's NFKC.

## Refresh policy

The policy is a port of the C app's, with the C constants named below,
driven by macOS signals. The "429 and the retry count" qualifier above
applies to the cool-down and the NWS pause: they start only for the 429
heads CFNetwork hands over.

- A refresh happens only while the window is visible and the network is
  available. "Visible" means the window's occlusion state includes visible,
  it is not minimised and the app is not hidden (`NSWindow` and
  `NSApplication` notifications, `Shell/ShellWindowObserver.swift`). "Focused"
  means the app is active and the window is its key window. The network
  state comes from `NWPathMonitor` (path status satisfied).
- Rounds (every place) run when the window becomes visible, when it regains
  focus, when the network returns and every 10 minutes while those conditions
  hold (`RefreshScheduler`, period 600 s); a newly added place is fetched at
  once. Hiding the window or losing the network cancels the requests in
  flight.
- A place with a successful fetch younger than 2 minutes is skipped by an
  event round, one younger than 9 minutes by a periodic round. At most 3
  refreshes (places being fetched) are in flight. Each refresh asks every
  enabled source that covers the place, and a source makes one or two HTTP
  requests (Open-Meteo two inside the contiguous-US boxes, MET Norway one,
  NWS a place lookup that is remembered and the grid forecast).
- A failed fetch keeps the cached data on screen, marks the place stale, and
  is retried by the next round; nothing retries it by itself.
- A manual refresh (⌘R) of a place is not started earlier than 10 seconds
  after its latest request started or succeeded
  (`RefreshEngine.refreshMinGapS`), and not earlier than 60 seconds after a
  refresh failed with a rate limit (`RefreshEngine.rateLimitCooldownS`).
  During that cool-down nothing asks the place again (the scheduler's rounds
  skip it too); when it has ended, the place is fetched once more at once.
- Only a rate limit of a server (HTTP 429, or a pause a provider keeps after
  one) starts that cool-down. A provider's own refusal to send a request
  (MET Norway's once-per-10-minutes-per-place floor, or a provider's cap on
  requests in flight) is no failure of a server: it never outranks another
  source's real error, and when it is all that remains the refresh fails
  with "no data" and without a cool-down.
- Independently, MET Norway is asked at most once per 10 minutes per place
  (`METNorwayParse.minRefreshS` = 600), in memory for the running process and
  for the 32 most recently requested places (`METNorwayParse.cacheMax`), and
  NWS pauses for 5 seconds after an HTTP 429 (`NWSProvider.rateLimitSeconds`).
- Changes to places and settings are saved 3 seconds after the first change
  (`AppModel.saveDelayMs`) and at quit. Quitting (⌘Q, closing the window,
  SIGTERM or SIGINT) saves and waits up to 5 s for the work in flight
  (`AppModel.shutdownWaitMs`; with the real clock the wait can overshoot by
  about 6.5%, DECISIONS #60 item 3). A quit during the start-up load is
  bounded by the same 5 s: if the load has not finished by then, the app
  gives up with C's log line "Gave up waiting for pending saves/requests
  after 5000 ms", and the flush that follows gets only the time left
  (DECISIONS #72; see "macOS platform conventions" for what such a quit
  saves).

## Other documented differences from the C app

These are accepted differences outside the transport, each with its
consequence. The list is the porting run's record (DECISIONS #41, #43, #49,
#50, #58, #59, #60 and #68, and the shell conventions of the app shell unit).

### Numbers

Numeric parity of the blend and the formatting was measured against the
unmodified C code built with `clang -O1 -ffp-contract=off`, over generated
inputs. On those inputs the Swift port is
byte-identical to the C built without FMA contraction.
A C build that fuses multiply-adds (clang's default
`-ffp-contract=on`, or gcc on FMA targets) differs only in
`wx_forecast_now`'s six interpolated "now" fields: about 95% of the differing
values by 1-6 ulps, a tail up to about 3,072 ulps near cancellation (relative
error at most 6.4e-13), and one 5e-324 against 0.0. Hours, quarters, days and
errors never differ. Consequence: compared with such a C build, the six
interpolated current-condition values can differ in their last bits; the
port reproduces the unfused C, not every C build.

### Time zones (DECISIONS #41)

- Case variants of zone names, such as `asia/tokyo`, give UTC, as
  `src/blend/test-blend.c:4907` asserts (the unmodified C on case-insensitive
  APFS opens Tokyo; on case-sensitive Linux it gives UTC too). Consequence:
  none for the providers, which send correctly cased names.
- 15 legacy names that only ICU still knows (the 13 `SystemV/*` names,
  `US/Pacific-New`, `Canada/East-Saskatchewan`) resolve to a real zone where
  C gives UTC. Consequence: none known; the providers and the geocoder never
  send these IDs.
- The port ignores `TZDIR` (C honours it). Consequence: the zone data is the
  system's.

### Providers

- Open-Meteo slot lifetime (DECISIONS #43). A Swift fetch returns only after
  its second request's cancellation has finished, so its slots are free when
  it returns: 16 fetches started right after one returns all succeed, where C
  (`wx-openmeteo.h:133-147`, `test-openmeteo.c:2975-2981`) gives 15 results and
  1 RATE_LIMITED. Consequence: the port never refuses a fetch C accepts here;
  the total of 16 per provider and the 2-slot rule for the contiguous US
  still hold.
- MET Norway cancel during parse (DECISIONS #49). If the last waiter cancels
  while the answer is being parsed, the answer is still stored in the cache
  (C: "a cancelled one included changes no entry", `wx-metno.h:56-58`).
  Consequence: a just-fetched answer is cached instead of discarded; it never
  shows stale or wrong data, never sends an extra request and never blocks a
  later fetch beyond C's own 10-minute floor.

### Service orchestration (DECISIONS #50)

- A cancel after completion but before return, on the path where no provider
  covers the place, returns without C's callback delay (C reports
  CANCELLED). Consequence: the app model re-checks its request token after
  every resume, so the app does not see it.
- Providers run concurrently after a start in registration order.
  Consequence: none for the result; each provider owns its state.
- The internal test hooks `testDeadlineMs` and `completionProbe` are compiled
  into the production `WeatherCore` (internal, reachable only from
  `@testable` tests, never set by the app), contrary to
  `wx-service-testing.h:7-11` ("no hook in production"). Consequence: dead
  code in the shipped framework.
- The 30 s service deadline starts before the providers' `covers()` checks run
  (C starts it after). Consequence: visible only with a slow `covers()`,
  which the provider protocol forbids.

### App model (DECISIONS #60, amended by #71)

1. After removing the selected place, the neighbour selected follows an
   assumed GTK index rule (the row now at that position, else the last); C's
   tests require only a selected place other than the removed one.
   Consequence: visible; if the assumed rule is not GTK's, the selection lands
   on a different neighbour than in the GTK app.
2. `/window/app/selection-dropped-when-place-removed` is not reproduced: the
   single window always selects a place. Consequence: visible; while there are
   places, one is always selected.
3. The quit wait `flush(timeout:)` is clamped to 0-5000 ms on the injected
   clock; with the real clock the wait can overshoot by about 6.5%.
   Consequence: a quit with work in flight can take slightly over 5 s.
4. A window visible before the load finishes (impossible in C) could fetch the
   restored selection second. Consequence: none in the app, which reports
   visibility only after the model is loaded.
5. There is no disposed-but-alive application state. Consequence: none.
6. A non-UTF-8 drop payload cannot reach a Swift `String` as raw bytes.
   Consequence: a dropped payload that is not valid UTF-8 is not handled byte
   for byte as in C.
7. Two log texts on unreachable paths replace GLib criticals. Consequence:
   none in normal use.
8. Places are republished as a new array instead of a `GListStore` splice.
   Consequence: none visible.
9. Internal `@testable`-only seams (`testSaveHook`, `testRefresh`,
   `testSearch`, `testLoadWorkerFirst` with a `DispatchSemaphore` that is dead
   in production, `testLoadAfterWorkerResume`, read only when
   `testLoadWorkerFirst` is true and so dead in production as well, and
   read-only counters) are compiled into the production `WeatherCore`,
   contrary to `test-window.c:76` ("The production code has no hook for it").
   Consequence: dead code in the shipped framework.
10. Exact main-queue deferral of the load's completion was not adopted: the
    model defers it with `Task.yield`, which hops to the generic executor. A
    flush sent from another thread during that hop races, exactly as C's quit
    source races its GTask callback. Consequence: the ordering is as racy as
    C's in that window, not stricter. In the app, the quit path waits for the
    load before it flushes.

### Picker and first run (DECISIONS #58)

- Replacing the whole search text programmatically fires one change where
  GTK fires two (empty, then the text; `test-picker.c:228-229`), so GTK
  shows the suggestions in between and the port keeps the old rows.
  Consequence: none in the app, which never replaces the text this way.
- The rules "Caps Lock does not block Escape" and "Return or Space adds only
  without modifiers" are recollections of GTK behaviour that C does not pin
  (C pins: plain Escape closes, Control+Escape does not). Consequence: these
  key combinations may differ from the GTK app.
- Text comparisons use Swift string equality, which treats NFC and NFD forms
  as equal: replacing NFC text with its NFD form neither keeps the typed
  bytes nor restarts the search, where C keeps exactly what was typed and
  searches again (`wx-picker.h:38`). Consequence: replacing the text with a
  canonically equivalent form changes nothing in the picker. A byte
  comparison would fix it (offered at sign-off).

### macOS platform conventions (DECISIONS #13, #59, #62, #70, #72 and #73)

The maintainer chose to adopt Mac defaults (register #16). Each item below
differs from the GTK app, with its consequence:

- The standard macOS About panel. GTK's About-dialog chrome (a "Website" link
  label instead of the URL, and the licence preamble "This program comes with
  absolutely no warranty…") is GTK text, not an app string, so it is not
  shown; the app's About strings are shown verbatim (version `0.1.0` first in
  the credits, the copyright with ©). AppKit keeps an empty version row and an
  empty copyright row and has no option to hide them. Consequence: the About
  window looks like other Mac apps' and lacks GTK's chrome.
- Switches, links and the About button are Tab stops only when macOS keyboard
  navigation is on (System Settings), where GTK always focuses them.
  Consequence: with the default setting, Tab skips them.
- Tooltips name the Mac shortcuts ("Add a city (⌘N)", "Refresh this place
  (⌘R)") instead of Ctrl+N and F5. Consequence: different text.
- F5 is not bound (DECISIONS #13). Consequence: use ⌘R.
- About is also in the app menu (the C app reaches it only from the sources
  popover and has no "about" action, `test-window.c:2997-3050`). Consequence:
  one more way to open it.
- Standard macOS menus (app, Edit, View, Window), with Refresh and the unit
  switch in the View menu; ⌘Q quits. Consequence: menu items the GTK app does
  not have.
- SwiftUI's hidden "Toggle Sidebar" command (⌥⌘S, no visible menu item) still
  fires (DECISIONS #72). Consequence: the sidebar slides out and comes straight
  back; it cannot stay hidden.
- The window frame is restored on relaunch (the C app persists no size).
  Consequence: the window should reopen where you left it (a manual check).
- While the stored places load, the window shows a blank, neutral page, never
  the first-run page (DECISIONS #62; the C app builds the window only after
  the load). Consequence: a short blank window at start.
- A quit during the start-up load saves the place the app selected
  automatically, the first one (DECISIONS #72; C writes nothing then,
  `wx-app.c:1815-1816`, `:2044-2045`), and a flush that also runs out of time
  logs the time that was left (for example "after 3000 ms") where C always
  says 5000 ms. Consequence: not visible to the user, since the next launch
  selects the same place.
- In the "Add a City…" search field, when the picker cuts an entry at its
  limit (64 characters or 64 bytes), the field's undo history is dropped: the
  edit that hit the limit, and the typing before it, cannot be undone; edits
  after the cut can (DECISIONS #70, #73; GTK keeps its history). About 0.3 s
  after a cut, when the search redraws, a dead Undo step appears.
  Consequence: Undo does less than in GTK after a cut, and that one Undo step
  does nothing (no error; the field keeps the picker's text).
- VoiceOver reads "Added" on a saved place in the picker's results, as GTK
  does (`wx-picker.c:364`, `:475`); this one is not a difference.
- Styling (DECISIONS #73): "Added" in the picker's results is at body size
  (GTK: 0.85em at opacity 0.6); the sources popover has a divider above the
  honesty note; the first-run page's "Add a city" button uses the large
  control size. Consequence: small visual differences from the GTK app.
- Unit-verified ledger items (DECISIONS #68): `WxPlace` String initialiser
  accepts repaired U+FFFD text (D-O1); IDN 3 of 193,056 single-scalar hosts
  differ from GLib, unreachable with ASCII base URLs (D-O2, above);
  out-of-range timing arguments throw `INVALID_ARG` (D-O3); the strict store
  reader refuses hand-edited JSON `json-glib` may accept (D-O4); foreign error
  message is `localizedDescription` and an escaping `URLError(.cancelled)` maps
  to `NETWORK` (D-O5); async save throws `PENDING`, completes on the caller's
  actor, and checks cancellation at job start (D-O6); `HTTPClient.get` throws
  its outstanding-cap refusal (`RATE_LIMITED`) before checking the caller's
  cancellation where C checks `CANCELLED` first — NWS re-checks (pinned by
  `cancelledCapRefusalStartsNoPause`), while for MET Norway (whose
  `RATE_LIMITED` branch sets `throttleUntilS`) and the service the consequence
  of a fetch cancelled while at the cap is unverified (D-O7); zone LRU,
  negative ring and loader/clock hooks not ported (D-O8); whole-page change
  granularity (D-O9); `Link.url` via `URL(string:)` and recalled GTK About
  strings (D-O10); `AppModel.add` schedules the save (D-O11); `fsync(2)`
  fallback after `fcntl(F_FULLFSYNC)` (D-O12); 2-h chart keeps 4 of 5 labels
  at 336 pt by C's overlap rule, all 5 from 358 pt (D-V1); partial-sources
  line uses a system orange mixed toward the label colour (5.85:1 light,
  9.18:1 dark) instead of `#9a6700`, and GTK `width-chars` is approximated
  from the system font, Increase Contrast not probed (D-V2); Linux build and
  distribution tooling not ported (D-P11).

## Data sources, licences and attribution (read this)

From the opening sentences to the "not affiliated" line, this section is
copied verbatim from the C app's `README.md`. In the port the texts live in
the provider files in `WeatherCore/Providers/` and in
`WeatherCore/ViewModels/SourcesViewModel.swift` (C: `src/providers/*`,
`src/ui/wx-sources.c:42-46`). The C constant names in the table correspond to
`METNorwayParse.minRefreshS` and `METNorwayParse.cacheMax` in the port.

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

Copied verbatim from the C app's `README.md` (the weights are ported to
`WeatherCore/Blend/Weights.swift`):

"Highly accurate" is the design goal of this app, not a measured result. The
blend weights (per variable and per source and model; in the US region also
per horizon band of 0-3 h, 3-18 h, 18-72 h and from 72 h, elsewhere flat over
the horizon) are documented heuristics, rules of thumb
written down in `src/blend/wx-weights.c`. They are not statistics and were
not fitted to forecast-verification data. No accuracy measurement of this app
or of the blend was performed, so no accuracy figure is claimed; the app says
so in the sources popover too. Treat the forecast as you would any single
free forecast.

The sources popover shows the C app's note verbatim: "Forecasts blend several
sources with fixed, documented weights. These weights are rules of thumb, not
statistics measured from past accuracy, so no accuracy figure is claimed."

## Licence

GPL-3.0-or-later, the licence of the whole repository (see `COPYING`). Every
Swift source file carries `SPDX-License-Identifier: GPL-3.0-or-later`.
Copyright (C) 2026 wtp128pro.

## See also

- `FEATURES.md` (this directory): the feature traceability table, with every
  documented difference.
- `../README.md`: the GTK/C app, its build, packaging and signing.
