# Audit evidence harnesses

These are the harnesses that produced the evidence for some of the fixes of
the October 2026 units-and-alerts audit, packaged so that they can be re-run
on the current tree. Finding IDs (`U19-F1`, …) are the audit's; its fix
ledger cites these harnesses as the evidence for each fix listed below.

They exist because two kinds of code have no test runner:

- **The Weather app target.** `WeatherCoreTests` links only
  `WeatherCore.framework`; the app target (`Weather/`) has no test bundle, so
  fixes in `Weather/Detail`, `Weather/Shell`, `Weather/Settings` and
  `Weather/Picker` cannot be pinned by an XCTest/Swift Testing test.
  [`u42/`](#u42-detail-page-and-live-station-fixes) compiles the app sources
  themselves into two probe executables;
  [`u43/`](#u43-shell-settings-and-picker-fixes) compiles verbatim extracts of
  the fixed code into five small harnesses.
- **The repository's own scripts.** [`u44/`](#u44-tests-of-the-scripts)
  holds regression tests for `scripts/github_math.py`, `scripts/help/` and
  `scripts/build_dmg.sh`.

Fixes in `WeatherCore` are pinned by `WeatherCoreTests` instead (for the
audit, `WeatherCoreTests/AuditFixes/`).

Requirements: Xcode (`xcodebuild`, `swiftc`, `nm`) for `u42` and `u43`;
Python 3 (standard library) for all three. No network: every HTTP request of
`u42` is answered in-process, `u43` shadows the address geocoder with a
scripted one, and `u44` runs offline.

## Common behaviour

- **Repository.** Each script finds the repository from its own location
  (`REPO` defaults to the `macos/` directory three levels up); set `REPO=…`
  to point it at another checkout. They can be run from any directory.
- **Scratch.** Everything a harness writes (the Xcode build, scratch copies of
  the sources, extracts, binaries, outputs, and the probes' `TMPDIR`) goes
  into one `mktemp -d` directory under `$TMPDIR`, removed on exit. Nothing is
  written into the working tree; `git status` is unchanged after a run.
- **Build.** `u42` and `u43` first build the `Weather` scheme (Debug,
  `CODE_SIGNING_ALLOWED=NO`) with `xcodebuild -derivedDataPath` in the scratch
  directory, for `WeatherCore.framework` (and, for `u42`, the app target's
  generated asset symbols). The app is compiled, never launched. Set
  `DD=<dir>` to build into (and keep) a derived-data directory of your own
  instead: later runs then build incrementally and start in seconds. The
  scripts never delete a `DD` you pass.

## Keychain safety rule

The app keeps the station networks' personal API keys in the user's login
Keychain (`Weather/Detail/StationKeys.swift`, service
`io.github.wtp128pro.Weather.station-keys`). No harness may be able to reach
it, so every harness that builds or runs app code keeps these guards; keep
them when you change one:

1. **In-memory stub.** No harness compiles the real `StationKeys.swift`.
   `u42/scratch_build.sh` replaces it in the scratch copy with
   `u42/stub/StationKeys.swift` (keys in a dictionary, nothing saved); the
   `u43` stations harness compiles `drivers/stubs_stations.swift`'s
   `StationKeys` (only `normalized`), and its Settings harness replaces the
   tabs with stubs.
2. **Source gate.** A harness refuses to compile when any of its sources
   contains `import Security` or `SecItem`.
3. **Binary gate.** Before running any binary, the harness runs
   `nm -u <binary> | grep -c SecItem` and refuses to run it unless that prints
   `0`. The same check is applied to the `WeatherCore.framework` it links.
   Each check is printed (`gate: nm -u … -> 0`, `== …: nm -u bin | grep -c SecItem -> 0`).
4. Never launch the real app, never run a binary that links the app's debug
   dylib or the real `StationKeys`, and never use the `security` command-line
   tool from a harness.

## u42: Detail page and live-station fixes

```sh
cd macos
bash scripts/audit-harnesses/u42/run_all.sh                       # the tree as it is
DD="$TMPDIR/wx-dd" bash scripts/audit-harnesses/u42/run_all.sh    # keep the Xcode build for next time
```

`run_all.sh` builds two probes, each one module compiled by
`scratch_build.sh` from a scratch copy of `Weather/` (without
`WeatherApp.swift`, with the `StationKeys` stub) plus a probe main:

- **liveprobe** (`liveprobe.swift`): drives `LiveStationFetcher`,
  `LiveStationStore`, `StationNetworkFetcher` and `StationHTTP`, with a
  `URLProtocol` stub answering every request (Open-Meteo, CAMS, AirNow,
  Bright Sky, MeteoSwiss, NWS, `cache.test`). Scenario S6 writes a station
  catalog into the probe's `TMPDIR` (inside the scratch directory).
- **uiprobe** (`uiprobe_main.swift` + the code `gen_ui.py` copies verbatim out
  of `DetailView.swift` and `DetailRainChart.swift`): renders day bars, the
  rain chart and the hover text off screen with `ImageRenderer` and measures
  the pixels. `U42_DUMP=<dir>` also writes `dump-chart.png` and
  `dump-days.png` there.

**Time:** about 1 minute with a fresh build (54 s on 2026-10-27; most of it
the Xcode build and two whole-app `swiftc` compiles; a cold machine takes
longer); about 40 seconds with a warm `DD`. With `--old` the two compiles
and runs are done twice.

**Success:** exit 0 and the last line `u42: all probes ran`; then the printed
lines read as below. The probe does not judge itself: compare the lines.
Times of day in the AQ text and the minute counts depend on the clock; the
onset minutes must equal the "true onset" printed beside them.

| Fix | Line (probe) | Fixed tree prints |
|---|---|---|
| U19-F1 metric day bars coloured as °F when there is no current hour | `U19-F1 metric, no current: …` (uiprobe) | `isMetric=true; day 1 low/high 12/24 -> cool teal / warm amber-gold`, and fill pixels in cool teal / mild green-gold / warm amber-gold only |
| U19-F2 a low == high bar drawn past the end of the track | `U19-F2 bar 14..14 within -2..14 …` (uiprobe) | `fill px inside=6 outside=0 x=124..129` (also for `29..29`) |
| U20-F1 nowcast 4× too high and one slot late; late "Rain starting" | `S1 F1 …`, `S1b F1 …`, `S12 F1-edge …` (liveprobe) | `forecast_minutely_15 asked = 9`; nowcast bars equal the printed truth `1.00 0.00 0.00 0.40 0.00 0.00 0.80 1.20`; live headline minutes = true onset; S12 `Rain starting in 1 minute \| nowcast slot 0 mm/h = 1.00` |
| U20-F2 Open-Meteo held the snapshot, refetched, had no User-Agent; cancelled owner stored an empty snapshot | `S2 F2 …`, `S11 U20-F2 …`, `S14 U20-F2 …` (liveprobe) | `User-Agent = weather-app/0.1 (github.com/wtp128pro/weather) \| timeoutInterval = 10.0`; `radarQuarters = 9 \| precipMmH = 0.00`; `refetched: false`; S11 `= 1`; S14 `true \| GETs = 2` |
| U20-F3 an AirNow card in the old units survived a units change | `S3 F3 round 2 …` | `AQ source = nil` |
| U20-F5 a units change during a fetch was dropped | `S4 F5 …`, `S13 F5-cancelled owner …` | `6.2 mi away` (not `10.0 km`); S13 also `radarQuarters = 9` |
| U20-F7 Forget All Stations lost on quit | `S6 F7 …` | `before quit = false \| right after willTerminate = true` |
| U20-F8 an hours-old snapshot kept overriding the page | `S5 F8 round 2 …` | `snapshot still shown: false` |
| U20-F12 a 15-minute sum read as a rate | `S1 F12 …` | `snapshot.precipMmH = 2.00 (true rate 2.00 mm/h)` |
| U21-F1 per-station outages reported as "ok, 0 reports" | `S7 U21-F1 …`, `S9 …`, `S10 …` | `dwdSYNOP status = unreachable`; S9 and S10 `observations = nil` |
| U21-F2 the 401st entry emptied the station HTTP cache | `S8 U21-F2 …` | `day/0 = 1 \| of the new entry = 1` |
| U21-F4 hover showed "0 mm/h" for an unknown slot | `U21-F4 …` (uiprobe) | `["0 mm/h", "2.0 mm/h", "—", "—"]` |
| U21-F5 solid baseline drawn at the top, real zero line dashed | `U21-F5 …` (uiprobe) | the long grey run is on the floor row: `y=152 grey=260 longestRun=90`, and `y=3 … longestRun=3` |

**Comparing with the pre-fix code.** `--old DIR` also builds both probes with
`DIR/*.swift` in place of `Weather/Detail/*.swift` (the `StationKeys` stub
still replaces `StationKeys.swift`) and prints `diff old new` for each probe.
The files must compile against the current `WeatherCore`. The Detail files of
`de60693` (0.3.0, before the audit) do:

```sh
cd macos
d=$(mktemp -d)
for f in DetailPreviewData DetailRainChart DetailView LiveStationFetcher StationNetworkFetcher WeatherTheme; do
  git show "de60693:macos/Weather/Detail/$f.swift" > "$d/$f.swift"
done
bash scripts/audit-harnesses/u42/run_all.sh --old "$d"; rm -rf "$d"
```

Every row of the table above then shows its pre-fix value on the `<` side
(e.g. `isMetric=false … icy cyan / cold azure`, `fill px inside=0 outside=6`,
`snapshot.precipMmH = 0.50`, `dwdSYNOP status = ok(reports: 0)`).

## u43: Shell, Settings and Picker fixes

```sh
cd macos
bash scripts/audit-harnesses/u43/run.sh          # the five harnesses on the tree
bash scripts/audit-harnesses/u43/run.sh all      # and the 12 non-vacuity mutants
bash scripts/audit-harnesses/u43/run.sh f3-count # one mutant
```

`extract.py` cuts the fixed code out of `Weather/Shell/ShellRow.swift`,
`Weather/Settings/SettingsView.swift`,
`Weather/Settings/StationsSettingsTab.swift`, `Weather/Picker/PickerView.swift`
(and `AppModel.localCorrections`' hour rows) **verbatim**, by marker and
bracket matching with a small Swift lexer, and wraps each cut in a host type
whose stored properties stand in for the view's `@State`. It fails loudly
when a marker is missing or ambiguous. When a view gains state that the cut
code uses, the host needs a stand-in for it (the hosts already carry
`units`, `focus`, `unitsFollowPointer` and a no-op `syncUnitsHighlight()`,
added after the audit for the units feature). The drivers in `drivers/` run
the cuts on pinned cases and print `PIN ok` / `PIN FAIL` lines.

| Harness | Fixes | What it pins | Success line |
|---|---|---|---|
| `badge` | U22-F2 | `ShellRow.symbolForPlace` on 58 places: names that merely contain a keyword (Munich, Tunis, Homestead, Workington, …) get no home/work/family/school badge; real ones keep it | `badge: cases=58 mismatches=0` |
| `settings` | U23-F1 | Bringing an open Settings window forward keeps its views and an unsaved key draft; another tab switches; a closed window starts fresh; a minimised one keeps its draft (5 pins; the window is never ordered in, `NSApp` is faked) | `settings: failures=0` |
| `stations` | U23-F3, U23-F5, U23-F6 | The Keychain-error line only after a rejected save; the caption `by up to ±4.0 °C` / `±7.2 °F`; a per-minute sweep of 8 days (DST changes in New York, London, Lord Howe; Kolkata) has exactly one "now" bar, never a skipped hour's | `stations: failures=0` |
| `picker` | U24-F2, U24-F3, U24-F5 | The search state machine against a scripted geocoder (500 ms): no stale candidate added after a paste or refinement; the cursor resets on a new row set; Return does not restart an identical round (cases F5a–h) | `picker: failures=0` |
| `undo` | U24-F1 | Undo in the search field (real AppKit field editor, in a borderless window at −20000,−20000 that is never ordered in) reaches the binding | `PIN ok   U24-F1 Undo's text reaches the binding (draft == field)` |

Mutants (`mutants` or `all`): each applies one named breaking edit from
`extract.py`'s `MUTANTS` to the extracted fixed code (`badge-substring`,
`settings-rebuild`, `f3-cancel`, `f5-signed`, `f6-ts0`, `f6-hour-from-tS`,
`f1-guard`, `f2-guard`, `f3-count`, `f5-inflight`, `f5-answered`,
`f5-nodedupe`); its harness must then fail, which shows the pins are not
vacuous.

`old` runs the harnesses on pre-fix copies of the four files, from
`OLD_SRC=<dir>` holding them at their `Weather/…` paths (report only; every
harness fails there):

```sh
cd macos
d=$(mktemp -d)
for f in Shell/ShellRow Settings/SettingsView Settings/StationsSettingsTab Picker/PickerView; do
  mkdir -p "$d/Weather/$(dirname "$f")"; git show "de60693:macos/Weather/$f.swift" > "$d/Weather/$f.swift"
done
OLD_SRC="$d" bash scripts/audit-harnesses/u43/run.sh old; rm -rf "$d"
```

**Time:** about 1 minute for the five harnesses with a fresh build (most of
it the Xcode build); about 3½ minutes for `all` (202 s on 2026-10-27). The
picker harness alone waits about 20 s on its scripted geocoder, and runs once
more for each of its 5 mutants.

**Success:** exit 0 and the last line
`u43: new harnesses passed 5/5; mutants caught 12/12; PASS` (with `all`).
Exit 1 if a harness fails, a mutant is not caught, or anything is refused or
does not compile; exit 2 for a build or usage error.

## u44: tests of the scripts

```sh
cd macos
python3 -I -B scripts/audit-harnesses/u44/test_github_math.py
python3 -B scripts/audit-harnesses/u44/test_help_generators.py
python3 -B scripts/audit-harnesses/u44/test_help_validate.py
bash scripts/audit-harnesses/u44/check_build_dmg_overwrite.sh
```

Each takes an optional path argument (the script or tree under test,
defaulting to this repository's) and runs in well under a second. The
Python tests print `PASS`/`FAIL` per case and end with `OK: 0 failed`, exit 0.

| Script | Fixes | What it checks |
|---|---|---|
| `test_github_math.py [github_math.py]` | U25-F1, U25-F6 | `fix --offline` on scratch Markdown in a temp dir: an unterminated ```` ```math ```` fence at end of file keeps its last line and is closed; an unterminated ```` ```python ```` fence is left alone; two `$$…$$` formulas with prose between them on one line stay two inline formulas; the controls (closed fence, lone `$$x^2$$`, multi-line `$$` block) are unchanged (7 cases) |
| `test_help_generators.py [scripts/help]` | U26-F2, U26-F5 | Imports `weight_tables.py` and `pages.py` (no bytecode written): the "first 18 hours" column covers H0 and H1 (`NBM (2.5 / 3)`), the "after 3 days" column is unchanged, a model leading only in H1 is listed, the header names both bands; the Sources & Weights page scopes "weigh 0" to outside the US and southern Canada for HRRR and NBM (7 checks) |
| `test_help_validate.py [tree [swift-tree]]` | U26-F1, U26-F3 | Copies the Help Book, `scripts/help` and `Weather/` into a temp dir per case and breaks it: with every page's `<title>` removed, `validate.py` reports each page (the count follows the bundle: 15 pages on 2026-10-27, 14 when the fix landed); a wrong title is reported; a hand edit of a bundled page, or a `pages.py` / `weight_tables.html` edit without `regenerate.py`, is reported as stale; the pristine copy passes (6 cases) |
| `check_build_dmg_overwrite.sh [build_dmg.sh]` | U25-F5 | Static only (nothing is built, `hdiutil` never runs): `build_dmg.sh` parses (`bash -n`) and runs `rm -f "$DMG_OUTPUT"` before `hdiutil convert`. Prints `PASS: rm -f "$DMG_OUTPUT" at :N precedes hdiutil convert at :M`, exit 0 |

The generator and validator tests pin page wording (`HRRR stops after 48
hours`, the Sources & Weights sentences). When that wording changes on
purpose, update the pinned strings with it.
