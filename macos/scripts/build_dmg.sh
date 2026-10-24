#!/usr/bin/env bash
# =============================================================================
# Neginato Mezora — Code-Sign & DMG Build Script
# =============================================================================
#
# USAGE
#   ./scripts/build_dmg.sh <path/to/Neginato Mezora.app> [output-dir]
#
# PREREQUISITES
#   python3 on PATH — ds_store + mac_alias are provisioned automatically into a
#     private venv on first run (see scripts/dmg_python.sh; network needed once)
#   xcode-select --install               (Xcode CLI tools)
#   Developer ID Application cert in login Keychain
#   scripts/signing_credentials.sh filled in (see .example)
#
# WORKFLOW
#   NOTE: this script does NOT (re-)sign the .app. The bundle passed in as
#   APP_PATH must ALREADY be deep-signed with Developer ID + Hardened Runtime
#   (that happens upstream in the Xcode export step). This script's job is to
#   notarize + staple that bundle, package it, and gate-verify the result. It
#   only ADDS a notarization ticket to the .app — it never runs `codesign
#   --sign` against the bundle.
#   1. Load signing credentials.
#   2. Developer ID cert preflight: warn on imminent expiry, loudly flag an
#      abnormally short (revoke-reissue) validity window, and run a live
#      security verify-cert / OCSP check — abort if the leaf is not trusted.
#   3. Assert the incoming .app carries a secure Timestamp= (reject the legacy
#      ad-hoc "Signed Time=" form).
#   4. Notarize the .app itself (ditto-zip → notarytool submit --wait), gate on
#      "status: Accepted", then `xcrun stapler staple` the .app so it carries an
#      OFFLINE-verifiable ticket BEFORE packaging (a read-only DMG cannot be
#      stapled in place afterward).
#   5. Build a temporary read-write HFS+ disk image and mount it.
#   6. Copy the STAPLED .app, add the Applications symlink, copy the background.
#   7. Write .DS_Store directly via Python (no AppleScript / no Finder).
#      This is reliable on all macOS versions because it bypasses the Finder
#      scripting bridge, which was broken by -nobrowse mounting in all prior
#      versions of this script and create-dmg.
#   8. Hide .background so it does not appear as an icon.
#   9. Flush writes, unmount, convert to read-only UDZO.
#  10. Sign the DMG (with --timestamp), notarize the DMG, staple the DMG
#      (belt-and-suspenders on top of the already-stapled .app).
#  11. Pre-ship gate: copy the .app OUT of the finished DMG and verify it as the
#      user will receive it — spctl -a -t exec, codesign --verify --deep
#      --strict, and stapler validate — aborting the build on any failure.
#
# ICON LAYOUT  (matches the directional arrow in dmg_assets/background.png)
#   ┌──────────────────────────────────────────────────┐
#   │                                                  │
#   │  [Neginato Mezora.app] ──────►  [Applications]   │
#   │         x=155                       x=415        │
#   │                                                  │
#   └──────────────────────────────────────────────────┘
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITE_DS_STORE="$SCRIPT_DIR/dmg_assets/write_ds_store.py"


# ─── Dependency check ─────────────────────────────────────────────────────────
# write_ds_store.py runs in a private venv with pinned ds_store + mac_alias, so a
# Homebrew Python upgrade (or PEP 668) can no longer break the build. When run
# from build.sh this reuses the environment its preflight already provisioned.
source "$SCRIPT_DIR/dmg_python.sh"
ensure_dmg_python || exit 1


# ─── Load credentials ─────────────────────────────────────────────────────────
CREDS_FILE="$SCRIPT_DIR/signing_credentials.sh"
if [[ ! -f "$CREDS_FILE" ]]; then
    echo "❌  $CREDS_FILE not found."
    echo "    Copy signing_credentials.sh.example → signing_credentials.sh"
    exit 1
fi
# shellcheck source=signing_credentials.sh.example
source "$CREDS_FILE"

# Default provisioning profile path; signing_credentials.sh may override it.
BB_PROVISIONING_PROFILE="${BB_PROVISIONING_PROFILE:-$SCRIPT_DIR/../provisioning/Weather_Provisioning.provisionprofile}"


# ─── Input validation ─────────────────────────────────────────────────────────
APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "Usage: $0 <path/to/Neginato Mezora.app> [output-dir]"
    exit 1
