#!/usr/bin/env python3
"""Bake MeteoAlarm's warning regions into WeatherCore/Resources/MeteoAlarmRegions.json.

Most MeteoAlarm country feeds (feeds.meteoalarm.org/api/v1) carry no polygon
on a warning, only geocodes naming a region. The app answers "does this
warning cover this place?" by looking the warning's geocode up in a bundled
table and running point-in-polygon on the region it names. This script
builds that table, reproducibly, from pinned public inputs:

  EMMA_ID   MeteoAlarm's own regions, from the geocodes GeoJSON the
            MeteoAlarm PM group publishes on GitLab under a dated name
            (MeteoAlarm_Geocodes_2026_07_31.json: 2006 regions, 30
            countries). MeteoAlarm data: CC BY 4.0, "Data provided by
            EUMETNET members".
  NUTS3     Eurostat GISCO NUTS regions, 1:3 million, EPSG:4326, for the
  NUTS2     feeds that file NUTS codes instead: FR, BG, RO, HR, MK at
            level 3, HU and BE at level 2. "© EuroGeographics for the
            administrative boundaries"; GISCO terms are non-commercial
            and non-transferable (see README.md).

Edition per country follows what the live feeds file (checked 2026-10-26):
France files 2013 codes (FR211, not 2016's FRF21) and Hungary files 2013's
HU10 (split into HU11/HU12 in 2016), so FR, HU, BE, BG, RO come from NUTS
2013. Croatia files 2021 codes (HR027 Karlovacka was HR04D in 2013), so HR
comes from 2021, plus the 2013 codes 2021 no longer carries (no code means
one county in 2013 and another in 2021). North Macedonia files its eight
statistical regions as NUTS3 MK001..MK008 (2021 edition). A region is keyed
by (type, code), so NUTS3/HR031 and EMMA_ID/HR031 never cross.

Rings are split in two halves (so a closed ring keeps its ends) and
simplified with Douglas-Peucker at EPS degrees, then rounded to DECIMALS
places; the size cap is 3 MB. Simplification moves a boundary by at most
EPS (0.004 deg: ~450 m north-south, ~300 m east-west at 45N); a place that
close to a coast or border can miss its region or land in the neighbour -
accepted, never buffered (README.md: Dubrovnik leaves EMMA_ID/HR007 but
stays in NUTS3/HR037).

Modes (Python 3 standard library only):
  (default)        fetch missing inputs into the cache, check their sha256
                   against the pins below, write the resource and
                   scripts/alerts/build_manifest.json.
  --verify         rebuild in memory from the cached inputs and compare
                   bytes with the committed resource; check size < 3 MB,
                   that every EMMA_ID and every NUTS region of the carried
                   countries/editions is present, and that every code the
                   NUTS-coded feeds filed on 2026-10-26 resolves. Exit 1 on
                   any failure.
  --self-check     point-in-polygon on the committed resource: every town in
                   TOWNS must fall inside at least one region of its own
                   country. Exit 1 on any miss.
  --check-feeds D  report geocodes in saved api/v1 feed JSONs (D/*.json)
                   that the table cannot place (informational).

Inputs are cached under $METEOALARM_GEO_CACHE, else
<tempdir>/meteoalarm-geo-inputs - never in the repository.
"""

import argparse
import hashlib
import json
import math
import os
import platform
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MACOS = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(MACOS, "WeatherCore", "Resources", "MeteoAlarmRegions.json")
MANIFEST = os.path.join(HERE, "build_manifest.json")

EPS = 0.004          # Douglas-Peucker tolerance, degrees (2.72 MB; 0.003 is 3.02 MB)
DECIMALS = 4         # coordinate rounding (~11 m)
MAX_BYTES = 3_000_000  # "under 3 MB", read strictly (decimal MB)

MA_CREDIT = "Data provided by EUMETNET members"
GISCO_CREDIT = "© EuroGeographics for the administrative boundaries"
GISCO_URL = ("https://gisco-services.ec.europa.eu/distribution/v2/nuts/geojson/"
             "NUTS_RG_03M_{year}_4326_LEVL_{level}.geojson")

