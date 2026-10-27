#!/usr/bin/env python3
"""U44 regression tests for the Help Book generators (U26-F2 weight_tables.py, U26-F5 pages.py).

  python3 -B test_help_generators.py [scripts/help dir]

The default directory is $REPO/scripts/help, where REPO defaults to the macos/ directory three levels
above this file. The generators are imported, not run: nothing is written (bytecode included).
Exit 0 = all pass, 1 = a case failed."""
import os, re, sys
from pathlib import Path
sys.dont_write_bytecode = True  # never leave __pycache__ in the scanned tree
REPO = Path(os.environ.get("REPO") or Path(__file__).resolve().parents[3])
help_dir = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "scripts" / "help").resolve()
if not (help_dir / "weight_tables.py").is_file():
    sys.exit(f"no weight_tables.py in {help_dir}")
sys.path.insert(0, str(help_dir))
import weight_tables, pages  # noqa: E402

failed = 0

def check(name, ok, detail):
    global failed
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")

def row(region, mid, name, temp):
    zero = [0.0] * 4
    return {"region": region, "id": mid, "name": name, "w": {v: (temp if v == "temp" else zero) for v, _ in weight_tables.VARS}}

def summary(rows, region_name):
    m = re.search(rf"<tr><td><strong>{re.escape(region_name)}</strong></td><td>[^<]*</td><td>([^<]*)</td><td>([^<]*)</td>",
                  weight_tables.tables(rows))
    return m.groups() if m else (None, None)

# U26-F2: the "first 18 hours" column covers H0 (0-3 h) and H1 (3-18 h), not H0 alone.
us = [row("us", "nws:nws", "NWS", [4, 4, 4.5, 5]), row("us", "open-meteo:hrrr", "HRRR", [3, 3, 0.5, 0]),
      row("us", "open-meteo:nbm", "NBM", [2.5, 3, 3, 2])]
first18, after3d = summary(us, "United States")
check("f2_h1_weight_shown", first18 == "NWS (4), HRRR (3), NBM (2.5 / 3)", f"first 18 h {first18!r}")
check("f2_after_3_days_unchanged", after3d == "NWS (5), NBM (2)", f"after 3 days {after3d!r}")
# A model that leads only from hour 3 to 18 is among the 18-hour leaders.
late = [row("canada", "a:a", "A", [2, 2, 2, 2]), row("canada", "b:b", "B", [2, 2, 2, 2]), row("canada", "c:c", "C", [2, 2, 2, 2]),
        row("canada", "x:x", "X", [1, 6, 0, 0])]
first18, _ = summary(late, "Canada")
check("f2_h1_leader_listed", first18 == "X (1 / 6), A (2), B (2)", f"first 18 h {first18!r}")
check("f2_header_names_bands", "<th>Leads the first 18 hours (temperature, H0 / H1)</th>" in weight_tables.tables(us), "header")

# U26-F5: HRRR and NBM are weighted (and fetched) in southern Canada, not only in the US.
body = pages.PAGE_BODIES["sources-weights"]
check("f5_old_claim_gone", "Models that only run in the US (NWS, HRRR, NBM) weigh 0 elsewhere" not in body, "weigh-0 sentence")
check("f5_weigh_0_scoped", "NWS outside the US, HRRR and NBM outside the US and southern Canada" in body, "weigh-0 sentence")
check("f5_open_meteo_row", "and in the US and southern Canada NOAA HRRR and the National Blend of Models (NBM)" in body, "Open-Meteo row")
print(f"{'OK' if not failed else 'FAILED'}: {failed} failed")
sys.exit(1 if failed else 0)
