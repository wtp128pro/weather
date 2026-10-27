#!/usr/bin/env python3
"""Rebuilds weight_tables.html, the weight tables of the sources-weights help page, from the code.

Run after changing WeatherCore/Blend/Weights.swift (HelpBookTests fails until you do):
    xcodebuild -project Weather.xcodeproj -scheme Weather -derivedDataPath ../build-macos build
    python3 scripts/help/weight_tables.py ../build-macos/Build/Products/Debug
    python3 scripts/help/regenerate.py
"""

from __future__ import annotations
import html
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "weight_tables.html"

VARS = [("temp", "Temperature"), ("wind", "Wind"), ("cloud", "Cloud"), ("humidity", "Humidity"),
        ("precipMm", "Rain amount"), ("precipProb", "Rain chance")]
# WxRegion case -> (name, the places it is used for: WxGeo.region(for:)).
REGIONS = {
    "us": ("United States", "US states and territories (Puerto Rico, US Virgin Islands, Guam, American Samoa, "
           "Northern Mariana Islands), and any place the National Weather Service covers"),
    "canada": ("Canada", "Canada"),
    "ukIreland": ("UK &amp; Ireland", "United Kingdom, Ireland, Isle of Man, Jersey, Guernsey"),
    "beneluxNorthSea": ("Netherlands &amp; Benelux", "Netherlands, Belgium, Luxembourg"),
    "centralEurope": ("Germany &amp; Central Europe", "Germany, Austria, Switzerland, Liechtenstein, Poland, Czechia"),
    "nordic": ("Nordic", "Norway, Sweden, Finland, Denmark, Iceland, Faroe Islands, Svalbard"),
    "europeOther": ("Rest of Europe", "Other places in Europe"),
    "world": ("Rest of the world", "Everywhere else"),
}
# OpenMeteoShared.models(for:): the 15-minute precipitation model of each region.
NOWCAST = {
    "us": "NOAA HRRR (contiguous US only)",
    "canada": "NOAA HRRR in the south; Open-Meteo's best 15-minute model elsewhere",
    "ukIreland": "UK Met Office 2 km",
    "beneluxNorthSea": "KNMI HARMONIE-AROME 2 km",
    "centralEurope": "DWD ICON-D2",
    "nordic": "Open-Meteo's best 15-minute model, south of 65°N and between 11°W and 25°E",
    "europeOther": "Open-Meteo's best 15-minute model, south of 65°N and between 11°W and 25°E",
    "world": "None",
}


def num(x: float) -> str:
    return "%g" % x


def cell(ws: list[float]) -> str:
    return num(ws[0]) if len(set(ws)) == 1 else " / ".join(num(w) for w in ws)


def leaders(rows: list[dict], region: str, bands: list[int]) -> str:
    """The top three temperature models by summed weight over the bands, with each band's weight (one if equal)."""
    rs = [r for r in rows if r["region"] == region and any(r["w"]["temp"][b] > 0 for b in bands)]
    rs.sort(key=lambda r: (-sum(r["w"]["temp"][b] for b in bands), r["id"]))
    return ", ".join(f'{html.escape(r["name"])} ({cell([r["w"]["temp"][b] for b in bands])})' for r in rs[:3])


def tables(rows: list[dict]) -> str:
    out = ['<table>', '    <thead>',
           '        <tr><th>Profile</th><th>Used for</th><th>Leads the first 18 hours (temperature, H0 / H1)</th>'
           '<th>Leads after 3 days</th><th>15-minute rain</th></tr>',
           '    </thead>', '    <tbody>']
    for key, (name, where) in REGIONS.items():
        out.append(f'        <tr><td><strong>{name}</strong></td><td>{where}</td><td>{leaders(rows, key, [0, 1])}</td>'
                   f'<td>{leaders(rows, key, [3])}</td><td>{NOWCAST[key]}</td></tr>')
    out += ['    </tbody>', '</table>']
    out.append('<p>Each table below gives a model\'s weight in the four horizon bands as <code>H0 / H1 / H2 / H3</code> '
               '(one number when all four are equal), before your multipliers. Open a region to see it.</p>')
    for key, (name, _) in REGIONS.items():
        out.append(f'<details>\n<summary><strong>{name}</strong>: every model\'s weights</summary>')
        out += ['<table>', '    <thead>',
                '        <tr><th>Model</th>' + "".join(f"<th>{t}</th>" for _, t in VARS) + '</tr>',
                '    </thead>', '    <tbody>']
        unused = []
        for r in (r for r in rows if r["region"] == key):
            w = r["w"]
            if all(v == 0 for vs in w.values() for v in vs):
                unused.append(html.escape(r["name"]))
                continue
            data = ";".join(v + "=" + ",".join(num(x) for x in w[v]) for v, _ in VARS)
            out.append(f'        <tr data-region="{key}" data-model="{r["id"]}" data-weights="{data}">'
                       f'<td>{html.escape(r["name"])}<br><code>{r["id"]}</code></td>'
                       + "".join(f"<td>{cell(w[v])}</td>" for v, _ in VARS) + "</tr>")
        out += ['    </tbody>', '</table>']
        if unused:
            out.append(f'<p>Not used here (weight 0): {", ".join(unused)}.</p>')
        out.append('</details>')
    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    products = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as tmp:
        exe = Path(tmp) / "dump_weights"
        dump = Path(tmp) / "weights.json"
        subprocess.run(["swiftc", "-swift-version", "6", "-F", str(products), "-framework", "WeatherCore",
                        "-Xlinker", "-rpath", "-Xlinker", str(products), str(HERE / "dump_weights.swift"),
                        "-o", str(exe)], check=True)
        subprocess.run([str(exe), str(dump)], check=True)
        rows = json.loads(dump.read_text(encoding="utf-8"))
    OUTPUT.write_text(tables(rows), encoding="utf-8")
    print(f"Wrote {OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