# Pinned inputs. A new edition is a deliberate edit here (URL + sha256),
# never a silent drift: a mismatching download stops the build.
INPUTS = {
    "geocodes": {
        "name": "MeteoAlarm geocodes (EMMA_ID regions)",
        "edition": "2026-07-31",
        "url": "https://gitlab.com/meteoalarm-pm-group/documents/-/raw/master/"
               "MeteoAlarm_Geocodes_2026_07_31.json",
        "file": "MeteoAlarm_Geocodes_2026_07_31.json",
        "sha256": "41ff77fc08cff6b0c8b3f8d56c66f02796b762c3415432a3704b6ca77a8c1ad6",
        "licence": "CC BY 4.0 (MeteoAlarm License, https://creativecommons.org/licenses/by/4.0/)",
        "attribution": MA_CREDIT,
    },
    "nuts3_2013": {
        "name": "Eurostat GISCO NUTS level 3",
        "edition": "NUTS 2013, 1:3 million (03M), EPSG:4326",
        "url": GISCO_URL.format(year=2013, level=3),
        "file": "NUTS_RG_03M_2013_4326_LEVL_3.geojson",
        "sha256": "a860545eb4e3afcd22b6f921bdede3e16a7e20778435ff1c9eceae4e05678120",
        "licence": "Eurostat GISCO: non-commercial, non-exclusive, non-transferable; source must be acknowledged",
        "attribution": GISCO_CREDIT,
    },
    "nuts2_2013": {
        "name": "Eurostat GISCO NUTS level 2",
        "edition": "NUTS 2013, 1:3 million (03M), EPSG:4326",
        "url": GISCO_URL.format(year=2013, level=2),
        "file": "NUTS_RG_03M_2013_4326_LEVL_2.geojson",
        "sha256": "77fa4c28b970a0e5afeba9a44ee23cc872627441e039668cf498a4412c87444f",
        "licence": "Eurostat GISCO: non-commercial, non-exclusive, non-transferable; source must be acknowledged",
        "attribution": GISCO_CREDIT,
    },
    "nuts3_2021": {
        "name": "Eurostat GISCO NUTS level 3",
        "edition": "NUTS 2021, 1:3 million (03M), EPSG:4326",
        "url": GISCO_URL.format(year=2021, level=3),
        "file": "NUTS_RG_03M_2021_4326_LEVL_3.geojson",
        "sha256": "5a5a6cc672c3bc50b51a8d6b9605760dd26322f894624042872fdb9702a50ea4",
        "licence": "Eurostat GISCO: non-commercial, non-exclusive, non-transferable; source must be acknowledged",
        "attribution": GISCO_CREDIT,
    },
}

# (geocode type, country, inputs newest first). An older edition only adds
# the codes the newer ones do not carry.
NUTS = [
    ("NUTS3", "FR", ("nuts3_2013",)),
    ("NUTS3", "BG", ("nuts3_2013",)),
    ("NUTS3", "RO", ("nuts3_2013",)),
    ("NUTS3", "HR", ("nuts3_2021", "nuts3_2013")),
    ("NUTS3", "MK", ("nuts3_2021",)),
    ("NUTS2", "HU", ("nuts2_2013",)),
    ("NUTS2", "BE", ("nuts2_2013",)),
]

# Every NUTS code the NUTS-coded feeds filed on 2026-10-26 (all warnings,
# live and expired, feeds.meteoalarm.org api/v1). --verify requires each to
# resolve, so an edition that stops matching the feeds is caught here.
FEED_CODES_2026_10_26 = {
    "NUTS3": """
        FR101 FR102 FR103 FR104 FR105 FR106 FR107 FR108 FR211 FR212 FR213 FR214
        FR221 FR222 FR223 FR231 FR232 FR241 FR242 FR243 FR244 FR245 FR246 FR251
        FR252 FR253 FR261 FR262 FR263 FR264 FR301 FR302 FR411 FR412 FR413 FR414
        FR421 FR422 FR431 FR432 FR433 FR434 FR511 FR512 FR513 FR514 FR515 FR521
        FR522 FR523 FR524 FR531 FR532 FR533 FR534 FR611 FR612 FR613 FR614 FR615
        FR632 FR633 FR711 FR712 FR713 FR714 FR715 FR716 FR717 FR718 FR721 FR722
        FR723 FR724 FR812 FR813 FR821 FR822 FR823 FR824 FR825 FR826 FR831 FR832
        BG311 BG312 BG313 BG314 BG315 BG321 BG322 BG323 BG324 BG325 BG331 BG332
        BG333 BG334 BG341 BG342 BG343 BG344 BG411 BG412 BG413 BG414 BG415 BG421
        BG422 BG423 BG424 BG425
        RO221 RO222 RO223 RO225 RO312 RO314 RO315
        HR021 HR022 HR023 HR024 HR025 HR026 HR027 HR028 HR031 HR032 HR033 HR034
        HR035 HR036 HR037 HR050 HR061 HR062 HR063 HR064 HR065
        MK001 MK002 MK004 MK005 MK006 MK008
    """.split(),
    "NUTS2": "BE21 BE22 BE23 BE25 BE32 BE33 BE34 BE35 HU10 HU21 HU22 HU23 HU31 HU32 HU33".split(),
    "EMMA_ID": "BE004 BE801 HR801 HR802 HR803 HR804 HR805 HR806".split(),
}

