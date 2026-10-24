#!/usr/bin/env python3
"""Regenerates the bundled NeginatoMezora.help HTML Help Book and search index."""

from __future__ import annotations
import json
from pathlib import Path
from _helplib import CONTENTS_DIR, EN_LPROJ, SECTIONS, all_pages, strip_html

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.wtp128pro.Weather.help</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Neginato Mezora Help</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleSignature</key>
    <string>hbwr</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>HPDBookAccessPath</key>
    <string>index.html</string>
    <key>HPDBookTitle</key>
    <string>Neginato Mezora Help</string>
    <key>HPDBookType</key>
    <string>3</string>
</dict>
</plist>
"""

BOOK_CSS = """
:root {
    color-scheme: dark;
    --bg: #0f172a;
    --sidebar-bg: #111c33;
    --card-bg: #1e293b;
    --border: rgba(255, 255, 255, 0.12);
    --text: #f8fafc;
    --muted: #94a3b8;
    --accent: #38bdf8;
    --amber: #fb923c;
}
* { box-sizing: border-box; }
body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.6;
}
.help-layout {
    display: grid;
    grid-template-columns: 260px 1fr;
    min-height: 100vh;
}
.help-sidebar {
    background: var(--sidebar-bg);
    border-right: 1px solid var(--border);
    padding: 18px 14px;
    position: sticky;
    top: 0;
    height: 100vh;
    overflow-y: auto;
}
.brand {
    font-size: 15px;
    font-weight: 700;
    color: var(--text);
    margin-bottom: 12px;
    display: flex;
    align-items: center;
    gap: 8px;
}
.search-input {
    width: 100%;
    padding: 7px 10px;
    border-radius: 7px;
    border: 1px solid var(--border);
    background: rgba(15, 23, 42, 0.75);
    color: var(--text);
    font-size: 13px;
    margin-bottom: 14px;
}
.nav-section {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted);
    margin: 14px 6px 6px;
}
.nav-link {
    display: block;
    padding: 6px 10px;
    border-radius: 6px;
    color: var(--text);
    text-decoration: none;
    font-size: 13px;
    margin-bottom: 2px;
}
.nav-link:hover { background: rgba(56, 189, 248, 0.12); }
.nav-link.active {
    background: rgba(56, 189, 248, 0.22);
    color: var(--accent);
    font-weight: 600;
}
.help-main {
    padding: 32px 44px 64px;
    max-width: 880px;
}
h1 { font-size: 26px; margin-top: 0; letter-spacing: -0.01em; }
h2 { font-size: 19px; margin-top: 28px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
h3 { font-size: 15px; margin-top: 20px; color: var(--accent); }
p, li { font-size: 14px; color: #e2e8f0; }
code, pre {
    font-family: "SF Mono", Menlo, monospace;
    background: rgba(15, 23, 42, 0.75);
    border: 1px solid var(--border);
    border-radius: 5px;
}
code { padding: 1px 5px; font-size: 12.5px; }
pre { padding: 12px 14px; overflow-x: auto; font-size: 12.5px; }
table {
    width: 100%;
    border-collapse: collapse;
    margin: 14px 0 20px;
    font-size: 13px;
    background: var(--card-bg);
    border-radius: 8px;
    overflow: hidden;
}
th, td {
    padding: 8px 11px;
    border-bottom: 1px solid var(--border);
    text-align: left;
}
th { background: rgba(255, 255, 255, 0.05); color: var(--accent); font-weight: 600; }
.callout {
    background: var(--card-bg);
    border-left: 3px solid var(--accent);
    padding: 12px 16px;
    border-radius: 6px;
    margin: 16px 0;
}
.callout.amber { border-left-color: var(--amber); }
.search-results {
    margin-bottom: 14px;
    display: none;
}
.search-results.visible { display: block; }
.search-hit {
    display: block;
    padding: 7px 9px;
    border-radius: 6px;
    background: var(--card-bg);
    margin-bottom: 6px;
    text-decoration: none;
    color: var(--text);
    font-size: 12.5px;
    border: 1px solid var(--border);
}
.search-hit strong { color: var(--accent); display: block; }
"""

HELP_JS = """
(function() {
    const input = document.getElementById('help-search');
    const resultsBox = document.getElementById('search-results');
    if (!input || !resultsBox || !window.HELP_SEARCH_INDEX) return;

    input.addEventListener('input', function() {
        const q = input.value.trim().toLowerCase();
        resultsBox.innerHTML = '';
        if (q.length < 2) {
            resultsBox.classList.remove('visible');
            return;
        }
        const hits = window.HELP_SEARCH_INDEX.filter(item =>
            item.title.toLowerCase().includes(q) || item.body.toLowerCase().includes(q)
        );
        if (hits.length === 0) {
            resultsBox.innerHTML = '<div class="search-hit">No matching topics found.</div>';
        } else {
            hits.forEach(hit => {
                const a = document.createElement('a');
                a.className = 'search-hit';
                a.href = hit.href;
                a.innerHTML = '<strong>' + hit.title + '</strong><span>' + hit.section + '</span>';
                resultsBox.appendChild(a);
            });
        }
        resultsBox.classList.add('visible');
    });
})();
"""

PAGE_BODIES: dict[str, str] = {
    "index": """
<h1>Welcome to Neginato Mezora</h1>
<p><strong>Neginato Mezora</strong> is a native macOS meteorological workstation and hyper-local precipitation nowcasting application. It synthesizes up to <strong>10 numerical weather prediction (NWP) models</strong> from three free upstream providers (<code>Open-Meteo</code>, <code>NOAA National Weather Service</code>, and <code>MET Norway</code>) and fuses them with real-time physical airport METARs, 90m DEM surface analysis, and US EPA AirNow air quality monitors.</p>

<div class="callout">
    <strong>Quick Navigation</strong>
    <ul>
        <li><a href="rain-chart.html" style="color:#38bdf8;">Rain Graph &amp; Bars Guide</a> — Understand what the cyan bars (Rain rate, left axis) and amber-rose curve (Rain chance %, right axis) represent.</li>
        <li><a href="sources-weights.html" style="color:#38bdf8;">Settings: Data Sources &amp; Weights (⌘,)</a> — Configure enabled providers and adjust per-source and per-model blend weights.</li>
        <li><a href="algorithms.html" style="color:#38bdf8;">Ensemble Blending &amp; Citations</a> — Full mathematical formulas, horizon weight tables, and academic references.</li>
        <li><a href="live-stations.html" style="color:#38bdf8;">Live Station 3D Assimilation</a> — How nearby physical weather stations and air quality sensors are fused in real time.</li>
    </ul>
</div>

<h2>Key Features at a Glance</h2>
<table>
    <thead>
        <tr><th>Feature</th><th>Description</th></tr>
    </thead>
    <tbody>
        <tr><td><strong>Labeled Dual-Series Rain Charts</strong></td><td>Side-by-side <em>Next 2 hours</em> (15-minute HRRR nowcast bars) and <em>Next 24 hours</em> (hourly bars + probability curve) with explicit series pills, left/right axis labels, peak callout badges, and interactive hover inspection.</td></tr>
        <tr><td><strong>Configurable Ensemble Weights</strong></td><td>Open <strong>Settings (⌘,)</strong> to enable/disable providers and tune blend multipliers (<code>0.00×</code> to <code>3.00×</code>) per source and per NWP model.</td></tr>
        <tr><td><strong>3D Live Station Assimilation</strong></td><td>Blends up to 16 NOAA/FAA AviationWeather METAR stations within 95 km using horizontal Cauchy-Gaussian and vertical Gaussian kernels, lapse-rate elevation correction, Shepard angular de-clustering, and MAD outlier QC.</td></tr>
        <tr><td><strong>Street-Address &amp; Pin Geocoding</strong></td><td>Search any street address, postal code, city, or raw <code>lat, lon</code> coordinates via 5 parallel geocoders or drop a pin on the interactive Apple Map.</td></tr>
    </tbody>
</table>
""",
    "rain-chart": """
<h1>Rain Graph &amp; Bars Guide</h1>
<p>The <strong>Rain</strong> card in the detail pane displays up to two charts side-by-side: <strong>Next 2 hours</strong> (15-minute intervals, shown for US locations with HRRR sub-hourly coverage) and <strong>Next 24 hours</strong> (hourly intervals). Each visual series is explicitly labeled in the header legend and on the axes.</p>

<div class="callout">
    <strong>Bars = Rain Rate (Intensity, Left Axis)</strong><br>
    The vertical aqua-to-cobalt bars show <em>how hard it is expected to rain</em> in <code>in/h</code> (Imperial) or <code>mm/h</code> (Metric). Read bar heights against the <strong>Left Y-Axis</strong> (labeled <code>Rate · 0.10 in/h</code> / <code>2.5 mm/h</code> at the top, half-scale at the middle dashed line, and <code>0</code> at the baseline).
</div>

<div class="callout amber">
    <strong>Curve = Rain Chance (Probability %, Right Axis)</strong><br>
    On the 24-hour chart, the smooth amber-rose curve with glowing circular nodes shows <em>how likely measurable rain (&ge; 0.1 mm/h) is</em> during each hour, from <code>0%</code> to <code>100%</code>. Read the curve against the <strong>Right Y-Axis</strong> (labeled <code>100%</code> at top, <code>50%</code> at midline, and <code>0%</code> at bottom).
</div>

<h2>Reading On-Chart Callouts &amp; Hover Inspection</h2>
<ul>
    <li><strong>Peak Bar Badges:</strong> Up to two highest non-zero bars display a cyan badge directly above the bar cap showing the exact precipitation rate (e.g., <code>0.08 in/h</code> or <code>1.5 mm/h</code>).</li>
    <li><strong>Peak Chance Badge:</strong> The highest probability hour on the 24-hour curve displays an amber-rose badge (e.g., <code>Peak 80%</code>).</li>
    <li><strong>Interactive Hover Readout:</strong> Move the pointer across any time slot on either chart to reveal a vertical guide line and a floating summary banner at the top of the plot: <code>3:00 PM · Bar: 0.06 in/h · Chance: 70%</code>.</li>
</ul>

<h2>Precipitation Intensity Classification</h2>
<table>
    <thead>
        <tr><th>Category</th><th>Metric Rate (mm/h)</th><th>Imperial Rate (in/h)</th><th>Physical Description</th></tr>
    </thead>
    <tbody>
        <tr><td><strong>Dry / Trace</strong></td><td><code>&lt; 0.1 mm/h</code></td><td><code>&lt; 0.004 in/h</code></td><td>No measurable accumulation.</td></tr>
        <tr><td><strong>Light Rain</strong></td><td><code>0.1 – 2.5 mm/h</code></td><td><code>0.004 – 0.10 in/h</code></td><td>Individual drops easily identified; small puddles form slowly.</td></tr>
        <tr><td><strong>Moderate Rain</strong></td><td><code>2.5 – 7.6 mm/h</code></td><td><code>0.10 – 0.30 in/h</code></td><td>Rapid puddle formation; visible spray off roofs and pavement.</td></tr>
        <tr><td><strong>Heavy Rain</strong></td><td><code>&ge; 7.6 mm/h</code></td><td><code>&ge; 0.30 in/h</code></td><td>Sheets of rain; rapid runoff and reduced visibility.</td></tr>
    </tbody>
</table>
""",
    "sources-weights": """
<h1>Settings: Data Sources &amp; Weights</h1>
<p>Open the <strong>Neginato Mezora Settings</strong> dialogue at any time by pressing <code>⌘,</code>, clicking the <strong>gear (⚙)</strong> button in the top-right window toolbar, or choosing <strong>Neginato Mezora &gt; Settings…</strong> from the menu bar.</p>

<h2>Tab 1: Sources</h2>
<p>The <strong>Sources</strong> tab controls which upstream weather providers participate in forecast refreshes and sets each provider's overall blend weight multiplier:</p>
<ul>
    <li><strong>Open-Meteo (<code>open-meteo</code>):</strong> Supplies up to 8 NWP models (NOAA HRRR 3 km + 15-min Nowcast, NOAA NBM, ECMWF IFS, NOAA GFS, DWD ICON, ECCC GEM, UK Met Office, and Météo-France). Licensed under CC BY 4.0.</li>
    <li><strong>National Weather Service (<code>nws</code>):</strong> Official NOAA human-forecaster 2.5 km NDFD grid for the United States, Puerto Rico, US Virgin Islands, Guam, and American Samoa. US Government public domain work.</li>
    <li><strong>MET Norway (<code>met-no</code>):</strong> Norwegian Meteorological Institute Locationforecast 2.0 (1 km Nordic MEPS + global ECMWF IFS). Licensed under CC BY 4.0 / NLOD.</li>
</ul>
<p>Each source row includes a <strong>Source weight multiplier</strong> slider (<code>0.10×</code> to <code>3.00×</code>, default <code>1.00×</code>) that scales all models belonging to that provider.</p>

<h2>Tab 2: Weights &amp; Model Matrix</h2>
<p>The <strong>Weights</strong> tab lets you inspect the baseline heuristic weight table across all 6 variable groups (<code>Temperature</code>, <code>Wind</code>, <code>Cloud Cover</code>, <code>Humidity</code>, <code>Precipitation Amount</code>, <code>Precipitation Chance</code>) and adjust individual multipliers (<code>0.00×</code> to <code>3.00×</code>) for every NWP model.</p>

<h3>Baseline US Horizon Band Weights (H0: 0–3h, H1: 3–18h, H2: 18–72h, H3: 72h+)</h3>
<table>
    <thead>
        <tr><th>Model</th><th>Temp [H0..H3]</th><th>Wind</th><th>Cloud</th><th>Humidity</th><th>Precip mm [H0..H3]</th><th>Precip %</th></tr>
    </thead>
    <tbody>
        <tr><td><code>nws:nws</code></td><td>4.0, 4.0, 4.5, 5.0</td><td>3.0</td><td>3.0</td><td>1.0</td><td>2.0, 3.0, 4.0, 4.0</td><td>5.0</td></tr>
        <tr><td><code>open-meteo:hrrr</code> (&le;48h)</td><td>3.0, 3.0, 0.5, 0.0</td><td>3.0, 3.0, 0.5, 0.0</td><td>2.0, 2.0, 0.5, 0.0</td><td>1, 1, 1, 0</td><td>4.0, 4.0, 1.0, 0.0</td><td>1, 1, 1, 0</td></tr>
        <tr><td><code>open-meteo:nbm</code></td><td>2.5, 3.0, 3.0, 2.0</td><td>2.0</td><td>2.0</td><td>1.0</td><td>2.0</td><td>2.0</td></tr>
        <tr><td><code>open-meteo:ecmwf</code></td><td>1.0, 1.5, 2.0, 2.0</td><td>1.5</td><td>1.5</td><td>1.0</td><td>1.0, 2.0, 2.5, 2.5</td><td>1.0</td></tr>
        <tr><td><code>open-meteo:icon</code></td><td>0.5, 1.0, 1.0, 1.0</td><td>1.0</td><td>1.0</td><td>1.0</td><td>1.0, 1.0, 1.5, 1.5</td><td>1.0</td></tr>
        <tr><td><code>open-meteo:gfs</code></td><td>0.5, 1.0, 1.0, 1.0</td><td>1.0</td><td>1.0</td><td>1.0</td><td>1.0</td><td>1.0</td></tr>
        <tr><td><code>open-meteo:gem</code></td><td>0.5</td><td>1.0</td><td>1.0</td><td>1.0</td><td>1.0</td><td>1.0</td></tr>
        <tr><td><code>open-meteo:ukmo</code></td><td>2.0</td><td>2.0</td><td>2.0</td><td>1.0</td><td>2.0</td><td>1.0</td></tr>
        <tr><td><code>open-meteo:meteofrance</code></td><td>2.0</td><td>2.0</td><td>2.0</td><td>1.0</td><td>2.0</td><td>1.0</td></tr>
        <tr><td><code>met-no:ecmwf</code></td><td>0.5</td><td>1.0</td><td>1.0</td><td>1.0</td><td>1.0</td><td>1.0</td></tr>
    </tbody>
</table>

<h3>Baseline World Weights (Outside US Region)</h3>
<p>Outside the US region, US-only models (<code>nws</code>, <code>hrrr</code>, <code>nbm</code>) receive weight <code>0.0</code>. Global models use flat horizon weights for Temperature, Wind, Cloud, and Precip mm (with Humidity = <code>1.0</code> and Precip % = <code>1.0</code>): <code>open-meteo:ecmwf = 3.0</code>, <code>open-meteo:icon = 2.5</code>, <code>open-meteo:ukmo = 2.0</code>, <code>open-meteo:meteofrance = 2.0</code>, <code>open-meteo:gem = 1.5</code>, <code>open-meteo:gfs = 1.5</code>, and <code>met-no:ecmwf = 1.5</code>.</p>
""",
    "algorithms": """
<h1>Ensemble Blending &amp; Meteorological Citations</h1>
<p>Every forecast value in <strong>Neginato Mezora</strong> is computed by deterministic, unit-tested algorithms in <code>WeatherCore</code>.</p>

<h2>1. IEEE-754 <code>frexp</code>/<code>ldexp</code> Weighted Median (<code>WeightedMedian.swift</code>)</h2>
<p>Continuous variables (temperature, feels-like, wind speed, gusts, cloud cover, relative humidity, and precipitation amount) are blended using the <strong>weighted median</strong> (Edgeworth, 1888) rather than an arithmetic mean so a single outlier model cannot skew the forecast. To prevent IEEE-754 floating-point overflow or underflow without altering mantissa bits, weights are rescaled by an exact power of two via <code>frexp</code> and <code>ldexp</code> (Goldberg, 1991):</p>
<pre><code>w_tilde_i = ldexp(w_i, -max_exp)   // exact exponent shift, zero mantissa rounding</code></pre>
<p>When cumulative weight lands strictly on the 50% midpoint, the two adjacent values are averaged using an overflow-safe sign-aware formula (<code>meanOfPair</code>).</p>

<h2>2. Mass-Conserving 15-Minute HRRR Rescaling (<code>Nowcast.swift</code>)</h2>
<p>For CONUS places, 15-minute NOAA HRRR precipitation quarters are summed into full UTC hours prior to blending. After multi-model blending produces the consensus hourly total <code>B_H</code>, the 3 smaller quarters scale by <code>B_H / raw_sum</code> and the first largest quarter absorbs the exact remainder <code>B_H - rest</code> so the 4 quarters sum identically to <code>B_H</code>.</p>

<h2>3. WMO Code 4677 &amp; Hydrometeor Classification (<code>ConditionRules.swift</code>)</h2>
<ul>
    <li><strong>Thunderstorm Majority:</strong> &ge; 50% of WMO-reporting members in <code>{95, 96, 97, 99}</code>.</li>
    <li><strong>Snow Majority:</strong> &ge; 50% in <code>{71, 73, 75, 77, 85, 86}</code> and blended temperature <code>T &le; 2.0 °C</code>.</li>
    <li><strong>Sleet / Freezing Rain:</strong> &ge; 50% in <code>{56, 57, 66, 67}</code>, or wet hour with <code>0.0 °C &le; T &lt; 1.5 °C</code>.</li>
    <li><strong>Wet Hour Criterion:</strong> <code>precipMm &ge; 0.1 mm/h</code> and <code>precipProb &ge; 30%</code> (classified as <code>.showers</code> when <code>cloudPct &lt; 87.5%</code> and <code>precipMm &lt; 7.6 mm/h</code>, else steady <code>.rain</code>).</li>
</ul>

<h2>4. Primary Academic &amp; Standard Citations</h2>
<ul>
    <li><strong>Alduchov &amp; Eskridge (1996):</strong> <em>Improved Magnus Form Approximation of Saturation Vapor Pressure</em>, J. Appl. Meteor., 35, 601–609.</li>
    <li><strong>Benjamin et al. (2016):</strong> <em>A North American Hourly Assimilation and Model Forecast Cycle: The Rapid Refresh (HRRR)</em>, Mon. Wea. Rev., 144, 1669–1694.</li>
    <li><strong>Edgeworth (1888):</strong> <em>On a New Method of Reducing Observations Relating to Several Quantities</em>, Phil. Mag., 25, 184–191.</li>
    <li><strong>Glahn &amp; Lowry (1972):</strong> <em>The Use of Model Output Statistics (MOS) in Objective Weather Forecasting</em>, J. Appl. Meteor., 11, 1203–1211.</li>
    <li><strong>Goldberg (1991):</strong> <em>What Every Computer Scientist Should Know About Floating-Point Arithmetic</em>, ACM Comput. Surv., 23, 5–48.</li>
    <li><strong>Hamill et al. (2017):</strong> <em>The U.S. National Blend of Models (NBM)</em>, BAMS, 98, 2599–2617.</li>
    <li><strong>Meeus (1998):</strong> <em>Astronomical Algorithms</em> (2nd ed.), Willmann-Bell (NOAA solar elevation &amp; equation of time).</li>
    <li><strong>Osczevski &amp; Bluestein (2005):</strong> <em>The New Wind Chill Equivalent Temperature Chart</em>, BAMS, 86, 1453–1458.</li>
    <li><strong>Rothfusz (1990):</strong> <em>The Heat Index Equation</em>, NWS Technical Attachment SR/SSD 90-23.</li>
    <li><strong>Rousseeuw &amp; Croux (1993):</strong> <em>Alternatives to the Median Absolute Deviation (MAD)</em>, JASA, 88, 1273–1283.</li>
    <li><strong>Shepard (1968):</strong> <em>A Two-Dimensional Interpolation Function for Irregularly-Spaced Data</em>, Proc. 23rd ACM Nat. Conf., 517–524.</li>
    <li><strong>Stull (2011):</strong> <em>Wet-Bulb Temperature from Relative Humidity and Air Temperature</em>, JAMC, 50, 2267–2269.</li>
    <li><strong>Zängl et al. (2015):</strong> <em>The ICON Modelling Framework of DWD and MPI-M</em>, QJRMS, 141, 563–579.</li>
</ul>
""",
    "live-stations": """
<h1>Live Station 3D Assimilation</h1>
<p>To capture local microclimates (sea breezes, valley cold pools, urban heat islands, and local gust fronts), <code>LiveStationFetcher.swift</code> assimilates live physical observations from nearby airport METAR stations, 90m DEM surface analysis, and US EPA AirNow monitors.</p>

<h2>1. 3D Anisotropic Spatial Kernel</h2>
<p>Each physical station at horizontal distance <code>d</code> (km) and elevation difference <code>Δz</code> (m) is weighted by:</p>
<pre><code>W_horiz(d) = exp(-d² / (2 * 22.0²)) / (1 + (d / 8.0)²)
W_vert(Δz) = exp(-Δz² / (2 * 350.0²))
W_spatial  = W_horiz(d) * W_vert(Δz)</code></pre>

<h2>2. Diurnal Lapse-Rate Elevation Reduction</h2>
<p>Station temperatures and dewpoints are reduced to the target location's elevation using boundary-layer lapse rates before blending:</p>
<ul>
    <li><strong>Daytime Dry-Bulb Lapse Rate:</strong> <code>Γ_T = -0.0068 °C/m</code> (6.8 °C/km mixed convective boundary layer)</li>
    <li><strong>Nighttime Dry-Bulb Lapse Rate:</strong> <code>Γ_T = -0.0042 °C/m</code> (4.2 °C/km nocturnal inversion damping)</li>
    <li><strong>Dewpoint Lapse Rate:</strong> <code>Γ_Td = -0.0019 °C/m</code></li>
</ul>

<h2>3. Shepard Directional Isolation &amp; MAD Buddy QC</h2>
<ul>
    <li><strong>Angular De-Clustering (Shepard, 1968):</strong> Stations clustered along the same compass bearing from the target share angular shadow penalty <code>W_dir = 1 / (1 + 0.85 * shadow)</code>.</li>
    <li><strong>Variable-Specific Temporal Decay:</strong> Exponential decay time constants <code>τ_temp = 2700 s</code> (45 min), <code>τ_wind = 1200 s</code> (20 min), and <code>τ_wx = 900 s</code> (15 min).</li>
    <li><strong>MAD Outlier Quality Control (Rousseeuw &amp; Croux, 1993):</strong> When &ge; 3 stations report, any sensor deviating by more than <code>3.2 × MAD</code> is penalized by a 4th-power Huber tail weight.</li>
    <li><strong>6-Hour MOS Bias Decay (Glahn &amp; Lowry, 1972):</strong> The observed temperature innovation <code>ΔT_0</code> decays across the first 6 forecast hours via <code>ΔT(t) = ΔT_0 * exp(-Δt / 3.5h)</code>.</li>
</ul>
""",
    "shortcuts": """
<h1>Keyboard Shortcuts &amp; Places</h1>
<h2>Keyboard Shortcuts</h2>
<table>
    <thead>
        <tr><th>Shortcut</th><th>Command</th></tr>
    </thead>
    <tbody>
        <tr><td><code>⌘N</code></td><td>Open <strong>Add a City / Street Address / Pin</strong> window</td></tr>
        <tr><td><code>⌘R</code></td><td>Refresh the selected place now</td></tr>
        <tr><td><code>⌘U</code></td><td>Switch between Imperial (<code>°F, mph, in</code>) and Metric (<code>°C, km/h, mm</code>)</td></tr>
        <tr><td><code>⌘,</code></td><td>Open <strong>Neginato Mezora Settings</strong> (<code>Sources</code>, <code>Weights</code>, <code>General</code>)</td></tr>
        <tr><td><code>⌘?</code></td><td>Open <strong>Neginato Mezora Help</strong></td></tr>
        <tr><td><code>⌘Q</code></td><td>Flush unsaved changes and quit Neginato Mezora</td></tr>
    </tbody>
</table>

<h2>Adding Custom Locations, Street Addresses &amp; Map Pins</h2>
<p>Press <code>⌘N</code> or click the <code>+</code> button in the toolbar to open the location picker:</p>
<ul>
    <li><strong>Search Tab:</strong> Enter any city name, street address, postal code, landmark, or raw <code>latitude, longitude</code> pair. Neginato Mezora queries Apple MapKit, US Census TIGER/Line, OpenStreetMap Nominatim, OSM Photon, and Open-Meteo in parallel.</li>
    <li><strong>Pin on Map Tab:</strong> Click anywhere on the interactive Apple Map (or enter exact coordinates and a custom label) to save a hyper-local pin.</li>
</ul>
""",
}


def render_shell(current_id: str, title: str, body_html: str) -> str:
    nav_parts: list[str] = []
    for section in SECTIONS:
        nav_parts.append(f'<div class="nav-section">{section["title"]}</div>')
        for page in section["pages"]:
            active = " active" if page["id"] == current_id else ""
            nav_parts.append(
                f'<a class="nav-link{active}" href="{page["href"]}">{page["title"]}</a>'
            )
    nav_html = "\n".join(nav_parts)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="AppleTitle" content="Neginato Mezora Help">
    <title>{title} — Neginato Mezora Help</title>
    <link rel="stylesheet" href="book.css">
    <link rel="stylesheet" href="help-ui.css">
</head>
<body>
    <div class="help-layout">
        <aside class="help-sidebar">
            <div class="brand">⛅ Neginato Mezora Help</div>
            <input id="help-search" class="search-input" type="search" placeholder="Search documentation…">
            <div id="search-results" class="search-results"></div>
            <nav>
                {nav_html}
            </nav>
        </aside>
        <main class="help-main">
            {body_html.strip()}
        </main>
    </div>
    <script src="search-index.js"></script>
    <script src="help.js"></script>
</body>
</html>
"""


def main() -> None:
    CONTENTS_DIR.mkdir(parents=True, exist_ok=True)
    EN_LPROJ.mkdir(parents=True, exist_ok=True)

    (CONTENTS_DIR / "Info.plist").write_text(INFO_PLIST.strip() + "\n", encoding="utf-8")
    (EN_LPROJ / "book.css").write_text(BOOK_CSS.strip() + "\n", encoding="utf-8")
    (EN_LPROJ / "help-ui.css").write_text("/* Additional UI overrides */\n", encoding="utf-8")
    (EN_LPROJ / "help.js").write_text(HELP_JS.strip() + "\n", encoding="utf-8")
    (EN_LPROJ / "toc.json").write_text(
        json.dumps({"sections": SECTIONS}, indent=2) + "\n", encoding="utf-8"
    )
    (EN_LPROJ / "_shell.html").write_text(
        render_shell("__PAGE_ID__", "__PAGE_TITLE__", "__PAGE_BODY__"),
        encoding="utf-8",
    )

    search_index = []
    for page in all_pages():
        pid = page["id"]
        body = PAGE_BODIES[pid]
        full_html = render_shell(pid, page["title"], body)
        (EN_LPROJ / page["href"]).write_text(full_html, encoding="utf-8")
        search_index.append(
            {
                "id": pid,
                "title": page["title"],
                "section": page["section"],
                "href": page["href"],
                "body": strip_html(body),
            }
        )

    search_js = "window.HELP_SEARCH_INDEX = " + json.dumps(search_index, indent=2) + ";\n"
    (EN_LPROJ / "search-index.js").write_text(search_js, encoding="utf-8")
    print(f"Regenerated {len(search_index)} help pages in {EN_LPROJ}")


if __name__ == "__main__":
    main()
