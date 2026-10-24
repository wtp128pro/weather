# Neginato Mezora for macOS

**Neginato Mezora** is a native Swift 6 / SwiftUI meteorological workstation and precipitation nowcasting application for macOS. It blends up to **10 numerical weather prediction (NWP) models** across three free, unauthenticated upstream providers (`Open-Meteo`, `NOAA National Weather Service`, and `MET Norway`), fuses them with **real-time physical surface observations** (`NOAA/FAA AviationWeather METAR`, `Open-Meteo 90m DEM`, and `US EPA AirNow`), and presents high-contrast visual cards with sub-hourly precipitation charts.

> **Apple ID & Bundle Identifier Continuity:**  
> While the application display name is **Neginato Mezora**, the bundle identifier (`io.github.wtp128pro.Weather`) and Apple Development Team (`AQK9MG47BS`) remain unchanged so existing code-signing provisioning profiles, notarization pipelines, and sandboxed container directories (`~/Library/Containers/io.github.wtp128pro.Weather/`) work seamlessly.

---

## Documentation Map

- **[`ALGORITHMS_AND_ARCHITECTURE.md`](ALGORITHMS_AND_ARCHITECTURE.md)** — Complete mathematical, physical, and algorithmic reference (with academic and institutional citations):
  - IEEE-754 `frexp`/`ldexp` weighted median (`WxWeightedMedian`) & multi-model ensemble blending (`WxBlend`)
  - Complete US (4 horizon bands `H0`–`H3`) and World baseline weight matrices (`WxWeights`) & custom multipliers (`WxWeightMultipliers`)
  - 15-minute HRRR nowcast extraction & mass-conserving sub-hourly quarter rescaling (`WxNowcast`)
  - WMO Code Table 4677 consensus voting, hydrometeor classification & 48-hour rain outlook state machine (`WxConditionRules`, `WxDaily`, `WxRainRules`)
  - Live physical station assimilation: 3D anisotropic Cauchy-Gaussian spatial kernel, diurnal lapse-rate elevation reduction, Shepard (1968) directional isolation, MAD buddy QC, and 6-hour MOS exponential bias decay (`LiveStationFetcher`)
  - Psychrometrics (Alduchov & Eskridge 1996 Magnus-Tetens, Stull 2011 wet-bulb, Rothfusz 1990 Heat Index, Osczevski & Bluestein 2005 Wind Chill), radiative random-overlap cloud cover, and EPA AirNow AQI interpolation
  - Haversine great-circle distance & NOAA/Meeus solar elevation algorithm (`WxGeo`)
  - Crash-safe `F_FULLFSYNC` atomic storage, scheduler freshness windows, and RFC 9111 conditional caching
- **[`FEATURES.md`](FEATURES.md)** — Feature guide covering UI cards, labeled rain charts, Settings (`⌘,`) for sources & weights, street-address geocoding, and keyboard shortcuts.
- **Bundled In-App Help Book (`Weather/NeginatoMezora.help`)** — Accessible via `Help > Neginato Mezora Help` (`⌘?`), generated and validated by `scripts/help/regenerate.py` and `scripts/help/validate.py`.

---

## Key Highlights

### 1. Clear, Self-Documenting Rain Graph & Bars
The **Rain** card in the detail pane (`DetailView.swift`, `DetailRainChart.swift`) presents up to two side-by-side charts (**Next 2 hours** at 15-minute intervals and **Next 24 hours** at 1-hour intervals) with unambiguous visual legends, axis labels, and callouts:
- **Bars (`Bars: Rain rate (in/h or mm/h, left)`):** Aqua-to-cobalt vertical bars plotted against the left Y-axis, labeled at the top (`Rate · 0.10 in/h` or `Rate · 2.5 mm/h`), midpoint (`0.05 in/h` or `1.3 mm/h`), and baseline (`0 in/h` or `0 mm/h`), with direct peak rate callout badges above the highest bars.
- **Curve (`Line: Rain chance (%, right)`):** Smooth monotone cubic Hermite curve on the 24-hour chart plotted against the right Y-axis, labeled at `100%`, `50%`, and `0%` in matching warm amber-rose, plus a peak probability callout badge.
- **Interactive Hover Readout:** Moving the cursor over any time slot highlights the bar and curve point with a vertical guide line and displays a floating readout banner (`<Time> · Bar: <rate> · Chance: <prob>%`).

### 2. Native Settings Dialogue (`⌘,`) for Sources & Blend Weights
Replacing the legacy hamburger popover, **Neginato Mezora Settings** (`⌘,` or the gear button in the window toolbar) provides a three-tab native macOS settings window (`Weather/Settings/SettingsView.swift`):
- **Sources Tab:** Enable or disable `Open-Meteo`, `National Weather Service`, and `MET Norway`; inspect live per-place status (`Used for this place (N forecast models)`, `Turned off`, or error diagnostics); adjust each provider's overall **Source Weight Multiplier** (`0.10×` to `3.00×`, default `1.00×`); and open attribution/license links.
- **Weights Tab:** Fine-tune per-model multipliers (`0.00×` to `3.00×`) for all 10 NWP models (`NOAA NWS Grid`, `NOAA HRRR`, `NOAA NBM`, `ECMWF IFS`, `NOAA GFS`, `DWD ICON`, `ECCC GEM`, `UK Met Office`, `Météo-France`, and `MET Norway`), inspect baseline and effective weights across all 6 variable groups (`Temp`, `Wind`, `Cloud`, `Humidity`, `Precip mm`, `Precip %`) and 4 US horizon bands (`H0: 0–3h`, `H1: 3–18h`, `H2: 18–72h`, `H3: 72h+`) plus `World`, or reset all weights to `1.00×`.
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

### Signed Release Archive & Notarized DMG
1. Copy `Local.xcconfig.example` to `Local.xcconfig` (`BB_DEVELOPMENT_TEAM = AQK9MG47BS`).
2. Copy `scripts/signing_credentials.sh.example` to `scripts/signing_credentials.sh`.
3. Run `./build.sh` to archive, export, notarize, staple, and package `Weather.dmg`.