# Coastal, island, lake-shore and border towns: (name, country, lat, lon).
TOWNS = [
    ("Venice", "IT", 45.4371, 12.3326),
    ("Lisbon", "PT", 38.7223, -9.1393),
    ("Valletta", "MT", 35.8989, 14.5146),
    ("Dubrovnik", "HR", 42.6407, 18.1077),
    ("Nice", "FR", 43.7102, 7.2620),
    ("Varna", "BG", 43.2047, 27.9105),
    ("Constanța", "RO", 44.1733, 28.6383),
    ("Ohrid", "MK", 41.1172, 20.8016),
    ("Ostend", "BE", 51.2167, 2.9167),
    ("Siófok", "HU", 46.9041, 18.0580),
    ("Trieste", "IT", 45.6503, 13.7703),
    ("Split", "HR", 43.5081, 16.4402),
    ("Ajaccio", "FR", 41.9267, 8.7369),
    ("Strasbourg", "FR", 48.5734, 7.7521),
    ("Algeciras", "ES", 36.1275, -5.4539),
    ("Cádiz", "ES", 36.5271, -6.2886),
    ("Thessaloniki", "GR", 40.6403, 22.9439),
    ("Gdańsk", "PL", 54.3520, 18.6466),
    ("Klaipėda", "LT", 55.7033, 21.1443),
    ("Copenhagen", "DK", 55.6761, 12.5683),
    ("Galway", "IE", 53.2707, -9.0568),
    ("Kotor", "ME", 42.4247, 18.7712),
    ("Burgas", "BG", 42.5048, 27.4626),
    ("Tulcea", "RO", 45.1716, 28.7914),
    ("Gevgelija", "MK", 41.1392, 22.5025),
    ("Mohács", "HU", 45.9931, 18.6833),
    ("Arlon", "BE", 49.6833, 5.8167),
]


# -- inputs -----------------------------------------------------------------

def cache_dir():
    return os.environ.get("METEOALARM_GEO_CACHE") or os.path.join(
        tempfile.gettempdir(), "meteoalarm-geo-inputs")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_inputs(download):
    """Path of every pinned input in the cache, fetched if missing and allowed;
    raises if a file is missing or its sha256 is not the pinned one."""
    root = cache_dir()
    paths = {}
    for key, spec in INPUTS.items():
        path = os.path.join(root, spec["file"])
        if not os.path.exists(path):
            if not download:
                raise SystemExit(f"missing cached input {path}")
            os.makedirs(root, exist_ok=True)
            print(f"fetching {spec['url']}", file=sys.stderr)
            req = urllib.request.Request(
                spec["url"], headers={"User-Agent": "weather-app/0.1 (github.com/wtp128pro/weather)"})
            with urllib.request.urlopen(req, timeout=300) as r:
                data = r.read()
            with open(path + ".part", "wb") as f:
                f.write(data)
            os.replace(path + ".part", path)
        digest = sha256_of(path)
        if digest != spec["sha256"]:
            raise SystemExit(f"{path}: sha256 {digest} is not the pinned {spec['sha256']} "
                             "(a new upstream edition? update INPUTS deliberately)")
        paths[key] = path
    return paths


def load(paths):
    out = {}
    for key, path in paths.items():
        with open(path, "rb") as f:
            out[key] = json.loads(f.read().decode("utf-8"))
    return out


# -- geometry ---------------------------------------------------------------

def douglas_peucker(pts, eps):
    """Iterative Douglas-Peucker on an open polyline; keeps both ends."""
    n = len(pts)
    if n < 3:
        return list(pts)
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        ax, ay = pts[i]
        bx, by = pts[j]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        dmax, k = -1.0, -1
        for m in range(i + 1, j):
            px, py = pts[m]
            if length == 0.0:
                d = math.hypot(px - ax, py - ay)
            else:
                d = abs(dy * (px - ax) - dx * (py - ay)) / length
            if d > dmax:
                dmax, k = d, m
        if k >= 0 and dmax > eps:
            keep[k] = True
            stack.append((i, k))
            stack.append((k, j))
    return [p for p, f in zip(pts, keep) if f]


