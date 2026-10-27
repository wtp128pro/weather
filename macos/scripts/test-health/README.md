# Test-health scan

`scan_tests.py` is a mechanical, read-only scan of the Swift Testing / XCTest
tree for patterns that often make a test vacuous, flaky or order-dependent. It
reads every file under the test tree and writes a list of hits; it never
builds, runs or edits anything.

Every hit is a **candidate**, not a defect: the scan matches text, so each hit
must be confirmed (or dismissed) by reading the code around it. Many hits are
deliberate (a test of the clock has to read the clock; a suite that touches a
shared resource is `.serialized` on purpose).

Python 3 standard library only.

```sh
cd macos
python3 scripts/test-health/scan_tests.py                         # scan WeatherCoreTests, write to stdout
python3 scripts/test-health/scan_tests.py --out "$TMPDIR/scan.tsv"  # write to a file
python3 scripts/test-health/scan_tests.py --root path/to/OtherTests --out -
```

| Flag | Default | Meaning |
|---|---|---|
| `--root DIR` | `../../WeatherCoreTests` relative to the script (`macos/WeatherCoreTests`) | The test tree to scan; works from any working directory. |
| `--out FILE` | `-` (standard output) | Where to write the hits. With `-`, the one-line summary goes to standard error. |

Exit 0 after writing; exit 1 (with a message) if `--root` is not a directory.
Keep the output outside the repository (or delete it): it is a report, not a
source file.

## What it finds

Swift files are scanned line by line (comments are stripped first, except for
the `disabled` kind, which also looks for a commented-out `@Test`). Every
non-Swift file under the root is treated as a test-bundle fixture, because the
test target copies fixtures **flat** into the bundle (see
`WeatherCoreTests/Support/TestSupport.swift`, `Fixtures`).

| Kind | What matches | Typical false positive |
|---|---|---|
| `no-expectation` | An `@Test` function, or an XCTest `test…` function, whose body has no `#expect`, `#require`, `XCTAssert…`, `XCTFail`, `Issue.record`, `confirmation(` or `withKnownIssue`, and calls no helper that has one | A test that only checks that a `try` does not throw |
| `expectation-via-helper` | Informational: such a test that calls a helper which asserts (found transitively). The detail lists up to four helpers | Usually fine; confirm the helper asserts on this test's values |
| `disabled` | `.disabled`, `.enabled(if:`, `XCTSkip`, `withKnownIssue`, or a commented-out `@Test` | A condition that is true on every machine that runs the suite |
| `sleep` | `Task.sleep`, `sleep(`, `usleep(`, `Thread.sleep`, `asyncAfter(` | A deadline or a cancellation test that needs real time to pass |
| `wall-clock` | `Date()`, `Date.now`, `CFAbsoluteTimeGetCurrent`, `DispatchTime.now`, `systemUptime` | A test of the clock itself |
| `real-host` | An `http(s)://` literal whose host is not `127.0.0.1`, `localhost`, `[::1]`, `*.invalid`, `*.test` or `example.com/.org/.net`; `URLSession.shared` | A URL that is only parsed or compared, never requested |
| `shared-state` | `static var`, `nonisolated(unsafe)`, `UserDefaults.standard`, a fixed `"/tmp/…"` path, `.serialized` | A computed `static var`; a suite serialized on purpose |
| `fixture-dup` | Two fixtures with the same file name in different folders (the flat copy keeps only one) | Rare: a non-Swift file under the root that is not a bundle resource |
| `fixture-unused` | A fixture whose file name, and whose stem in quotes, appear in no Swift file (an interpolated prefix such as `"stations-smhi-\(p).json"` counts as a reference to every fixture with that prefix) | A fixture loaded through a name built some other way |

## Reading the output

Two header lines, then one tab-separated hit per line: kind, `file:line`
(relative to the parent of the root), detail (the trimmed source line, cut at
140 characters, or the function and its helpers).

```text
# command: python3 scripts/test-health/scan_tests.py
# swift_files=87 fixtures=60 hits=241
sleep	WeatherCoreTests/ViewModels/DetailViewModelTests.swift:1373	try? await Task.sleep(for: .milliseconds(2))
wall-clock	WeatherCoreTests/Core/ClockTests.swift:22	let before = Int64(Date().timeIntervalSince1970 * 1_000_000)
disabled	WeatherCoreTests/Alerts/AlertsServiceTests.swift:641	@Test(.enabled(if: HoldSecondCovers.poolCanHold, "a held coverage check needs two cooperative threads"))
shared-state	WeatherCoreTests/ViewModels/PickerViewModelTests.swift:261	@Suite(.serialized, .timeLimit(.minutes(2)))
expectation-via-helper	WeatherCoreTests/ViewModels/DetailViewModelTests.swift:611	func rainDry -> checkRain
```

(Lines of the run on 2026-10-27; numbers move as the tests change.)

To triage, group by kind (`cut -f1 scan.tsv | sort | uniq -c`), then open each
`file:line`. A `fixture-dup` is almost always real. A `no-expectation` is real unless
the test body proves something by not throwing, and the right fix is then
usually an explicit `#expect`. For `sleep` and `wall-clock`, ask whether the
test would still pass on a loaded machine, or at midnight, or across a DST
change; prefer an injected clock. For `real-host`, check whether the URL is
ever requested. Record the hits you dismiss and why, so the next scan can be
compared against them.
