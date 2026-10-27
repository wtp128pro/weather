#!/bin/bash
# check_build_dmg_overwrite.sh [build_dmg.sh] — static U25-F5 check (hdiutil is never run; the script is only
# read): it must remove an existing "$DMG_OUTPUT" before `hdiutil convert ... -o "$DMG_OUTPUT"`, and must
# still parse. The default script is $REPO/scripts/build_dmg.sh, where REPO defaults to the macos/ directory
# three levels above this file.
set -u
REPO="${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
f="${1:-$REPO/scripts/build_dmg.sh}"
[ -f "$f" ] || { echo "FAIL: no such file: $f"; exit 2; }
bash -n "$f" || { echo "FAIL: bash -n"; exit 1; }
conv=$(grep -n '^hdiutil convert' "$f" | head -1 | cut -d: -f1)
rm_line=$(grep -nE '^rm -f "\$DMG_OUTPUT"$' "$f" | head -1 | cut -d: -f1)
if [ -n "$conv" ] && [ -n "$rm_line" ] && [ "$rm_line" -lt "$conv" ]; then
  echo "PASS: rm -f \"\$DMG_OUTPUT\" at :$rm_line precedes hdiutil convert at :$conv"; exit 0
fi
echo "FAIL: no rm -f \"\$DMG_OUTPUT\" before hdiutil convert (convert at :${conv:-none}, rm at :${rm_line:-none})"; exit 1
