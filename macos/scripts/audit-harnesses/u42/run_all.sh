#!/bin/bash
# U42 evidence harness: the app-target fixes U19-F1/F2, U20-F1/F2/F3/F5/F7/F8/F12 and U21-F1/F2/F4/F5,
# which the WeatherCoreTests bundle cannot reach (the Weather app target has no test bundle).
#
#   bash run_all.sh [--old DIR]
#
# Builds WeatherCore.framework from $REPO, then two probes, each ONE module compiled from a scratch copy
# of $REPO/Weather (scratch_build.sh: StationKeys replaced by the in-memory stub, no SecItem reference
# allowed, checked again before each run): liveprobe (the live-station/Open-Meteo/AQ path, every HTTP
# request answered in-process by the URLProtocol stub in liveprobe.swift: no network) and uiprobe (the
# Detail view code, rendered off screen with ImageRenderer). Prints both outputs. With --old DIR it also
# builds the probes with DIR's *.swift in place of Weather/Detail/*.swift (e.g. a pre-fix copy of the
# Detail files) and prints the differences (that tree must still compile against the current WeatherCore).
#
# REPO defaults to the macos/ directory three levels above this script. DD=<dir> builds (incrementally)
# into that derived-data directory and keeps it; without DD a fresh one is built in the temp directory.
# Everything else (scratch copies, binaries, outputs, the probes' TMPDIR) lives in a mktemp -d directory
# that is removed on exit; nothing is written into the working tree. U42_DUMP=<dir> makes uiprobe also
# write its debug PNGs into <dir>.
# Exit 0: everything built, passed the SecItem gate and ran to completion (read the lines against the
# README for the verdicts).
set -eu
H=$(cd "$(dirname "$0")" && pwd)
REPO="${REPO:-$(cd "$H/../../.." && pwd)}"
export REPO
[ -f "$REPO/Weather.xcodeproj/project.pbxproj" ] || { echo "REPO=$REPO is not the macos/ directory"; exit 2; }
OLD=""
if [ "${1:-}" = "--old" ]; then
  [ -d "${2:-}" ] || { echo "usage: run_all.sh [--old DIR]"; exit 2; }
  OLD=$(cd "$2" && pwd)
elif [ $# -gt 0 ]; then
  echo "usage: run_all.sh [--old DIR]"; exit 2
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/u42-harness.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/run" "$T/bin" "$T/scratch"

# ---- WeatherCore.framework and the app target's generated asset symbols (compiled, never run; no signing)
DDIR="${DD:-$T/dd}"
echo "building the Weather scheme from $REPO (derived data: ${DD:-temporary}) ..."
if ! xcodebuild -project "$REPO/Weather.xcodeproj" -scheme Weather -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$DDIR" CODE_SIGNING_ALLOWED=NO build > "$T/xcodebuild.log" 2>&1; then
  echo "xcodebuild FAILED"; grep -E 'error:' "$T/xcodebuild.log" | head -20; exit 2
fi
export PRODUCTS="$DDIR/Build/Products/Debug"
[ -f "$PRODUCTS/WeatherCore.framework/WeatherCore" ] || { echo "no WeatherCore.framework in $PRODUCTS"; exit 2; }
n=$(nm -u "$PRODUCTS/WeatherCore.framework/WeatherCore" | grep -c SecItem || true)
echo "gate: nm -u WeatherCore.framework/WeatherCore | grep -c SecItem -> $n"
[ "$n" = 0 ] || { echo "REFUSED: WeatherCore references SecItem"; exit 1; }
ASSET_SYMBOLS=$(find "$DDIR/Build/Intermediates.noindex/Weather.build" -path '*/Weather.build/DerivedSources/GeneratedAssetSymbols.swift' 2>/dev/null | head -1)
export ASSET_SYMBOLS

# ---- the probes: "new" = the tree, "old" = the tree with DIR's Detail files
variants="new"; [ -n "$OLD" ] && variants="old new"
mkdir -p "$T/src-live"; cp "$H/liveprobe.swift" "$T/src-live/main.swift"
for v in $variants; do
  if [ "$v" = old ]; then DET="$OLD"; export DETAIL_DIR="$OLD"; else DET="$REPO/Weather/Detail"; unset DETAIL_DIR; fi
  mkdir -p "$T/src-ui-$v"; cp "$H/uiprobe_main.swift" "$T/src-ui-$v/main.swift"
  python3 -I "$H/gen_ui.py" "$DET/DetailView.swift" "$DET/DetailRainChart.swift" "$T/src-ui-$v/ui_gen.swift"
  echo "compiling liveprobe-$v and uiprobe-$v (each compiles the whole app target) ..."
  "$H/scratch_build.sh" "$T/scratch/$v-liveprobe" "$T/bin/liveprobe-$v" "$T/src-live/main.swift"
  "$H/scratch_build.sh" "$T/scratch/$v-uiprobe" "$T/bin/uiprobe-$v" "$T/src-ui-$v/main.swift" "$T/src-ui-$v/ui_gen.swift"
done
rc=0
for v in $variants; do
  for b in liveprobe uiprobe; do
    n=$(nm -u "$T/bin/$b-$v" | grep -c SecItem || true)
    echo "gate: nm -u $b-$v | grep -c SecItem -> $n"
    [ "$n" = 0 ] || { echo "REFUSED to run $b-$v"; exit 1; }
    k=${b%probe}
    (cd "$T/run" && TMPDIR="$T/tmp/" "$T/bin/$b-$v" > "$T/out-$k-$v.txt" 2>&1) || { echo "$b-$v FAILED (exit $?)"; rc=1; }
    echo "=== $b-$v output"; cat "$T/out-$k-$v.txt"
  done
done
if [ -n "$OLD" ]; then
  for k in live ui; do
    echo "=== $k: old (<) vs new (>)"; diff "$T/out-$k-old.txt" "$T/out-$k-new.txt" || true
  done
fi
echo "u42: $([ $rc = 0 ] && echo 'all probes ran' || echo 'a probe FAILED')"
exit $rc