def rounded(pts):
    """Round to DECIMALS, drop -0.0 and consecutive (and wrap-around) repeats."""
    out = []
    for x, y in pts:
        p = (round(x, DECIMALS) + 0.0, round(y, DECIMALS) + 0.0)
        if not out or out[-1] != p:
            out.append(p)
    while len(out) > 1 and out[-1] == out[0]:
        out.pop()
    return out


def simplify_ring(ring, eps):
    """A closed ring, simplified as two open halves so its ends survive;
    returned closed ([lon, lat] lists), or None if it has collapsed."""
    pts = [(float(p[0]), float(p[1])) for p in ring]
    if len(pts) > 1 and pts[0] == pts[-1]:
        pts.pop()
    if len(pts) >= 4:
        half = len(pts) // 2
        s = (douglas_peucker(pts[:half + 1], eps)[:-1]
             + douglas_peucker(pts[half:] + [pts[0]], eps)[:-1])
    else:
        s = pts
    out = rounded(s)
    if len(out) < 3:          # a sliver or islet below EPS: keep it unsimplified
        out = rounded(pts)
    if len(out) < 3:
        return None
    return [[x, y] for x, y in out] + [[out[0][0], out[0][1]]]


def simplify_geometry(geom, eps):
    polys = [geom["coordinates"]] if geom["type"] == "Polygon" else geom["coordinates"]
    out = []
    for poly in polys:
        outer = simplify_ring(poly[0], eps)
        if outer is None:
            continue
        holes = [r for r in (simplify_ring(h, eps) for h in poly[1:]) if r is not None]
        out.append([outer] + holes)
    return out


def in_polygon(lon, lat, poly):
    """Even-odd ray cast over a polygon's rings (outer + holes)."""
    inside = False
    for ring in poly:
        j = len(ring) - 1
        for i in range(len(ring)):
            xi, yi = ring[i]
            xj, yj = ring[j]
            if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
                inside = not inside
            j = i
    return inside


# -- build ------------------------------------------------------------------

def build(data, eps=EPS):
    regions = {}

    def add(kind, code, country, name, geom):
        key = (kind, code)
        if key in regions:
            raise SystemExit(f"duplicate region {kind}/{code}")
        polygons = simplify_geometry(geom, eps)
        if not polygons:
            raise SystemExit(f"{kind}/{code} collapsed to nothing at eps={eps}")
        regions[key] = {"type": kind, "code": code, "country": country,
                        "name": name, "polygons": polygons}

    for f in data["geocodes"]["features"]:
        p = f["properties"]
        if p["type"] != "EMMA_ID":
            raise SystemExit(f"unexpected geocode type {p['type']}")
        add("EMMA_ID", p["code"], p["country"], p["name"], f["geometry"])
    for kind, country, keys in NUTS:
        for key in keys:
            for f in data[key]["features"]:
                p = f["properties"]
                if p["CNTR_CODE"] == country and (kind, p["NUTS_ID"]) not in regions:
                    add(kind, p["NUTS_ID"], country, p["NAME_LATN"], f["geometry"])
    sources = [{"name": s["name"], "edition": s["edition"], "url": s["url"],
                "sha256": s["sha256"], "licence": s["licence"],
                "attribution": s["attribution"]} for s in INPUTS.values()]
    doc = {"format": 1,
           "geometry": {"crs": "EPSG:4326", "order": "lon,lat",
                        "simplification": f"Douglas-Peucker {eps} deg, rings split in halves",
                        "decimals": DECIMALS},
           "sources": sources,
           "regions": [regions[k] for k in sorted(regions)]}
    return (json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def expected_codes(data):
    """Every (type, code) the build must carry, from the inputs themselves."""
    want = {("EMMA_ID", f["properties"]["code"]) for f in data["geocodes"]["features"]}
    for kind, country, keys in NUTS:
        for key in keys:
            want |= {(kind, f["properties"]["NUTS_ID"]) for f in data[key]["features"]
                     if f["properties"]["CNTR_CODE"] == country}
    return want


def read_resource():
    with open(OUT, "rb") as f:
        raw = f.read()
    return raw, json.loads(raw.decode("utf-8"))


def summary(doc):
    counts = {}
    for r in doc["regions"]:
        counts.setdefault(r["type"], {}).setdefault(r["country"], 0)
        counts[r["type"]][r["country"]] += 1
    return {t: dict(sorted(c.items())) for t, c in sorted(counts.items())}


def cmd_build(args):
    paths = fetch_inputs(download=True)
    blob = build(load(paths), args.eps)
    if args.dry_run:
        print(f"eps={args.eps}: {len(blob)} bytes (not written)")
        return 0
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(blob)
    manifest = {"python": platform.python_version(),
                "script": "scripts/alerts/build_meteoalarm_regions.py",
                "inputs": [{"file": s["file"], "url": s["url"], "sha256": s["sha256"],
                            "bytes": os.path.getsize(paths[k])} for k, s in INPUTS.items()],
                "output": {"file": "WeatherCore/Resources/MeteoAlarmRegions.json",
                           "bytes": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}}
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"wrote {OUT}: {len(blob)} bytes, sha256 {manifest['output']['sha256']}")
    print(json.dumps(summary(json.loads(blob))))
    return 0


