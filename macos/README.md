# Neginato Mezora for macOS

**Neginato Mezora** is a native Swift 6 / SwiftUI meteorological workstation and precipitation nowcasting application for macOS. It blends up to **13 numerical weather prediction (NWP) models** across five free, unauthenticated upstream providers (`Open-Meteo`, `NOAA National Weather Service`, `MET Norway`, `DWD Bright Sky`, and `Environment Canada`), fuses them with **real-time physical surface observations** from 10 keyless station networks (`NOAA AviationWeather METAR` worldwide; `NWS ASOS` and the `Iowa Environmental Mesonet` in the US; `ECCC SWOB` in Canada; `DWD`, `DMI`, `FMI`, `SMHI`, `GeoSphere Austria` and `MeteoSwiss` in Europe) and 5 more with the user's own free key (`Met Office`, `KNMI`, `MET Norway Frost`, `Météo-France`, `AEMET`) plus the `Open-Meteo 90m DEM` analysis, learns each place's **local forecast bias** from those stations, shows air quality from the nearest `US EPA AirNow` monitor as reported or the `Copernicus CAMS` forecast, and presents high-contrast visual cards with sub-hourly precipitation charts.

- **Download:** **[⬇ Download Neginato Mezora for macOS (`Neginato.Mezora.dmg`)](https://github.com/wtp128pro/weather/releases/latest/download/Neginato.Mezora.dmg)** (Signed & notarized · Requires macOS 27 or later)
- **Website:** **[neginato.app/mezora](https://neginato.app/mezora)** (Suite home: **[neginato.app](https://neginato.app)**)
- **License:** Open source under **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** — see [`../COPYING`](../COPYING).

> **Apple ID & Bundle Identifier Continuity:**  
> While the application display name is **Neginato Mezora**, the bundle identifier (`io.github.wtp128pro.Weather`) and Apple Development Team (`AQK9MG47BS`) remain unchanged so existing code-signing provisioning profiles, notarization pipelines, and sandboxed container directories (`~/Library/Containers/io.github.wtp128pro.Weather/`) work seamlessly.

---

## Documentation Map

- **[`ALGORITHMS_AND_ARCHITECTURE.md`](ALGORITHMS_AND_ARCHITECTURE.md)** — Complete mathematical, physical, and algorithmic reference (with academic and institutional citations):
  - IEEE-754 `frexp`/`ldexp` weighted median (`WxWeightedMedian`) & multi-model ensemble blending (`WxBlend`)
  - Complete US (4 horizon bands `H0`–`H3`) and World baseline weight matrices (`WxWeights`) & custom multipliers (`WxWeightMultipliers`)
  - 15-minute HRRR nowcast extraction & mass-conserving sub-hourly quarter rescaling (`WxNowcast`)
  - WMO Code Table 4677 consensus voting, hydrometeor classification & 48-hour rain outlook state machine (`WxConditionRules`, `WxDaily`, `WxRainRules`)
  - Live physical station assimilation from 15 networks (5 with the user's free key, kept in the Keychain) with one algorithm in every country: 3D anisotropic Cauchy-Gaussian spatial kernel, diurnal lapse-rate elevation reduction, Shepard (1968) de-clustering, MAD buddy QC, per-station health from leave-one-out cross-validation (`WxStationFusion`, `WxStationNetworks`, `WxStationCatalog`), 6-hour MOS exponential bias decay, and a learned per-place, time-of-day forecast bias correction (`WxLocalBias`)
  - Psychrometrics (Alduchov & Eskridge 1996 Magnus-Tetens, Stull 2011 wet-bulb, Rothfusz 1990 Heat Index, Osczevski & Bluestein 2005 Wind Chill), radiative random-overlap cloud cover, and the Air Quality card (nearest AirNow monitor as reported, else the CAMS forecast)
  - Haversine great-circle distance & NOAA/Meeus solar elevation algorithm (`WxGeo`)
  - Crash-safe `F_FULLFSYNC` atomic storage, scheduler freshness windows, and RFC 9111 conditional caching
- **[`FEATURES.md`](FEATURES.md)** — Feature guide covering UI cards, labeled rain charts, Settings (`⌘,`) for sources, weights and stations, street-address geocoding, and keyboard shortcuts.
- **Bundled In-App Help Book (`Weather/NeginatoMezora.help`)** — 14 pages, accessible via `Help > Neginato Mezora Help` (`⌘?`) and the Help menu's topic links; page bodies in `scripts/help/pages.py`, generated and validated by `scripts/help/regenerate.py` and `scripts/help/validate.py`.

---

## Key Highlights

### 1. Clear, Self-Documenting Rain Graph & Bars
The **Rain** card in the detail pane (`DetailView.swift`, `DetailRainChart.swift`) presents up to two side-by-side charts (**Next 2 hours** at 15-minute intervals and **Next 24 hours** at 1-hour intervals) with unambiguous visual legends, axis labels, and callouts:
- **Bars (`Bars: Rain rate (in/h or mm/h, left)`):** Aqua-to-cobalt vertical bars plotted against the left Y-axis, labeled at the top (`Rate · 0.10 in/h` or `Rate · 2.5 mm/h`), midpoint (`0.05 in/h` or `1.3 mm/h`), and baseline (`0 in/h` or `0 mm/h`), with direct peak rate callout badges above the highest bars.
- **Curve (`Line: Rain chance (%, right)`):** Smooth monotone cubic Hermite curve on the 24-hour chart plotted against the right Y-axis, labeled at `100%`, `50%`, and `0%` in matching warm amber-rose, plus a peak probability callout badge.
- **Interactive Hover Readout:** Moving the cursor over any time slot highlights the bar and curve point with a vertical guide line and displays a floating readout banner (`<Time> · Bar: <rate> · Chance: <prob>%`).

### 2. Native Settings Dialogue (`⌘,`) for Sources, Blend Weights & Stations
Replacing the legacy hamburger popover, **Neginato Mezora Settings** (`⌘,` or the gear button in the window toolbar) provides a four-tab native macOS settings window (`Weather/Settings/SettingsView.swift`):
- **Sources Tab:** Enable or disable `Open-Meteo`, `National Weather Service`, `MET Norway`, `DWD Bright Sky`, and `Environment Canada`; inspect live per-place status (`Used for this place (N forecast models)`, `Turned off`, or error diagnostics); adjust each provider's overall **Source Weight Multiplier** (`0.10×` to `3.00×`, default `1.00×`); and open attribution/license links.
- **Weights Tab:** Fine-tune per-model multipliers (`0.00×` to `3.00×`) for all 13 NWP models (`NOAA NWS Grid`, `NOAA HRRR`, `NOAA NBM`, `ECMWF IFS`, `NOAA GFS`, `DWD ICON`, `ECCC GEM`, `UK Met Office`, `Météo-France`, `KNMI HARMONIE`, `MET Norway`, `DWD MOSMIX`, and `ECCC HRDPS`), inspect baseline and effective weights across all 8 regional profiles (`WxRegion`), 6 variable groups (`Temp`, `Wind`, `Cloud`, `Humidity`, `Precip mm`, `Precip %`), and 4 horizon bands (`H0: 0–3h`, `H1: 3–18h`, `H2: 18–72h`, `H3: 72h+`) plus `World`, or reset all weights to `1.00×`.
- **Stations Tab (`StationsSettingsTab.swift`):** Show, switch off or reset the learned local corrections (per place, by hour of the day); enter the free keys of the Met Office, KNMI, MET Norway Frost, Météo-France and AEMET (stored in the login Keychain) with built-in sign-up steps, expiry and live status; switch any station network off; and see every station near the selected place with its weight and the reason.
- **General Tab:** Toggle between Imperial (`°F, mph, in`) and Metric (`°C, km/h, mm`), open the Help Book (`⌘?`), or view the About panel.

---

## Building, Testing & Packaging

### Local Build & Unit Tests (`WeatherCoreTests`)
```bash
xcodebuild -project Weather.xcodeproj \
  -scheme Weather \
  -destination 'platform=macOS' \
  -derivedDataPath ../build-macos \
  test
```

### Regenerating & Validating the In-App Help Book
```bash
python3 scripts/help/regenerate.py
python3 scripts/help/validate.py
```
After changing `WeatherCore/Blend/Weights.swift`, rebuild the help's weight tables from the code first (`HelpBookTests` fails until you do): build once, then `python3 scripts/help/weight_tables.py ../build-macos/Build/Products/Debug`.

### Checking & Fixing Math in the Markdown Docs
```bash
python3 scripts/github_math.py check
python3 scripts/github_math.py fix
```
GitHub mangles some valid LaTeX: it strips backslash escapes such as `\!` and `\%` from `$…$` and `$$…$$`, shows a ```` ```math ```` block inside a list as plain code, and rejects `\operatorname`. `check` reports each formula that will not render as written, with its line number; `fix` rewrites them into forms GitHub passes on verbatim (`` $`…`$ `` inline, ```` ```math ```` at the top level, `` $`\displaystyle …`$ `` inside a list). With no file arguments both process every tracked `.md` file, confirming each formula through GitHub's Markdown API; add `--offline` to skip that round trip. Run `check` after editing `ALGORITHMS_AND_ARCHITECTURE.md` or `FEATURES.md`.

### Signed Release Archive & Notarized DMG
1. Copy `Local.xcconfig.example` to `Local.xcconfig` (`BB_DEVELOPMENT_TEAM = AQK9MG47BS`).
2. Copy `scripts/signing_credentials.sh.example` to `scripts/signing_credentials.sh`.
3. Run `./build.sh` to archive, export, notarize, staple, and package `Neginato Mezora.dmg` (containing `Neginato Mezora.app`).
