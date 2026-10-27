#!/usr/bin/env python3
"""U44 regression tests for scripts/help/validate.py (U26-F1 title check, U26-F3 freshness check).

  python3 -B test_help_validate.py [<macos tree with scripts/help and Weather/NeginatoMezora.help> [<macos tree with Weather/*.swift>]]

Both trees default to $REPO, where REPO defaults to the macos/ directory three levels above this file.
Each case copies the tree to a fresh temp dir (removed afterwards), breaks it, and runs validate.py there;
the trees themselves are only read. Exit 0 = all pass."""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

REPO = Path(os.environ.get("REPO") or Path(__file__).resolve().parents[3])
tree = Path(sys.argv[1] if len(sys.argv) > 1 else REPO).resolve()
swift_tree = Path(sys.argv[2] if len(sys.argv) > 2 else tree).resolve()
LPROJ = Path("Weather/NeginatoMezora.help/Contents/Resources/en.lproj")
if not (tree / LPROJ).is_dir() or not (tree / "scripts/help/validate.py").is_file():
    sys.exit(f"{tree} has no {LPROJ} or scripts/help/validate.py")
# Every bundled page but the shell template carries its own <title>; strip_titles removes them all.
N_PAGES = sum(1 for p in (tree / LPROJ).glob("*.html") if p.name != "_shell.html")
failed = 0

def run(name, mutate, want_exit, want_msgs):
    global failed
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        shutil.copytree(swift_tree / "Weather", root / "Weather", ignore=shutil.ignore_patterns("NeginatoMezora.help"))
        shutil.copytree(tree / "Weather/NeginatoMezora.help", root / "Weather/NeginatoMezora.help")
        shutil.copytree(tree / "scripts/help", root / "scripts/help", ignore=shutil.ignore_patterns("__pycache__"))
        mutate(root)
        r = subprocess.run([sys.executable, "-B", str(root / "scripts/help/validate.py")], capture_output=True, text=True)
        out = r.stdout + r.stderr
        counts = {m: out.count(m) for m in want_msgs}
        ok = r.returncode == want_exit and all(counts[m] == n for m, n in want_msgs.items())
        failed += not ok
        print(f"{'PASS' if ok else 'FAIL'} {name}: exit {r.returncode}, counts {counts}" + ("" if ok else f" (want exit {want_exit}, {want_msgs}); tail {out.strip().splitlines()[-1:]}"))

def edit(rel, fn):
    def mutate(root):
        p = root / rel
        p.write_text(fn(p.read_text(encoding="utf-8")), encoding="utf-8")
    return mutate

def strip_titles(root):
    for p in (root / LPROJ).glob("*.html"):
        if p.name != "_shell.html":
            p.write_text(re.sub(r"<title>.*?</title>", "", p.read_text(encoding="utf-8"), count=1), encoding="utf-8")

run("pristine", lambda root: None, 0, {})
# U26-F1: every page losing its own <title> must be reported (the nav lists every title, so the old check never fired).
# (14 pages when the fix landed; the count follows the bundle.)
run("f1_titles_removed", strip_titles, 1, {"does not contain its title": N_PAGES})
run("f1_wrong_title", edit(LPROJ / "places.html", lambda t: t.replace("<title>Adding &amp; Managing Places", "<title>Places")),
    1, {"Page places.html does not contain its title": 1})
# U26-F3: a hand edit of a bundled page, or a generator edit without regenerate.py, must be reported.
run("f3_hand_edit_page", edit(LPROJ / "sources-weights.html", lambda t: t.replace("HRRR stops after 48 hours", "HRRR stops after 36 hours")),
    1, {"Stale Weather/NeginatoMezora.help/Contents/Resources/en.lproj/sources-weights.html": 1})
run("f3_pages_py_not_regenerated", edit(Path("scripts/help/pages.py"), lambda t: t.replace("HRRR stops after 48 hours", "HRRR stops after 36 hours")),
    1, {"Stale Weather/NeginatoMezora.help/Contents/Resources/en.lproj/sources-weights.html": 1,
        "Stale Weather/NeginatoMezora.help/Contents/Resources/en.lproj/search-index.js": 1})
run("f3_weight_tables_not_regenerated", edit(Path("scripts/help/weight_tables.html"), lambda t: t.replace("Leads after 3 days", "Leads after 4 days")),
    1, {"Stale Weather/NeginatoMezora.help/Contents/Resources/en.lproj/sources-weights.html": 1})
print(f"{'OK' if not failed else 'FAILED'}: {failed} failed")
sys.exit(1 if failed else 0)
