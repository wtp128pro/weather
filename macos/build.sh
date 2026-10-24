#!/usr/bin/env bash
# =============================================================================
# Weather — Clean Build + DMG Script
# =============================================================================
#
# USAGE
#   ./build.sh [output-dir]
#
#   output-dir  Directory where Weather.dmg is written (default: ~/Downloads)
#
# PREREQUISITES
#   scripts/signing_credentials.sh filled in (see .example)
#   python3 on PATH (the DMG step's ds_store + mac_alias are provisioned
#     automatically into a private venv — see scripts/dmg_python.sh)
#   Developer ID Application cert in login Keychain
#   Active internet connection (notarization contacts Apple servers)
#
# WORKFLOW
#   0. Preflight: make sure the DMG step's Python environment is usable BEFORE
#      spending minutes on the archive (it is provisioned/rebuilt if needed).
#   1. Delegate archive + Developer ID export to app_build.sh.
#   2. Pass the resulting .app to build_dmg.sh, which signs, packages, notarizes,
#      and staples a read-only DMG into the output directory.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="${1:-$HOME/Downloads}"
BUILD_DIR="/tmp/Weather-build"
APP_PATH="$BUILD_DIR/Weather.app"

# ─── Build version: year:month:day:hour:minute ────────────────────────────────
# Pre-condition:  none
# Post-condition: BUILD_VERSION is exported and available to child scripts
# Format:         YYYY:MM:DD:HH:MM (e.g. 2026:06:13:14:30)
export BUILD_VERSION
BUILD_VERSION="$(date '+%Y:%m:%d:%H:%M')"
echo "==> Build version: $BUILD_VERSION"

# ─── Step 0: Preflight the DMG step's Python environment ─────────────────────
# Pre-condition:  python3 on PATH; network access if the venv must be (re)built
# Post-condition: DMG_PYTHON is exported for build_dmg.sh, or the script exits
#                 here — before the archive — instead of failing at the very end
source "$SCRIPT_DIR/scripts/dmg_python.sh"
ensure_dmg_python || exit 1

# ─── Step 1: Build ───────────────────────────────────────────────────────────
"$SCRIPT_DIR/app_build.sh" "$BUILD_DIR"

# ─── Step 2: Package DMG ─────────────────────────────────────────────────────
echo "==> [2/2] Packaging DMG → $OUTPUT_DIR/Weather.dmg"
rm -f "$OUTPUT_DIR/Weather.dmg"
"$SCRIPT_DIR/scripts/build_dmg.sh" "$APP_PATH" "$OUTPUT_DIR"