fi

# BB_PROVISIONING_PROFILE must be set and point to a real file.
# Without an embedded provisioning profile the kernel refuses to spawn the app
# when iCloud/CloudKit entitlements are present (launchd error 163).
if [[ -z "${BB_PROVISIONING_PROFILE:-}" || ! -f "$BB_PROVISIONING_PROFILE" ]]; then
    echo "❌  BB_PROVISIONING_PROFILE is not set or the file does not exist."
    echo "    See scripts/signing_credentials.sh.example for instructions."
    exit 1
fi

OUTPUT_DIR="${2:-$(pwd)}"
APP_NAME="Neginato Mezora"
SHIPPED_APP_NAME="${APP_NAME}.app"
BACKGROUND_SRC="$SCRIPT_DIR/dmg_assets/background.png"
DMG_OUTPUT="$OUTPUT_DIR/${APP_NAME}.dmg"

# Use a fixed mount point to keep the alias path predictable.
# If a stale volume from a previous run is still mounted, detach it first.
MOUNT_POINT="/Volumes/NeginatoMezora-build"
# Separate mount point for the post-build verification gate, where the finished
# DMG is re-mounted read-only to inspect the .app exactly as it ships.
VERIFY_MOUNT="/Volumes/NeginatoMezora-verify"

# Basename of the incoming bundle (e.g. "Neginato Mezora.app").
APP_BASENAME="$(basename "$APP_PATH")"

TEMP_DIR="$(mktemp -d)"
TEMP_DMG="$TEMP_DIR/NeginatoMezora-rw.dmg"

