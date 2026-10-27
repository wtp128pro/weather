#!/bin/bash
# U43 evidence harness: the app-target fixes U22-F2, U23-F1/F3/F5/F6 and U24-F1/F2/F3/F5, which the
# WeatherCoreTests bundle cannot reach (the Weather app target has no test bundle).
#
#   bash run.sh [new | old | mutants | all | <mutant name>]...      (default: new)
#
#   new      the repository's sources ($REPO)
#   old      a pre-fix copy of the four files, in OLD_SRC=<dir> holding Weather/Shell/ShellRow.swift,
#            Weather/Settings/SettingsView.swift, Weather/Settings/StationsSettingsTab.swift and
#            Weather/Picker/PickerView.swift (report only: its pins are expected to fail)
#   mutants  every named breaking edit in extract.py's MUTANTS, applied to $REPO (each must make its
#            harness fail: the non-vacuity check)
#   all      new, then mutants
#
# Each harness is compiled from VERBATIM extracts (extract.py) + in-memory stubs (drivers/), linked against
# a WeatherCore.framework built from $REPO, checked with `nm -u <bin> | grep -c SecItem` == 0 BEFORE it runs
# (and the framework too), and never puts a window on screen. No network. Nothing is written into the
# working tree: products, extracts and binaries live in a mktemp -d directory that is removed on exit.
#
# REPO defaults to the macos/ directory three levels above this script. DD=<dir> builds (incrementally)
# into that derived-data directory and keeps it, so later runs are fast; without DD a fresh one is built
# in the temp directory and removed (a full build: several minutes).
# Exit 0: every `new` harness passed, every mutant was caught, nothing was refused or failed to build.
set -u
H=$(cd "$(dirname "$0")" && pwd)
REPO="${REPO:-$(cd "$H/../../.." && pwd)}"
export REPO
[ -f "$REPO/Weather.xcodeproj/project.pbxproj" ] || { echo "REPO=$REPO is not the macos/ directory"; exit 2; }
MUTANTS="badge-substring settings-rebuild f3-cancel f5-signed f6-ts0 f6-hour-from-tS f1-guard f2-guard f3-count f5-inflight f5-answered f5-nodedupe"

T=$(mktemp -d "${TMPDIR:-/tmp}/u43-harness.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp"

# ---- WeatherCore.framework from $REPO (app code is compiled, never run; no signing)
DDIR="${DD:-$T/dd}"
echo "building WeatherCore.framework from $REPO (derived data: ${DD:-temporary}) ..."
if ! xcodebuild -project "$REPO/Weather.xcodeproj" -scheme Weather -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$DDIR" CODE_SIGNING_ALLOWED=NO build > "$T/xcodebuild.log" 2>&1; then
  echo "xcodebuild FAILED"; grep -E 'error:' "$T/xcodebuild.log" | head -20; exit 2
fi
FW=$DDIR/Build/Products/Debug
[ -f "$FW/WeatherCore.framework/WeatherCore" ] || { echo "no WeatherCore.framework in $FW"; exit 2; }
n=$(nm -u "$FW/WeatherCore.framework/WeatherCore" | grep -c SecItem)
echo "nm -u WeatherCore.framework/WeatherCore | grep -c SecItem -> $n"
[ "$n" = "0" ] || { echo "REFUSING: WeatherCore references SecItem"; exit 1; }

stubs_of() { case "$1" in settings|stations|picker) echo "stubs_$1.swift";; *) echo "";; esac; }
harness_of() { case "$1" in old|new) echo "badge settings stations picker undo";; badge-*) echo badge;; settings-*) echo settings;;
  f3-cancel|f5-signed|f6-*) echo stations;; f1-*) echo undo;; *) echo picker;; esac; }

variants=""
for a in "${@:-new}"; do
  case "$a" in
    all) variants="$variants new $MUTANTS";;
    mutants) variants="$variants $MUTANTS";;
    new|old) variants="$variants $a";;
    *) case " $MUTANTS " in *" $a "*) variants="$variants $a";; *) echo "unknown variant: $a"; exit 2;; esac;;
  esac
done

bad=0; new_ok=0; new_n=0; caught=0; mut_n=0; old_fail=0; old_n=0
for variant in $variants; do
  B=$T/build/$variant; rm -rf "$B"; mkdir -p "$B/gen"
  case $variant in
    old) [ -n "${OLD_SRC:-}" ] || { echo "old needs OLD_SRC=<dir with the four pre-fix files>"; exit 2; }
         python3 -I "$H/extract.py" "$OLD_SRC" "$B/gen" >/dev/null || { echo "== old: extract FAILED"; bad=1; continue; };;
    new) python3 -I "$H/extract.py" "$REPO" "$B/gen" >/dev/null || { echo "== new: extract FAILED"; bad=1; continue; };;
    *) python3 -I "$H/extract.py" "$REPO" "$B/gen" --mutant "$variant" >/dev/null || { echo "== $variant: extract FAILED"; bad=1; continue; };;
  esac
  for h in $(harness_of $variant); do
    D=$B/$h; mkdir -p "$D"; cp "$B/gen/${h}_extract.swift" "$D/"; cp "$H/drivers/main_${h}.swift" "$D/main.swift"
    st=$(stubs_of $h); [ -n "$st" ] && cp "$H/drivers/$st" "$D/"
    case $variant in old) old_n=$((old_n + 1));; new) new_n=$((new_n + 1));; *) mut_n=$((mut_n + 1));; esac
    if grep -l 'import Security\|SecItem' "$D"/*.swift; then
      echo "== $variant/$h: REFUSING to build: a source imports Security / names SecItem"; bad=1; continue
    fi
    if ! swiftc -swift-version 6 -default-isolation MainActor -module-name "H_$h" -F "$FW" -framework WeatherCore \
        -Xlinker -rpath -Xlinker "$FW" -o "$D/bin" "$D"/*.swift > "$D/compile.log" 2>&1; then
      echo "== $variant/$h: COMPILE FAILED"; head -20 "$D/compile.log"; bad=1; continue
    fi
    sec=$(nm -u "$D/bin" | grep -c SecItem)
    echo "== $variant/$h: nm -u bin | grep -c SecItem -> $sec"
    [ "$sec" = "0" ] || { echo "REFUSING to run: SecItem symbols"; bad=1; continue; }
    (cd "$D" && TMPDIR="$T/tmp" ./bin > "$D/out.txt" 2>&1); rc=$?
    if [ "$variant" = old ] || [ "$variant" = new ]; then cat "$D/out.txt"; else grep -E "PIN FAIL|failures=|mismatches=|MISMATCH" "$D/out.txt" | head -8; fi
    echo "== $variant/$h: exit $rc"
    case $variant in
      old) [ "$rc" = 0 ] || old_fail=$((old_fail + 1));;
      new) if [ "$rc" = 0 ]; then new_ok=$((new_ok + 1)); else bad=1; fi;;
      *) if [ "$rc" != 0 ]; then caught=$((caught + 1)); else echo "== $variant/$h: mutant NOT CAUGHT"; bad=1; fi;;
    esac
  done
done
summary="u43: new harnesses passed $new_ok/$new_n; mutants caught $caught/$mut_n"
[ "$old_n" = 0 ] || summary="$summary; old (report only) harnesses failing $old_fail/$old_n"
echo "$summary; $([ $bad = 0 ] && echo PASS || echo FAIL)"
exit $bad
