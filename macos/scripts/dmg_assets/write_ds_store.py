#!/usr/bin/env python3
"""
Writes a .DS_Store file for the Neginato Mezora DMG installer window.

Must be called while the RW DMG image is mounted, because:
  - mac_alias reads the background file's HFS catalog node ID (inode) and
    the volume's creation timestamp to build a self-contained alias record.
    These values are only accessible on a live, mounted HFS+ filesystem.
  - The alias must be written before the volume is unmounted and converted
    to the final read-only UDZO image.

Usage:
    python3 write_ds_store.py <mount_point> [app_bundle_name]

    <mount_point>      Absolute path to the mounted RW DMG volume,
                       e.g. /Volumes/NeginatoMezora-build.
    [app_bundle_name]  Bundle directory name inside the DMG
                       (default: "Neginato Mezora.app").

Requires:
    ds_store + mac_alias. build_dmg.sh runs this with the private venv from
    scripts/dmg_python.sh, which provisions the pinned versions automatically.

Pre-conditions:
    - <mount_point>/.background/background.png must exist.
    - <mount_point>/Neginato Mezora.app must exist (or be a symlink).
    - <mount_point>/Applications symlink must exist.

Post-condition:
    - <mount_point>/.DS_Store is written (or overwritten) with:
        '.'                    bwsp  — window position and toolbar flags
        '.'                    icvp  — icon view: background image, icon size, no arrangement
        'Neginato Mezora.app'  Iloc  — icon centre at (155, 195)
        'Applications'         Iloc  — icon centre at (415, 195)
"""

import os
import sys

# ─── Dependency check ─────────────────────────────────────────────────────────

try:
    from ds_store import DSStore
    from mac_alias import Alias
except ImportError:
    sys.exit(
        "Missing dependencies — run this via build_dmg.sh, or with the interpreter from\n"
        "scripts/dmg_python.sh (source it, run ensure_dmg_python, then use $DMG_PYTHON)."
    )


# ─── Layout constants ──────────────────────────────────────────────────────────
# These must match the arrow drawn in background.png (560 × 400).
# Coordinates are Finder icon-centre positions within the window.

APP_X, APP_Y   = 155, 195   # Neginato Mezora.app — left drop zone
APPS_X, APPS_Y = 415, 195   # Applications symlink — right drop zone
DEFAULT_APP_BUNDLE = "Neginato Mezora.app"

# Window: top-left at (100, 100) on screen, 560 px wide × 400 px tall
WIN_BOUNDS = "{{100, 100}, {560, 400}}"


# ─── Entry builders ────────────────────────────────────────────────────────────

def build_bwsp() -> dict:
    """
    Build the Browser Window State Properties plist dict.

    Hides toolbar, sidebar, and status bar so the installer window is clean.

    Returns:
        dict suitable for DSStore.d['.']['bwsp'] assignment.
    """
    return {
        "ContainerShowSidebar": False,
        "ShowSidebar":          False,
        "ShowStatusBar":        False,
        "ShowTabView":          False,
        "ShowToolbar":          False,
        "WindowBounds":         WIN_BOUNDS,
    }


def build_icvp(alias_bytes: bytes) -> dict:
    """
    Build the Icon View Properties plist dict for a picture background.

    Parameters:
        alias_bytes  Raw bytes of the macOS AliasManager alias record
                     pointing to .background/background.png on the volume.
                     Produced by Alias.for_file(...).to_bytes().

    Returns:
        dict suitable for DSStore.d['.']['icvp'] assignment.
        backgroundType=2 tells Finder to use the alias as the background image.
    """
    return {
        "arrangeBy":            "none",
        "backgroundColorBlue":  1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed":   1.0,
        "backgroundImageAlias": alias_bytes,   # bytes → stored as plist <data>
        "backgroundType":       2,             # 0=default 1=colour 2=picture
        "gridOffsetX":          0.0,
        "gridOffsetY":          0.0,
        "gridSpacing":          100.0,
        "iconSize":             128.0,
        "labelOnBottom":        True,
        "showIconPreview":      True,
        "showItemInfo":         False,
        "textSize":             12.0,
        "viewOptionsVersion":   1,
    }


# ─── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(f"Usage: {sys.argv[0]} <mount_point> [app_bundle_name]")

    mount = sys.argv[1].rstrip("/")
    app_bundle = sys.argv[2] if len(sys.argv) >= 3 else DEFAULT_APP_BUNDLE
    bg_path = os.path.join(mount, ".background", "background.png")
    app_path = os.path.join(mount, app_bundle)
    ds_path = os.path.join(mount, ".DS_Store")

    # Validate inputs
    if not os.path.isfile(bg_path):
        sys.exit(f"Error: background not found at {bg_path}")
    if not os.path.exists(app_path):
        sys.exit(f"Error: app bundle not found at {app_path}")

    print(f"  mount     : {mount}")
    print(f"  app       : {app_bundle}")
    print(f"  background: {bg_path}")
    print(f"  .DS_Store : {ds_path}")

    # Build the alias record while the volume is mounted.
    # mac_alias reads the file's HFS catalog node ID and the volume's
    # creation timestamp from the live filesystem via getattrlist(2).
    # This is the only time we can obtain these values.
    print("  Creating alias record...")
    alias = Alias.for_file(bg_path)
    alias_bytes = alias.to_bytes()

    # Remove any pre-existing .DS_Store so we write a completely fresh one.
    # A stale .DS_Store (e.g. from a previous failed build) can override our
    # settings via the B-tree merge rules in ds_store.
    if os.path.exists(ds_path):
        os.remove(ds_path)

    print("  Writing .DS_Store...")
    with DSStore.open(ds_path, "w+") as d:
        # '.' is the sentinel key for the container directory's own attributes.
        # This is confirmed by inspecting real Finder-written .DS_Store files.
        d["."]["bwsp"] = build_bwsp()
        d["."]["icvp"] = build_icvp(alias_bytes)

        # Icon positions: (x, y) tuples encoded by ILocCodec as
        # struct.pack(">IIII", x, y, 0xFFFFFFFF, 0xFFFF0000).
        d[app_bundle]["Iloc"] = (APP_X, APP_Y)
        d["Applications"]["Iloc"] = (APPS_X, APPS_Y)

    print("  Done.")


if __name__ == "__main__":
    main()