cleanup() {
    hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
    hdiutil detach "${VERIFY_MOUNT:-}" 2>/dev/null || true
    hdiutil detach "/Volumes/Weather-build" 2>/dev/null || true
    hdiutil detach "/Volumes/Weather-verify" 2>/dev/null || true
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ─── Step 0a: Developer ID certificate preflight ─────────────────────────────
# Pre-condition : BB_SIGNING_IDENTITY names an installed "Developer ID
#                 Application" certificate present in the login keychain.
# Post-condition: aborts BEFORE any signing/notarization if the leaf is
#                 revoked/expired/untrusted; warns (non-fatal) on imminent
#                 expiry or an abnormally short validity window.
# Defends       : a ~8-month validity window is the fingerprint of an Apple
#                 revoke-and-reissue (the replacement inherits the original
#                 notAfter); a live OCSP check catches a revoked leaf before we
#                 ship another poisoned build. NOTE: this only INSPECTS the cert
#                 — it does NOT change the signing identity, bundle id,
#                 container, or entitlements.
echo "==> [0a] Developer ID certificate preflight"
CERT_PEM="$(security find-certificate -c "$BB_SIGNING_IDENTITY" -p 2>/dev/null || true)"
if [[ -z "$CERT_PEM" ]]; then
    echo "❌  Could not locate a certificate for identity: $BB_SIGNING_IDENTITY"
    exit 1
fi
CERT_DER="$TEMP_DIR/devid_leaf.der"
printf '%s\n' "$CERT_PEM" | openssl x509 -outform DER -out "$CERT_DER" 2>/dev/null

# Validity window. BSD `date -j -f` parses the OpenSSL "MMM DD HH:MM:SS YYYY GMT"
# form; the space-padded day is matched by %e. Parsing is best-effort (guarded
# with `|| echo 0`) so a locale quirk downgrades to no-warning, never a crash.
NOT_BEFORE="$(printf '%s\n' "$CERT_PEM" | openssl x509 -noout -startdate 2>/dev/null | cut -d= -f2)"
NOT_AFTER="$(printf '%s\n'  "$CERT_PEM" | openssl x509 -noout -enddate   2>/dev/null | cut -d= -f2)"
NB_EPOCH="$(date -j -f '%b %e %T %Y %Z' "$NOT_BEFORE" +%s 2>/dev/null || echo 0)"
NA_EPOCH="$(date -j -f '%b %e %T %Y %Z' "$NOT_AFTER"  +%s 2>/dev/null || echo 0)"
NOW_EPOCH="$(date +%s)"
if [[ "$NA_EPOCH" -gt 0 ]]; then
    DAYS_LEFT=$(( (NA_EPOCH - NOW_EPOCH) / 86400 ))
    echo "    Cert valid: $NOT_BEFORE  →  $NOT_AFTER  (${DAYS_LEFT} days left)"
    if [[ "$DAYS_LEFT" -lt 90 ]]; then
        echo "⚠️   Developer ID cert expires in < 90 days — renew before it lapses."
    fi
    # A normal Developer ID Application cert is issued for ~5 years. A window
    # under ~2 years is the tell-tale of a revoke-and-reissue (inherited notAfter).
    if [[ "$NB_EPOCH" -gt 0 && $(( (NA_EPOCH - NB_EPOCH) / 86400 )) -lt 730 ]]; then
        echo "⚠️   ABNORMAL cert validity (< 2 yr): likely a revoke-and-reissue."
    fi
fi

# Live trust/revocation evaluation (OCSP for the codeSign policy). Aborts if the
# leaf does not evaluate as trusted (revoked/expired/untrusted).
if ! security verify-cert -c "$CERT_DER" -p codeSign >/dev/null 2>&1; then
    echo "❌  security verify-cert failed for the Developer ID leaf."
    echo "    The signing cert may be revoked, expired, or untrusted — refusing to ship."
    exit 1
fi


# ─── Step 0b: Assert the incoming .app carries a SECURE timestamp ─────────────
# Pre-condition : APP_PATH is an already deep-signed, Hardened-Runtime bundle.
# Post-condition: aborts unless codesign reports a cryptographic 'Timestamp='
#                 (Apple TSA), rejecting the offline ad-hoc 'Signed Time=' form.
# Defends       : a secure timestamp is what lets a signature stay trustworthy
#                 past the cert's natural expiry; without it a lapsed cert
#                 invalidates every field build.
echo "==> [0b] Verifying secure timestamp on $APP_BASENAME"
# Capture-then-grep (no pipe). Under `set -o pipefail`, `codesign ... | grep -q`
# lets grep -q close the pipe on its first match; codesign then receives SIGPIPE
# and exits non-zero, and pipefail turns the whole pipeline into a FALSE failure
# even though the Timestamp WAS present. A here-string avoids the pipe entirely.
CS_TS_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
if ! grep -q '^Timestamp=' <<<"$CS_TS_INFO"; then
    echo "❌  $APP_BASENAME has no secure Timestamp= (ad-hoc 'Signed Time=' only)."
    echo "    Re-sign upstream with --timestamp before packaging. Refusing to ship."
    echo "--- codesign -dvv output was: ---"
    printf '%s\n' "$CS_TS_INFO"
    exit 1
fi


# ─── Step 0c: Notarize + STAPLE the .app itself (the root-cause fix) ──────────
# Pre-condition : APP_PATH is deep-signed with a secure timestamp (asserted above).
# Post-condition: the .app carries an OFFLINE-verifiable notarization ticket
#                 BEFORE it is copied into the (read-only) DMG. The bundle is
#                 NOT re-signed — stapler adds the ticket without a codesign pass.
# Defends       : stapling only the DMG leaves the .app the user drags to
#                 /Applications with NO local ticket and dependent on an online
#                 Gatekeeper lookup that can later fail.
echo "==> [0c] Notarizing the .app (may take several minutes)…"
APP_ZIP="$TEMP_DIR/${APP_NAME}-notarize.zip"
# ditto --keepParent preserves the bundle layout, symlinks, and xattrs that
# notarytool requires (a plain `zip` corrupts nested framework symlinks).
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

APP_SUBMIT_OUT="$(xcrun notarytool submit "$APP_ZIP" \
    --apple-id "$BB_APPLE_ID" \
    --password "$BB_APP_PASSWORD" \
    --team-id  "$BB_TEAM_ID" \
    --wait 2>&1)" || { printf '%s\n' "$APP_SUBMIT_OUT"; echo "❌  .app notarization submit failed"; exit 1; }
printf '%s\n' "$APP_SUBMIT_OUT"

# Capture the submission id (first 'id:' line) and INDEPENDENTLY confirm the
# terminal status is 'Accepted' before trusting the ticket.
APP_SUBMISSION_ID="$(printf '%s\n' "$APP_SUBMIT_OUT" | awk '/id:/{print $2; exit}')"
if [[ -z "$APP_SUBMISSION_ID" ]]; then
    echo "❌  Could not parse a notarization submission id for the .app."
    exit 1
fi
# Capture-then-grep (see the [0b] note): avoids the pipefail + grep -q SIGPIPE
# false-failure on notarytool's multi-line output.
APP_NOTARY_INFO="$(xcrun notarytool info "$APP_SUBMISSION_ID" \
        --apple-id "$BB_APPLE_ID" \
        --password "$BB_APP_PASSWORD" \
        --team-id  "$BB_TEAM_ID" 2>&1)"
if ! grep -q 'status: Accepted' <<<"$APP_NOTARY_INFO"; then
    echo "❌  .app notarization is not Accepted (submission $APP_SUBMISSION_ID)."
    printf '%s\n' "$APP_NOTARY_INFO"
    exit 1
fi

# Staple NOW, while the bundle is still writable. A read-only UDZO DMG cannot be
# stapled in place, so this MUST precede packaging. stapler adds the ticket
# WITHOUT re-signing the bundle.
echo "==> [0c] Stapling the .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH" \
  || { echo "❌  stapler validate failed on $APP_PATH after stapling"; exit 1; }


# ─── Step 1: Create a blank read-write HFS+ disk image ───────────────────────
# We create an empty image instead of using -srcfolder because we need room
# to add the Applications symlink, .background folder, and .DS_Store metadata
# on top of the .app payload.
echo "==> [1/5] Creating RW disk image"
# Note: -format is incompatible with -size; omitting it defaults to UDRW (read-write).
hdiutil create \
    -size 300m \
    -fs HFS+ \
    -volname "${APP_NAME}" \
    "$TEMP_DMG"


# ─── Step 2: Mount the RW image ───────────────────────────────────────────────
# -nobrowse : hide from Finder sidebar and Launch Services.
#             Prevents Finder and Spotlight from registering the build volume,
#             which would hold the device busy and make hdiutil detach fail.
#             write_ds_store.py uses getattrlist(2) directly — a kernel syscall
#             that works regardless of the -nobrowse flag.
# -noautoopen: suppress Finder auto-opening a window for the volume.
echo "==> [2/5] Mounting disk image at $MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNT_POINT" -nobrowse -noautoopen


# ─── Step 3: Populate the volume ──────────────────────────────────────────────
echo "==> [3/5] Populating DMG volume"

# Prevent Spotlight from indexing the build volume.
# Without this, mds opens the device and holds it busy, causing
# hdiutil detach to fail with "Resource busy".
touch "$MOUNT_POINT/.metadata_never_index"

# Copy the signed + stapled .app bundle under the actual application name
cp -R "$APP_PATH" "$MOUNT_POINT/$SHIPPED_APP_NAME"

# Create the Applications folder symlink for drag-to-install
ln -sf /Applications "$MOUNT_POINT/Applications"

# Background image: hidden .background folder (Finder convention)
mkdir -p "$MOUNT_POINT/.background"
cp "$BACKGROUND_SRC" "$MOUNT_POINT/.background/background.png"

# Hide .background so it does not appear as an icon in the window.
# Use both chflags (UF_HIDDEN) and SetFile (kIsInvisible) for compatibility.
chflags hidden "$MOUNT_POINT/.background"
/usr/bin/SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true


# ─── Step 4: Write .DS_Store directly via Python ──────────────────────────────
# This is the critical step. All previous approaches used AppleScript to ask
# Finder to write the .DS_Store, which fails when the volume is mounted with
# -nobrowse (as create-dmg does) or when Finder automation permissions are
# restricted (macOS Ventura+).
#
# write_ds_store.py uses the ds_store + mac_alias Python packages to:
#   - Create an HFS alias record for .background/background.png by reading
#     the file's catalog node ID from the live mounted filesystem.
#   - Write a correctly-formatted .DS_Store B-tree with:
#       '.'                    bwsp — window bounds and toolbar flags
#       '.'                    icvp — background image alias + icon size
#       'Neginato Mezora.app'  Iloc — icon centre at (155, 195)
#       'Applications'         Iloc — icon centre at (415, 195)
echo "==> [4/5] Writing .DS_Store (Python, no AppleScript)"
"$DMG_PYTHON" "$WRITE_DS_STORE" "$MOUNT_POINT" "$SHIPPED_APP_NAME"


# ─── Step 6: Flush and unmount ────────────────────────────────────────────────
echo "==> [5/5] Flushing and unmounting"
sync
hdiutil detach "$MOUNT_POINT"


# ─── Convert to read-only compressed DMG ──────────────────────────────────────
echo "==> Converting to read-only DMG"
hdiutil convert \
    "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_OUTPUT"


# ─── Sign the DMG ─────────────────────────────────────────────────────────────
echo "==> Signing DMG: $DMG_OUTPUT"
# --timestamp requests a secure Apple timestamp; notarization and stapling
# require the container's signature to carry one, so it is not optional here.
# NOTE: the ONLY `codesign --sign` target in this script is the DMG container —
# the .app is never re-signed (it arrives deep-signed upstream and only gets a
# stapled ticket in Step 0c).
codesign \
    --force \
    --timestamp \
    --sign "$BB_SIGNING_IDENTITY" \
    "$DMG_OUTPUT"


# ─── Notarize ────────────────────────────────────────────────────────────────
# --wait: block until Apple returns pass/fail (typically 1–5 min)
echo "==> Notarizing (may take several minutes)…"
xcrun notarytool submit \
    "$DMG_OUTPUT" \
    --apple-id "$BB_APPLE_ID" \
    --password "$BB_APP_PASSWORD" \
    --team-id  "$BB_TEAM_ID" \
    --wait


# ─── Staple ──────────────────────────────────────────────────────────────────
# Embeds the ticket so Gatekeeper works offline
echo "==> Stapling"
xcrun stapler staple "$DMG_OUTPUT"


# ─── Pre-ship gate: verify the .app exactly as the user will receive it ───────
# Pre-condition : DMG_OUTPUT is built, signed, notarized, and stapled, and the
#                 .app inside it was stapled in Step 0c.
# Post-condition: aborts unless the .app copied OUT of the finished DMG passes
#                 Gatekeeper (Notarized Developer ID), a strict signature seal
#                 check, and stapler validation — proving it is offline-self-
#                 sufficient, not merely "accepted online on the build machine".
# Defends       : the unstapled-.app regression + post-package tampering / broken
#                 seal. Copying the app out of the read-only DMG reproduces the
#                 user's drag-to-/Applications step.
echo "==> Pre-ship verification gate (app as installed from the DMG)"
VERIFY_DIR="$TEMP_DIR/verify"
mkdir -p "$VERIFY_DIR"
hdiutil detach "$VERIFY_MOUNT" 2>/dev/null || true
hdiutil attach "$DMG_OUTPUT" -mountpoint "$VERIFY_MOUNT" -nobrowse -noautoopen -readonly
cp -R "$VERIFY_MOUNT/$SHIPPED_APP_NAME" "$VERIFY_DIR/"
hdiutil detach "$VERIFY_MOUNT"
VERIFY_APP="$VERIFY_DIR/$SHIPPED_APP_NAME"

# 1) Gatekeeper: must be accepted AND sourced from a notarized Developer ID.
# Capture-then-grep here-strings keep every gate SIGPIPE-safe under pipefail.
GATE_SPCTL="$(spctl -a -t exec -vv "$VERIFY_APP" 2>&1 || true)"
printf '%s\n' "$GATE_SPCTL"
grep -q 'accepted' <<<"$GATE_SPCTL" \
  || { echo "❌  Gatekeeper REJECTED the shipped .app"; exit 1; }
grep -q 'source=Notarized Developer ID' <<<"$GATE_SPCTL" \
  || { echo "❌  shipped .app is not sourced from a Notarized Developer ID"; exit 1; }

# 2) Strict signature seal — catches resource tampering / broken seals.
codesign --verify --deep --strict --verbose=2 "$VERIFY_APP" \
  || { echo "❌  codesign --verify --deep --strict FAILED on the shipped .app"; exit 1; }

# 3) The offline ticket MUST be present on the .app (the root-cause assertion).
xcrun stapler validate "$VERIFY_APP" \
  || { echo "❌  shipped .app has NO stapled ticket — root-cause regression"; exit 1; }

echo "✅  Pre-ship gate passed: shipped .app is notarized, sealed, and stapled."

echo ""
echo "✅  Done → $DMG_OUTPUT"
