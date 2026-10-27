#!/bin/bash
# scratch_build.sh <scratch-dir> <out-binary> <probe main.swift> [more probe files...]
#   env: REPO (the macos/ directory), PRODUCTS (an Xcode Debug products dir holding WeatherCore.framework),
#        ASSET_SYMBOLS (optional: the app target's GeneratedAssetSymbols.swift),
#        DETAIL_DIR (optional: Weather/Detail/*.swift copies compiled instead of the tree's, e.g. pre-fix ones)
# Builds a probe as ONE module from a scratch copy of $REPO/Weather made in <scratch-dir> (which must be
# under a temp directory; it is emptied first). WeatherApp.swift (@main) is left out and
# Weather/Detail/StationKeys.swift is replaced by stub/StationKeys.swift (in-memory, no Security framework).
# The probe links the WeatherCore.framework in $PRODUCTS. Refuses a source that imports Security or names
# SecItem, and refuses to leave a binary that references SecItem*.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
: "${REPO:?}" "${PRODUCTS:?}"
S="$1"; OUT="$2"; shift 2
case "$(cd "$(dirname "$S")" && pwd)/" in "$(cd "$REPO" && pwd)/"*) echo "REFUSED: scratch dir $S is inside REPO"; exit 1;; esac
rm -rf "$S"; mkdir -p "$S"
cp -R "$REPO/Weather" "$S/Weather"
if [ -n "${DETAIL_DIR:-}" ]; then cp "$DETAIL_DIR"/*.swift "$S/Weather/Detail/"; fi
cp "$H/stub/StationKeys.swift" "$S/Weather/Detail/StationKeys.swift"
rm "$S/Weather/WeatherApp.swift"
extra=()
if [ -n "${ASSET_SYMBOLS:-}" ]; then cp "$ASSET_SYMBOLS" "$S/GeneratedAssetSymbols.swift"; extra=("$S/GeneratedAssetSymbols.swift"); fi
mkdir -p "$S/probe"; for f in "$@"; do sed '/@testable import Neginato_Mezora/d' "$f" > "$S/probe/$(basename "$f")"; done
files=(); while IFS= read -r f; do files+=("$f"); done < <(find "$S/Weather" -name '*.swift')
if grep -l "import Security\|SecItem" "${files[@]}" "$S"/probe/*.swift; then
  echo "REFUSED: a source imports Security / names SecItem"; exit 1
fi
swiftc -swift-version 6 -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility \
  -module-name ProbeApp -F "$PRODUCTS" -framework WeatherCore -Xlinker -rpath -Xlinker "$PRODUCTS" -o "$OUT" \
  "${files[@]}" ${extra[@]+"${extra[@]}"} "$S"/probe/*.swift
n=$(nm -u "$OUT" | grep -c SecItem || true)
echo "nm -u $(basename "$OUT") | grep -c SecItem -> $n"
if [ "$n" != 0 ]; then rm -f "$OUT"; echo "REFUSED: binary references SecItem"; exit 1; fi
