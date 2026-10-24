#!/usr/bin/env bash
# =============================================================================
# Weather — Private Python Environment for the DMG Layout Step
# =============================================================================
#
# USAGE (sourced, not executed)
#   source "$SCRIPT_DIR/scripts/dmg_python.sh"
#   ensure_dmg_python || exit 1
#   "$DMG_PYTHON" scripts/dmg_assets/write_ds_store.py <mount_point>
#
#   Sourced by build.sh as a fail-fast preflight (BEFORE the multi-minute
#   archive + export) and by scripts/build_dmg.sh (so it also works standalone;
#   the second call just reuses the environment the first one provisioned).
#
# WHY A PRIVATE VIRTUALENV
#   write_ds_store.py needs the third-party ds_store + mac_alias packages.
#   Installing them into "the" python3 breaks in two ways:
#     - A Homebrew Python upgrade (e.g. 3.14 → 3.15) swaps the interpreter
#       behind `python3`. Packages installed for the old version are left behind
#       in its site-packages, invisible to the new one, and the release build
#       fails at its very last step.
#     - Homebrew's Python is EXTERNALLY-MANAGED (PEP 668), so a plain
#       `pip3 install ds_store mac_alias` into it is refused anyway.
#   A dedicated venv avoids both. It is rebuilt automatically whenever it can no
#   longer import the pinned packages — e.g. its base interpreter was upgraded
#   away — so a Python upgrade costs one short re-provision, not a failed build.
#
# PINNED VERSIONS
#   ds_store 1.3.3 + mac_alias 2.2.3 — the versions the shipped DMG layouts were
#   written with, so the generated .DS_Store does not drift with upstream
#   releases. Changing a pin here re-provisions the venv on the next run.
#
# OVERRIDES
#   WEATHER_DMG_VENV   Location of the venv
#                      (default: ~/Library/Caches/Weather/dmg-python).
#   Network access is needed only when the venv is (re)provisioned.
# =============================================================================

DMG_PYTHON_VENV="${WEATHER_DMG_VENV:-$HOME/Library/Caches/Weather/dmg-python}"
DMG_PYTHON_PACKAGES=("ds_store==1.3.3" "mac_alias==2.2.3")


# ─── dmg_python_ready ─────────────────────────────────────────────────────────
# Pre-condition:  none
# Post-condition: none (read-only probe; nothing is created or modified)
# Returns:        0 iff the venv's interpreter exists, runs, and has EXACTLY the
#                 pinned package versions installed and importable; non-zero
#                 otherwise (missing venv, dangling interpreter after a Python
#                 upgrade, missing package, or a version that no longer matches
#                 a pin).
dmg_python_ready() {
    local py="$DMG_PYTHON_VENV/bin/python3"
    [[ -x "$py" ]] || return 1
    # importlib.metadata reports the INSTALLED distribution version, so a pin
    # change is detected as well as a missing or unimportable package.
    "$py" - "${DMG_PYTHON_PACKAGES[@]}" <<'PY' 2>/dev/null
import importlib.metadata, sys
import ds_store, mac_alias
for pin in sys.argv[1:]:
    name, version = pin.split("==")
    if importlib.metadata.version(name) != version:
        sys.exit(1)
PY
}


# ─── ensure_dmg_python ────────────────────────────────────────────────────────
# Pre-condition:  a `python3` with the standard `venv` module is on PATH (only
#                 needed when the venv must be (re)built); network access to
#                 PyPI in that same case.
# Post-condition: on success, DMG_PYTHON is exported and names an interpreter
#                 that imports the pinned ds_store + mac_alias. An unusable venv
#                 is deleted and rebuilt from scratch — but only a directory that
#                 is recognisably a venv (has pyvenv.cfg) is ever deleted, so a
#                 mistyped WEATHER_DMG_VENV can never remove unrelated files.
# Returns:        0 on success; 1 with an actionable message on stderr otherwise.
ensure_dmg_python() {
    if ! dmg_python_ready; then
        _provision_dmg_python || return 1
    fi
    DMG_PYTHON="$DMG_PYTHON_VENV/bin/python3"
    export DMG_PYTHON
}


# ─── _provision_dmg_python ────────────────────────────────────────────────────
# Pre-condition:  dmg_python_ready just returned non-zero.
# Post-condition: on success, DMG_PYTHON_VENV holds a fresh venv with exactly
#                 the pinned packages and dmg_python_ready returns 0.
# Returns:        0 on success; 1 with a message on stderr otherwise.
_provision_dmg_python() {
    local base
    base="$(command -v python3 || true)"
    if [[ -z "$base" ]]; then
        echo "❌  python3 not found — install it (e.g. brew install python) and re-run." >&2
        return 1
    fi
    if [[ -e "$DMG_PYTHON_VENV" && ! -f "$DMG_PYTHON_VENV/pyvenv.cfg" ]]; then
        echo "❌  $DMG_PYTHON_VENV exists but is not a Python venv; refusing to replace it." >&2
        echo "    Remove it, or point WEATHER_DMG_VENV somewhere else." >&2
        return 1
    fi

    echo "==> Provisioning the DMG Python environment (first run, or after a Python upgrade)"
    echo "    $("$base" --version 2>&1) at $base → $DMG_PYTHON_VENV"
    rm -rf "${DMG_PYTHON_VENV:?}"
    mkdir -p "$(dirname "$DMG_PYTHON_VENV")"
    if ! "$base" -m venv "$DMG_PYTHON_VENV"; then
        echo "❌  '$base -m venv' failed — this python3 lacks the venv module." >&2
        return 1
    fi
    if ! "$DMG_PYTHON_VENV/bin/python3" -m pip install --quiet --disable-pip-version-check \
            "${DMG_PYTHON_PACKAGES[@]}"; then
        echo "❌  Could not install ${DMG_PYTHON_PACKAGES[*]} into $DMG_PYTHON_VENV." >&2
        echo "    This step needs network access to PyPI (only when provisioning)." >&2
        return 1
    fi
    if ! dmg_python_ready; then
        echo "❌  $DMG_PYTHON_VENV was provisioned but still cannot import the pinned packages." >&2
        return 1
    fi
    echo "    ✅ ${DMG_PYTHON_PACKAGES[*]}"
}
