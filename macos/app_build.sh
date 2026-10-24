#!/usr/bin/env bash
# =============================================================================
# Weather — Archive + Developer ID Export
# =============================================================================
#
# USAGE
#   ./app_build.sh [output-dir]
#
#   output-dir  Directory where Weather.app is written
#               (default: ~/Downloads/Release)
#
# PREREQUISITES
#   Developer ID Application cert in login Keychain
#   ExportOptions.plist present alongside this script
#
# WORKFLOW
#   1. Archive the Release scheme via xcodebuild.
#   2. Export the archive using ExportOptions.plist (Developer ID, automatic
#      provisioning) to produce a properly signed .app for distribution.
#
# EXIT
#   Exits non-zero on any failure (set -euo pipefail).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="${1:-$HOME/Downloads/Release}"
ARCHIVE_PATH="$OUTPUT_DIR/Weather.xcarchive"
PROJECT_PATH="$SCRIPT_DIR/Weather.xcodeproj"
LOCAL_XCCONFIG="$SCRIPT_DIR/Local.xcconfig"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

mkdir -p "$OUTPUT_DIR"

# ─── Resolve signing team from Local.xcconfig ────────────────────────────────
# Pre-condition:  Local.xcconfig exists beside this script and defines
#                 `BB_DEVELOPMENT_TEAM = <10-char team id>` plus the
#                 `DEVELOPMENT_TEAM = $(BB_DEVELOPMENT_TEAM)` mapping.
# Post-condition: the archive step receives DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY,
#                 and ENABLE_HARDENED_RUNTIME via the -xcconfig override, so
#                 automatic Developer ID signing selects the right certificate
#                 without a team being baked into project.pbxproj.
# Why: the committed project.pbxproj intentionally omits DEVELOPMENT_TEAM (and
#      uses ad-hoc signing for local/test builds); Local.xcconfig (a
#      non-committed file) injects the team and Hardened Runtime for release
#      archives.
if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
    echo "❌  $LOCAL_XCCONFIG not found."
    echo "    Copy Local.xcconfig.example → Local.xcconfig and set BB_DEVELOPMENT_TEAM."
    exit 1
fi
if [[ ! -f "$EXPORT_OPTIONS" ]]; then
    echo "❌  $EXPORT_OPTIONS not found (required for the Developer ID export)."
    echo "    See ExportOptions.plist alongside this script."
    exit 1
fi

# ─── Step 1: Archive ─────────────────────────────────────────────────────────
# Pre-condition:  BUILD_VERSION env var is set (exported by build.sh)
# Post-condition: Archive at ARCHIVE_PATH with CFBundleVersion = BUILD_VERSION
# CURRENT_PROJECT_VERSION overrides the project setting and is injected into
# Info.plist via the $(CURRENT_PROJECT_VERSION) variable in CFBundleVersion.
# VERSIONING_SYSTEM="" prevents WeatherCore's apple-generic stub generator from
# treating the colon-delimited timestamp as a C floating-point literal.
echo "==> [1/2] Archiving Weather (Release)"
xcodebuild clean archive \
    -project "$PROJECT_PATH" \
    -scheme Weather \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -xcconfig "$LOCAL_XCCONFIG" \
    -allowProvisioningUpdates \
    VERSIONING_SYSTEM="" \
    CURRENT_PROJECT_VERSION="${BUILD_VERSION:-$(date '+%Y:%m:%d:%H:%M')}"

# ─── Step 2: Export Developer ID–signed .app ─────────────────────────────────
echo "==> [2/2] Exporting Developer ID–signed .app → $OUTPUT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUTPUT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates
