#!/bin/sh
# Checks that the application id is spelled the same everywhere it matters.
#
# Usage: check-app-id.sh [SOURCE_ROOT]     (default: the parent of this script)
#
# The id is WX_APP_ID in src/ui/wx-app.h. It must also be
#   - the base name of the desktop file and of the metainfo file, the Icon= of
#     the desktop file, the <id> and <launchable> of the metainfo file,
#   - the base name of the two installed icons (and the only icons shipped),
#   - the GResource prefix of src/ui/weather.gresource.xml and the CSS path
#     constant in src/ui/wx-app.c (the id with '.' turned into '/').
# Needs only POSIX sh, grep and sed.

set -u

root=${1:-$(dirname "$0")/..}
cd "$root" || exit 2

fail=0
bad() {
  echo "check-app-id: $*" >&2
  fail=1
}

header=src/ui/wx-app.h
id=$(sed -n 's/^#define WX_APP_ID "\([^"]*\)".*/\1/p' "$header" 2>/dev/null)
if [ -z "$id" ]; then
  echo "check-app-id: no WX_APP_ID in $header" >&2
  exit 1
fi
path=/$(echo "$id" | sed 's|\.|/|g')

desktop=data/$id.desktop.in
metainfo=data/$id.metainfo.xml.in
scalable=data/icons/hicolor/scalable/apps/$id.svg
symbolic=data/icons/hicolor/symbolic/apps/$id-symbolic.svg

for f in "$desktop" "$metainfo" "$scalable" "$symbolic"; do
  [ -f "$f" ] || bad "missing file $f"
done

# All comparisons are literal (grep -F / string equality): the id contains dots.
[ -f "$desktop" ] && ! grep -qxF "Icon=$id" "$desktop" && bad "$desktop: Icon= is not $id"
if [ -f "$metainfo" ]; then
  meta_id=$(sed -n 's|^[[:space:]]*<id>\(.*\)</id>[[:space:]]*$|\1|p' "$metainfo")
  [ "$meta_id" = "$id" ] || bad "$metainfo: <id> is not $id"
  meta_launch=$(sed -n 's|^[[:space:]]*<launchable type="desktop-id">\(.*\)</launchable>[[:space:]]*$|\1|p' "$metainfo")
  [ "$meta_launch" = "$id.desktop" ] || bad "$metainfo: <launchable> is not $id.desktop"
fi

# Only the two icons may exist under data/icons.
for f in $(find data/icons -type f | sort); do
  [ "$f" = "$scalable" ] || [ "$f" = "$symbolic" ] || bad "unexpected icon file $f"
done

grep -qF "<gresource prefix=\"$path/ui\">" src/ui/weather.gresource.xml ||
  bad "src/ui/weather.gresource.xml: prefix is not $path/ui"
grep -qxF "#define CSS_RESOURCE_PATH \"$path/ui/style.css\"" src/ui/wx-app.c ||
  bad "src/ui/wx-app.c: CSS_RESOURCE_PATH is not $path/ui/style.css"

[ "$fail" -eq 0 ] && echo "check-app-id: $id is consistent"
exit "$fail"