def cmd_verify(args):
    failures = []
    raw, doc = read_resource()
    print(f"resource {len(raw)} bytes (cap {MAX_BYTES})")
    if len(raw) >= MAX_BYTES:
        failures.append(f"resource is {len(raw)} bytes, not under {MAX_BYTES}")
    paths = fetch_inputs(download=args.download)
    data = load(paths)
    rebuilt = build(data)
    if rebuilt != raw:
        failures.append(f"rebuild differs: {len(rebuilt)} bytes, sha256 "
                        f"{hashlib.sha256(rebuilt).hexdigest()} vs {hashlib.sha256(raw).hexdigest()}")
    else:
        print(f"rebuild byte-identical, sha256 {hashlib.sha256(raw).hexdigest()} "
              f"(python {platform.python_version()})")
    have = {(r["type"], r["code"]) for r in doc["regions"]}
    missing = sorted(expected_codes(data) - have)
    if missing:
        failures.append(f"{len(missing)} input regions missing: {missing[:10]}")
    for kind, codes in FEED_CODES_2026_10_26.items():
        gone = [c for c in codes if (kind, c) not in have]
        if gone:
            failures.append(f"feed codes not placed: {kind} {gone}")
    counts = summary(doc)
    for kind, country, _ in NUTS:
        if not counts.get(kind, {}).get(country):
            failures.append(f"no {kind} regions for {country}")
    pinned = sorted(s["sha256"] for s in INPUTS.values())
    if sorted(s.get("sha256") for s in doc.get("sources", [])) != pinned:
        failures.append("resource sources do not record the pinned inputs")
    print(json.dumps(counts))
    for f in failures:
        print("FAIL:", f)
    print("verify:", "FAILED" if failures else "OK")
    return 1 if failures else 0


def cmd_self_check(args):
    _, doc = read_resource()
    by_country = {}
    for r in doc["regions"]:
        by_country.setdefault(r["country"], []).append(r)
    misses = 0
    for name, country, lat, lon in TOWNS:
        hits = [f"{r['type']}/{r['code']}" for r in by_country.get(country, [])
                if any(in_polygon(lon, lat, p) for p in r["polygons"])]
        print(f"{'ok  ' if hits else 'MISS'} {name} ({country}) {lat},{lon}: {' '.join(hits) or '-'}")
        misses += not hits
    print("self-check:", f"FAILED ({misses} of {len(TOWNS)})" if misses else f"OK ({len(TOWNS)} towns)")
    return 1 if misses else 0


def cmd_check_feeds(args):
    _, doc = read_resource()
    have = {(r["type"], r["code"]) for r in doc["regions"]}
    for name in sorted(os.listdir(args.check_feeds)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(args.check_feeds, name), "rb") as f:
            feed = json.loads(f.read().decode("utf-8"))
        unplaced = set()
        for w in feed.get("warnings", []):
            for info in w.get("alert", {}).get("info", []):
                for area in info.get("area", []):
                    if area.get("polygon"):
                        continue
                    codes = {(g.get("valueName"), g.get("value")) for g in area.get("geocode", [])}
                    if codes and not codes & have:
                        unplaced |= codes
        print(f"{name}: {'all placed' if not unplaced else sorted(unplaced)[:12]}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--self-check", action="store_true")
    ap.add_argument("--check-feeds", metavar="DIR")
    ap.add_argument("--no-download", dest="download", action="store_false",
                    help="--verify: fail instead of fetching a missing input")
    ap.add_argument("--dry-run", action="store_true", help="build only, report size")
    ap.add_argument("--eps", type=float, default=EPS, help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.verify:
        return cmd_verify(args)
    if args.self_check:
        return cmd_self_check(args)
    if args.check_feeds:
        return cmd_check_feeds(args)
    return cmd_build(args)


if __name__ == "__main__":
    sys.exit(main())
