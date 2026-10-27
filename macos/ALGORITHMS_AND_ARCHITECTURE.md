# Neginato Mezora — Algorithms, Weights, and Architectural Reference

> **Application Name:** Neginato Mezora  
> **Bundle Identifier (preserved for signing & sandbox continuity):** `io.github.wtp128pro.Weather`  
> **Development Team ID:** `AQK9MG47BS`  
> **Architecture:** Native Swift 6 / SwiftUI (`Weather` app target + `WeatherCore` framework)  
> **License:** GPL-3.0-or-later

---

## Table of Contents

1. [Executive Overview & Architectural Philosophy](#1-executive-overview--architectural-philosophy)
2. [Multi-Model Ensemble Blending & Weighted Median (`Blend.swift`, `WeightedMedian.swift`)](#2-multi-model-ensemble-blending--weighted-median)
3. [Heuristic Forecast Weights, Horizon Bands & User Multipliers (`Weights.swift`)](#3-heuristic-forecast-weights-horizon-bands--user-multipliers)
4. [15-Minute HRRR Nowcast & Mass-Conserving Sub-Hourly Rescaling (`Nowcast.swift`, `OpenMeteoProvider.swift`)](#4-15-minute-hrrr-nowcast--mass-conserving-sub-hourly-rescaling)
5. [Sky Condition Derivation, Hydrometeor Classification & Daily Aggregation (`ConditionRules.swift`, `Daily.swift`, `RainRules.swift`)](#5-sky-condition-derivation-hydrometeor-classification--daily-aggregation)
6. [Live Physical Station Assimilation & 3D Anisotropic Kernel Fusion (`StationFusion.swift`, `StationNetworks.swift`, `StationCatalog.swift`, `LocalBias.swift`, `LiveStationFetcher.swift`)](#6-live-physical-station-assimilation--3d-anisotropic-kernel-fusion)
7. [Psychrometrics, Thermodynamics & Apparent Temperature (`LiveStationFetcher.swift`, `Format.swift`)](#7-psychrometrics-thermodynamics--apparent-temperature)
8. [Radiative Cloud Transmittance & the Air Quality Card (`AirQuality.swift`)](#8-radiative-cloud-transmittance--the-air-quality-card)
9. [Solar Position & Spherical Geodesy (`Geo.swift`)](#9-solar-position--spherical-geodesy)
10. [Rain Graph & Bars Visual Encoding (`ChartData.swift`, `DetailRainChart.swift`, `DetailView.swift`)](#10-rain-graph--bars-visual-encoding)
11. [Multi-Source Street-Address Geocoding & Proximity Deduplication (`AddressGeocoder.swift`, `Places.swift`)](#11-multi-source-street-address-geocoding--proximity-deduplication)
12. [Refresh Scheduler, Provider Rate-Limiting & Atomic Storage (`Scheduler.swift`, `RefreshEngine.swift`, `FileIO.swift`)](#12-refresh-scheduler-provider-rate-limiting--atomic-storage)
13. [Per-Place Units & Migration (`Places.swift`, `AppModel.swift`, `Geo.swift`)](#13-per-place-units--migration)
14. [Official Weather Alerts (`AlertsService.swift`, `AlertRegions.swift`, `AlertsFetchers.swift`)](#14-official-weather-alerts)
15. [Architectural Decision Records (ADRs)](#15-architectural-decision-records-adrs)
16. [Academic, Institutional & Standard Citations](#16-academic-institutional--standard-citations)

---

## 1. Executive Overview & Architectural Philosophy

**Neginato Mezora** is a native macOS meteorological workstation and hyper-local precipitation nowcasting application. It synthesizes numerical weather prediction (NWP) guidance from up to **10 distinct forecast models across 3 independent upstream providers** (`Open-Meteo`, `NOAA National Weather Service`, and `MET Norway`), fuses them with **real-time physical surface observations** from up to 10 keyless station networks (`NOAA AviationWeather METAR` worldwide, `NWS ASOS` and the `Iowa Environmental Mesonet` in the US, `ECCC SWOB` in Canada, `DWD`, `DMI`, `FMI`, `SMHI`, `GeoSphere Austria` and `MeteoSwiss` in Europe) plus the `Open-Meteo 90m DEM surface analysis` and `US EPA AirNow`, and renders high-contrast Apple Weather–inspired visual cards. Each place keeps its own display units (§13) and shows the official weather alerts of the one keyless issuer that covers it — NWS, DWD via Bright Sky, MET Norway, Environment Canada or MeteoAlarm (§14).

The system is split into two strict layers:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         Weather (macOS SwiftUI Target)                       │
│  ShellWindow · DetailView · DetailRainChart · SettingsView · HelpWindowMgr   │
│  LiveStationFetcher · StationNetworkFetcher (stations & AirNow, HTTP)        │
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                       WeatherCore (Framework Target)                         │
│  AppModel · ServiceOrchestrator · RefreshEngine · WxScheduler                │
│  WxBlend · WxWeights · WxWeightedMedian · WxNowcast · WxRainRules · WxGeo    │
│  WxStationFusion · WxStationNetworks · WxStationCatalog · WxLocalBias        │
│  OpenMeteoProvider · NWSProvider · METNorwayProvider · AddressGeocoder       │
│  WxPlaces · WxSettings · WxForecastCache · StoreJSON · FileIO (F_FULLFSYNC)  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Core Design Tenets
1. **Robust Order Statistics over Arithmetic Averaging:** Continuous atmospheric variables (temperature, feels-like, wind speed, gusts, cloud fraction, relative humidity, and precipitation amount) are combined via a **weighted median** rather than a weighted mean so a single outlier NWP model cannot skew the forecast ([`Blend.swift`](WeatherCore/Blend/Blend.swift), [`WeightedMedian.swift`](WeatherCore/Blend/WeightedMedian.swift)).
2. **Horizon-Dependent Model Trust:** Short-range convection-allowing models (`NOAA HRRR` 3 km) dominate the 0–18 h window, calibrated multi-model ensembles (`NOAA NBM`) and human-edited grids (`NWS NDFD`) anchor medium/extended ranges, and global spectral models (`ECMWF IFS`, `DWD ICON`, `UKMO`, `Météo-France`, `NOAA GFS`, `ECCC GEM`) provide global coverage ([`Weights.swift`](WeatherCore/Blend/Weights.swift)).
3. **User-Transparent & Customizable Weights:** All provider and per-model weights are exposed in the native **Settings (`⌘,`)** dialogue ([`SettingsView.swift`](Weather/Settings/SettingsView.swift)), allowing users to inspect the baseline table across all 6 variable groups and 4 horizon bands and apply custom `[0.00×, 3.00×]` multipliers persisted to `weights.json`.
4. **Physical Observation Grounding:** Model grid points can miss sub-grid coastal breezes, valley inversions, and urban heat islands. [`StationFusion.swift`](WeatherCore/Blend/StationFusion.swift) assimilates every reachable station within 95 km — airports and national, road-weather, hydrological and research networks — with one algorithm in every country: a 3D anisotropic kernel with lapse-rate elevation reduction, Shepard de-clustering, a MAD buddy check, and a per-station health record learned by leave-one-out cross-validation ([`StationCatalog.swift`](WeatherCore/Storage/StationCatalog.swift)). Close, fresh station readings also teach each place's **local forecast bias** by time of day ([`LocalBias.swift`](WeatherCore/Blend/LocalBias.swift)), which corrects the whole forecast, not just "now".

---

## 2. Multi-Model Ensemble Blending & Weighted Median

**Implementation:** [`WeatherCore/Blend/Blend.swift`](WeatherCore/Blend/Blend.swift), [`WeatherCore/Blend/WeightedMedian.swift`](WeatherCore/Blend/WeightedMedian.swift)

### 2.1 Why Weighted Median Instead of Weighted Mean?

In multi-model NWP ensembles, individual models frequently exhibit phase or amplitude errors (e.g., one model stalls a frontal boundary 30 km too far west, predicting $18\text{ mm/h}$ of rain while six other models predict $0\text{ mm/h}$). Under an arithmetic weighted mean, a single wet outlier produces artificial drizzle across dry hours ("ensemble drizzle bias"). The **weighted median** (Edgeworth, 1888) has a breakdown point of $`50\%`$—any minority of outlier models with less than half the total weight cannot pull the blended estimate away from the consensus regime.

Precipitation probability (`precipProb`), by contrast, is already a calibrated probability in $`[0, 100]\%`$ and is combined via a **weighted arithmetic mean** so every model's wet/dry signal contributes proportionally to the final risk percentage.

### 2.2 Numerical Stability via IEEE-754 `frexp`/`ldexp` Weight Scaling

**Implementation:** [`WeightedMedian.swift:22-121`](WeatherCore/Blend/WeightedMedian.swift#L22-L121)

Given $n \in [1, 64]$ candidate pairs $(x_i, w_i)$ filtered to finite $x_i$ and strictly positive finite weights $w_i > 0$:

1. **Power-of-Two Exponent Normalization:**  
   Directly summing arbitrary positive IEEE-754 `Double` weights can overflow to $+\infty$ (when $w_i \sim 10^{308}$) or underflow to $0$ (when $w_i \sim 10^{-320}$). To guarantee exactness without altering the binary significands (mantissas) of the weights, we find:

   $`\displaystyle w_{\max} = \max_{1 \le i \le k} w_i, \qquad (m, e_{\max}) = \mathrm{frexp}(w_{\max})`$

   where $m \in [0.5, 1.0)$ and $w_{\max} = m \cdot 2^{e_{\max}}$. Every weight is rescaled by an exact power of two via $\mathrm{ldexp}$:

   $`\displaystyle \tilde{w}_i = \mathrm{ldexp}(w_i, -e_{\max}) = w_i \cdot 2^{-e_{\max}} \in [0, 1)`$

   Because $\mathrm{ldexp}$ only adjusts the 11-bit IEEE-754 exponent field, **zero rounding error** is introduced into the mantissas, and the total weight satisfies:

   $`\displaystyle 0.5 \le \sum_{i=1}^k \tilde{w}_i < k \le 64`$

   which is guaranteed never to overflow or underflow (Goldberg, 1991).

2. **Stable Insertion Sort:**  
   The surviving pairs $(x_i, \tilde{w}_i)$ are sorted in ascending order of $x_i$ using a deterministic insertion sort (`j > 0 && xs[j - 1] > x`). Because $k \le 64$, insertion sort is cache-optimal and preserves member registration order for equal values.

3. **50% Cumulative Weight Threshold & Exact Tie-Breaking:**  
   Let $`H = \frac{1}{2} \sum_{i=1}^k \tilde{w}_i`$ be the half-weight threshold, and let $`C_i = \sum_{m=0}^{i} \tilde{w}_m`$ be the running cumulative weight:
   - The walk stops at the first index $i$ where $C_i \ge H$.
   - **Strict Exceedance ($C_i > H$):** The weighted median is $x_i$.
   - **Exact Split ($C_i == H$):** When the cumulative weight lands exactly on $H$, any zero-weight padding entries are skipped to find the next positive-weight element $x_j$ ($j > i$), and the tie is broken by their overflow-safe midpoint (`meanOfPair`):

     $`\displaystyle \mathrm{meanOfPair}(a, b) = \begin{cases} \dfrac{a + b}{2} & \text{if } (a < 0) \neq (b < 0) \quad \text{(opposite signs: } a+b \text{ cannot overflow)} \\[6pt] a + \dfrac{b - a}{2} & \text{if } \mathrm{sgn}(a) = \mathrm{sgn}(b) \quad \text{(same sign: } b-a \text{ cannot overflow)} \end{cases}`$

### 2.3 Per-Hour Ensemble Synthesis Rules

**Implementation:** [`Blend.swift:120-260`](WeatherCore/Blend/Blend.swift#L120-L260)

For each valid UTC hour $t_S$ in the union of all member timelines (capped at `WxLimits.forecastMaxHours = 240` hours):

| Output Field | Blending Estimator | Weight Group (`WxVar`) | Post-Processing & Special Rules |
| :--- | :--- | :--- | :--- |
| `tempC` | Weighted Median | `.temp` | Unweighted interquartile/range spread `tempSpreadC = max(tempC) - min(tempC)` when $\ge 2$ members report finite `tempC` (else `NaN`). |
| `feelsC` | Weighted Median | `.temp` | Uses member-reported apparent temperature. |
| `windKmh` | Weighted Median | `.wind` | Clamped $\ge 0$. |
| `gustKmh` | Weighted Median | `.wind` | Enforces physical invariant `gustKmh = max(gustKmh, windKmh)` when both are finite. |
| `cloudPct` | Weighted Median | `.cloud` | Clamped to $`[0, 100]\%`$. |
| `humidityPct` | Weighted Median | `.humidity` | Clamped to $`[0, 100]\%`$. |
| `precipMm` | Weighted Median | `.precipMm` | Also records `precipMmMax = max_i(precipMm_i)` across all members with positive `.precipMm` weight. |
| `precipProb` | Weighted Mean (or Derived Fallback) | `.precipProb` | See **§2.4** below. |

### 2.4 Precipitation Probability & Wet-Member Derivation Fallback

**Implementation:** [`Blend.swift:208-237`](WeatherCore/Blend/Blend.swift#L208-L237)

1. **Primary (Weighted Mean of Reported Probabilities):**  
   If at least one member supplies a finite `precipProb` with weight $w_i = \mathrm{weight}(\text{src}_i, \text{model}_i, \text{.precipProb}, h, \text{us}) > 0$:

   $`\displaystyle P_{\text{precip}} = \mathrm{clamp}_{[0, 100]}\!\left(\frac{\sum_i \tilde{w}_i \, P_i}{\sum_i \tilde{w}_i}\right)`$

   where $`\tilde{w}_i = \mathrm{ldexp}(w_i, -e_{\max})`$.

2. **Secondary Fallback (Derived from Wet-Member Fraction):**  
   Some global models (such as `MET Norway` and certain regional NWP feeds) report hourly precipitation amount (`precipMm`) without an explicit probability field. If no member reports `precipProb` at hour $t_S$, the probability is derived from the weighted fraction of members predicting measurable rain (`precipMm >= 0.1 mm/h`, `derivedWetMm = 0.1`):

   $`\displaystyle P_{\text{derived}} = 100 \cdot \frac{\sum_{i \,:\, R_i \ge 0.1} \tilde{w}_{i,\text{mm}}}{\sum_{i \,:\, R_i \text{ finite}} \tilde{w}_{i,\text{mm}}}`$

   using the `.precipMm` weights $w_{i,\text{mm}}$.

### 2.5 Sub-Hourly Linear Interpolation for "Now"

**Implementation:** [`Blend.swift:326-389`](WeatherCore/Blend/Blend.swift#L326-L389) (`WxBlend.interpolateAt`)

When displaying current conditions at wall-clock time $t_{\text{now}}$ between two consecutive hourly slots $h_0$ ($t_0 \le t_{\text{now}} < t_0 + 3600$) and $h_1$ ($t_1 = t_0 + 3600$), continuous fields are linearly interpolated with fraction $\alpha = (t_{\text{now}} - t_0) / 3600 \in [0, 1)$:
```math
\mathrm{lerpKnown}(a, b, \alpha) = \begin{cases} a + \alpha (b - a) & \text{if } a, b \text{ finite} \\ a & \text{if only } a \text{ finite} \\ b & \text{if only } b \text{ finite} \\ \text{NaN} & \text{otherwise} \end{cases}
```
Discrete fields (`condition`, `isDay`, `nMembers`, `tS`) are taken from the enclosing hour $h_0$.

---

## 3. Heuristic Forecast Weights, Horizon Bands & User Multipliers

**Implementation:** [`WeatherCore/Blend/Weights.swift`](WeatherCore/Blend/Weights.swift)

### 3.1 Forecast Horizon Bands (`bandOf`)

Forecast lead time (horizon) in hours is defined as:
```math
h = \frac{t_{\text{valid}} - t_{\text{now}}}{3600}
```
In the US region (`usRegion == true`), weights vary across 4 lead-time horizon bands (`bandOf`, [`Weights.swift:311-324`](WeatherCore/Blend/Weights.swift#L311-L324)):

| Band Index | Symbol | Horizon Interval $h$ (Hours) | Physical & Operational Regime |
| :---: | :---: | :--- | :--- |
| `0` | **H0** | $(-\infty, 3.0)$ | **Nowcast / Immediate (0–3 h):** Radar-assimilating rapid-refresh (`HRRR`) and human-monitored `NWS` grids dominate. |
| `1` | **H1** | $[3.0, 18.0)$ | **Short-Range Mesoscale (3–18 h):** Convection-allowing `HRRR` and calibrated `NBM` carry peak weight. |
| `2` | **H2** | $[18.0, 72.0)$ | **Medium-Range Synoptic (18–72 h):** `HRRR` tapers off (and cuts off strictly at $h > 48.0\text{ h}$); `NWS`, `NBM`, and `ECMWF` lead. |
| `3` | **H3** | $[72.0, +\infty)$ | **Extended Synoptic ($\ge 72\text{ h}$):** `HRRR` weight is $0$; `NWS`, `ECMWF`, `NBM`, and `ICON` anchor the extended outlook. |

### 3.2 Complete Baseline US Weight Table (`usRegion == true`)

Each cell lists the four horizon band weights `[H0, H1, H2, H3]` (or a single number when flat across all four bands):

| Source : Model | Coverage / Cutoff | `.temp` | `.wind` | `.cloud` | `.humidity` | `.precipMm` | `.precipProb` |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `nws:*` (NOAA NWS Grid) | US Only | `[4.0, 4.0, 4.5, 5.0]` | `3.0` | `3.0` | `1.0` | `[2.0, 3.0, 4.0, 4.0]` | `5.0` |
| `open-meteo:hrrr` (and `hrrr15`) | US Only, $\le 48\text{ h}$ | `[3.0, 3.0, 0.5, 0.0]` | `[3.0, 3.0, 0.5, 0.0]` | `[2.0, 2.0, 0.5, 0.0]` | `[1.0, 1.0, 1.0, 0.0]` | `[4.0, 4.0, 1.0, 0.0]` | `[1.0, 1.0, 1.0, 0.0]` |
| `open-meteo:nbm` (NOAA NBM) | US Only | `[2.5, 3.0, 3.0, 2.0]` | `2.0` | `2.0` | `1.0` | `2.0` | `2.0` |
| `open-meteo:ecmwf` (ECMWF IFS) | Worldwide | `[1.0, 1.5, 2.0, 2.0]` | `1.5` | `1.5` | `1.0` | `[1.0, 2.0, 2.5, 2.5]` | `1.0` |
| `open-meteo:gfs` (NOAA GFS) | Worldwide | `[0.5, 1.0, 1.0, 1.0]` | `1.0` | `1.0` | `1.0` | `1.0` | `1.0` |
| `open-meteo:icon` (DWD ICON) | Worldwide | `[0.5, 1.0, 1.0, 1.0]` | `1.0` | `1.0` | `1.0` | `[1.0, 1.0, 1.5, 1.5]` | `1.0` |
| `open-meteo:gem` (ECCC GEM) | Worldwide | `0.5` | `1.0` | `1.0` | `1.0` | `1.0` | `1.0` |
| `open-meteo:ukmo` (UK Met Office) | Worldwide | `2.0` | `2.0` | `2.0` | `1.0` | `2.0` | `1.0` |
| `open-meteo:meteofrance` | Worldwide | `2.0` | `2.0` | `2.0` | `1.0` | `2.0` | `1.0` |
| `open-meteo:knmi` (KNMI HARMONIE) | Benelux / North Sea | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) |
| `met-no:ecmwf` (MET Norway) | Worldwide | `0.5` | `1.0` | `1.0` | `1.0` | `1.0` | `1.0` |
| `dwd-brightsky:mosmix` (DWD MOSMIX) | DE / NL / Central Europe | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) |
| `eccc:hrdps` (ECCC GeoMet) | Canada | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) |

### 3.3 Regional 4-Band Horizon Profiles (`WxRegion`) & World Weights

Instead of a binary `US vs. Rest-of-World` split, [`Geo.swift`](WeatherCore/Core/Geo.swift) and [`Weights.swift`](WeatherCore/Blend/Weights.swift) classify every location into one of 8 meteorological domains (`WxRegion`) with 4-band lead-time horizon weights (`H0: 0–3h`, `H1: 3–18h`, `H2: 18–72h`, `H3: 72h+`) so that national convection-allowing models lead in short ranges (`0–48 h`) and gracefully hand off to `ECMWF IFS` and `DWD ICON` in medium/extended ranges (`72 h+`). In these regional profiles **relative humidity uses the same band weights as temperature** (a near-surface thermodynamic field the high-resolution models also resolve best), rather than the flat `1.0` of the US/world table:

| Region (`WxRegion`) | Leads H0 (0–3 h), temperature `[H0/H1/H2/H3]` | Leads H3 (72 h+) | Sub-Hourly 15-min Nowcast Model |
| :--- | :--- | :--- | :--- |
| `.canada` (Canada) | `eccc:hrdps` (`4/4/3.5/3.5`), `open-meteo:gem` (`4/4/3.5/3`), `open-meteo:hrrr` (`3/3/0.5/0`) | `eccc:hrdps` (`4/4/3.5/3.5`), `open-meteo:ecmwf` (`2/2.5/3.5/3.5`), `open-meteo:gem` (`4/4/3.5/3`) | `ncep_hrrr_conus` inside the HRRR domain, else Open-Meteo best match |
| `.ukIreland` (UK & Ireland) | `open-meteo:ukmo` (`4/4/3/2.5`), `open-meteo:ecmwf` (`3/3/3.5/3.5`), `met-no:ecmwf` (`2.5/2.5/2/2`) | `open-meteo:ecmwf` (`3/3/3.5/3.5`), `open-meteo:ukmo` (`4/4/3/2.5`), `met-no:ecmwf` (`2.5/2.5/2/2`) | `ukmo_seamless` |
| `.beneluxNorthSea` (Netherlands & Benelux) | `open-meteo:knmi` (`4/4/2/0`), `open-meteo:icon` (`3.5/3.5/3/2.5`), `dwd-brightsky:mosmix` (`3/3/2.5/2`) | `open-meteo:ecmwf` (`2.5/2.5/3.5/3.5`), `open-meteo:icon` (`3.5/3.5/3/2.5`), `dwd-brightsky:mosmix` (`3/3/2.5/2`) | `knmi_seamless` |
| `.centralEurope` (DE, AT, CH, LI, PL, CZ) | `open-meteo:icon` (`4/4/3.5/2.5`), `dwd-brightsky:mosmix` (`3.5/3.5/3/2.5`), `open-meteo:ecmwf` (`2.5/2.5/3.5/3.5`) | `open-meteo:ecmwf` (`2.5/2.5/3.5/3.5`), `dwd-brightsky:mosmix` (`3.5/3.5/3/2.5`), `open-meteo:icon` (`4/4/3.5/2.5`) | `icon_seamless` |
| `.nordic` (NO, SE, FI, DK, IS, FO, SJ) | `met-no:ecmwf` (`4/4/3/2.5`), `open-meteo:ecmwf` (`3/3/3.5/3.5`), `open-meteo:icon` (`2.5/2.5/2.5/2`) | `open-meteo:ecmwf` (`3/3/3.5/3.5`), `met-no:ecmwf` (`4/4/3/2.5`), `open-meteo:icon` (`2.5/2.5/2.5/2`) | Open-Meteo best match (lat ≤ 65°, lon −11…25°) |
| `.europeOther` (rest of Europe) | `open-meteo:ecmwf` (`3/3/3.5/3.5`), `open-meteo:icon` (`3/3/2.5/2.5`), `open-meteo:meteofrance` (`3/3/2.5/2`) | `open-meteo:ecmwf` (`3/3/3.5/3.5`), `open-meteo:icon` (`3/3/2.5/2.5`), `met-no:ecmwf` (`2/2/2/2`) | Open-Meteo best match (lat ≤ 65°, lon −11…25°) |

These rows are the three largest temperature weights of each profile, taken from the code. The complete per-model, per-variable tables of all eight profiles are generated from `WxWeights` into the Help Book (`scripts/help/weight_tables.py` → *Settings: Data Sources & Weights*), and `HelpBookTests` fails when they no longer match the code.

In `.world` (Rest of World), US/regional-only models receive weight `0.0`, while global models use flat horizon weights defined by `WORLD_MAIN(w)` (`[w, w, w, 1.0, w, 1.0]`). The `knmi`, `dwd-brightsky` and `eccc` rows below are their world baseline (shown in the Weights tab); `baseWeight(region: .world)` gives them `0.0`, since those models do not cover the rest of the world:

| Source : Model | `.temp` | `.wind` | `.cloud` | `.humidity` | `.precipMm` | `.precipProb` | Rationale |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| `open-meteo:ecmwf` | `3.0` | `3.0` | `3.0` | `1.0` | `3.0` | `1.0` | Highest global 500 hPa & surface verification skill (ECMWF Cy48r1). |
| `open-meteo:icon` | `2.5` | `2.5` | `2.5` | `1.0` | `2.5` | `1.0` | High-resolution non-hydrostatic icosahedral solver (Zängl et al., 2015). |
| `open-meteo:ukmo` | `2.0` | `2.0` | `2.0` | `1.0` | `2.0` | `1.0` | Strong global synoptic and marine boundary-layer performance. |
| `open-meteo:meteofrance` | `2.0` | `2.0` | `2.0` | `1.0` | `2.0` | `1.0` | Stretched-grid global ARPEGE + high-res European AROME. |
| `open-meteo:knmi` | `2.0` | `2.0` | `2.0` | `1.0` | `2.0` | `1.0` | KNMI HARMONIE-AROME Cy43 (2 km) nested into ECMWF IFS. |
| `open-meteo:gem` | `1.5` | `1.5` | `1.5` | `1.0` | `1.5` | `1.0` | Canadian GDPS/RDPS/HRDPS global-regional seamless suite. |
| `open-meteo:gfs` | `1.5` | `1.5` | `1.5` | `1.0` | `1.5` | `1.0` | FV3-based global spectral model. |
| `met-no:ecmwf` | `1.5` | `1.5` | `1.5` | `1.0` | `1.5` | `1.0` | MET Norway downscaled ECMWF + MEPS Nordic blend; kept at `1.5` so ECMWF (via Open-Meteo + MET Norway combined $= 4.5$) does not single-handedly exceed half the total ensemble weight ($13.5$). |
| `dwd-brightsky:mosmix` | `3.0` | `2.8` | `2.8` | `1.0` | `3.0` | `2.5` | DWD MOSMIX station-calibrated statistical post-processing + ICON-D2. |
| `eccc:hrdps` | `3.5` | `3.0` | `3.0` | `1.0` | `3.5` | `3.5` | Environment and Climate Change Canada MSC GeoMet Official Citypage & HRDPS. |
| Unknown `(src, model)` | `1.0` | `1.0` | `1.0` | `1.0` | `1.0` | `1.0` | `WxWeights.unknownWeight = 1.0`. |

**ECCC citypage forecasts (`ECCCProvider.swift`).** The place's own city is found with progressively wider boxes (0.2°, 0.6°, 1.4°; longitude ÷ cos lat, up to 20 cities each) and the nearest one is used, or none beyond 75 km (a narrow 4-city query used to return a neighbouring city, e.g. Richmond Hill for Toronto). Text forecasts contribute the forecaster's precipitation probability, sky cover and condition class; no precipitation **amount** is invented from wording such as "chance of showers".

### 3.4 User-Configurable Source & Model Multipliers (`WxWeightMultipliers`)

**Implementation:** [`Weights.swift:16-140`](WeatherCore/Blend/Weights.swift#L16-L140), [`AppModel.swift:874-919`](WeatherCore/App/AppModel.swift#L874-L919), [`SettingsView.swift`](Weather/Settings/SettingsView.swift)

In **Settings (`⌘,`)**, users can adjust:
- **Per-Source Multiplier** $M_{\text{src}}(\text{sourceID}) \in [0.00, 3.00]$ (default $1.00$)
- **Per-Model Multiplier** $M_{\text{model}}(\text{sourceID}, \text{modelID}) \in [0.00, 3.00]$ (default $1.00$)

The effective weight used by `WxWeights.weight(...)` is:
```math
w_{\text{eff}}(s, m, v, h, \text{us}) = w_{\text{base}}(s, m, v, h, \text{us}) \times M_{\text{src}}(s) \times M_{\text{model}}(s, m)
```
Custom multipliers are persisted atomically to `<configDirectory>/weather/weights.json` (keeping `settings.json` strictly compatible with the C schema) and immediately trigger `engine.sourcesChanged()` so active places re-blend.

---

## 4. 15-Minute HRRR Nowcast & Mass-Conserving Sub-Hourly Rescaling

**Implementation:** [`WeatherCore/Blend/Nowcast.swift`](WeatherCore/Blend/Nowcast.swift), [`WeatherCore/Providers/OpenMeteoProvider.swift`](WeatherCore/Providers/OpenMeteoProvider.swift)

### 4.1 Parallel CONUS Sub-Hourly Fetching (`OpenMeteoProvider`)

For places inside the Continental United States (`WxGeo.inCONUS`: $\text{lat} \in [24.0^\circ, 50.0^\circ]$, $\text{lon} \in [-125.0^\circ, -66.0^\circ]$, or `countryCode == "US"` within those bounds), `OpenMeteoProvider` issues two concurrent HTTPS requests:
- **Request A (Main Multi-Model Hourly):** Queries `ncep_hrrr_conus,ncep_nbm_conus,ecmwf_ifs,gfs_seamless,icon_seamless,gem_seamless` (every region requests ECMWF IFS at its native 9 km, `ecmwf_ifs`, rather than the 0.25° regrid `ecmwf_ifs025`).
- **Request B (15-Minute HRRR Nowcast):** Queries `models=ncep_hrrr_conus&minutely_15=precipitation&forecast_minutely_15=12` with a **2,000 ms grace window** (`nowcastGraceMs = 2000`) after Request A completes so a slow sub-hourly response never blocks the main forecast.

### 4.2 Contiguous Run Validation (`WxNowcast.extract`)

From the `hrrr15` member's quarter-hour slots (each $900\text{ s} = 15\text{ min}$, aligned to `:00`, `:15`, `:30`, `:45`), [`Nowcast.swift:52-135`](WeatherCore/Blend/Nowcast.swift#L52-L135) extracts the **first contiguous run** of valid quarter-hour slots starting at or before the current quarter $q_0 = \lfloor t_{\text{now}} / 900 \rfloor \times 900$:
- Every slot must satisfy $t_k = t_{k-1} + 900$ with finite $R_k \ge 0$ (`<= 500 mm`).
- **Minimum Horizon Coverage:** The contiguous run must reach at least $t_{\text{now}} + 1800\text{ s}$ ($30\text{ minutes}$ ahead) and is capped at `maxQuarters = 12` ($3\text{ hours}$).

### 4.3 Hourly Sum Substitution (`substituteHrrrHours`)

When the `hrrr15` run contains all 4 quarter-hours $[H, H+900, H+1800, H+2700]$ of an aligned UTC hour $H$, their sum:
```math
R_{\text{HRRR}, H} = \sum_{j=0}^{3} q_{H + 900j}
```
replaces the hourly `open-meteo:hrrr` member's `precipMm` at hour $H$ **before** multi-model ensemble blending.

### 4.4 Mass-Conserving Quarter Rescaling (`rescaleQuarters`)

After multi-model blending produces the consensus hourly precipitation $B_H$ at hour $H$, the 4 sub-hourly quarters $q_0, q_1, q_2, q_3$ must be rescaled so their sum equals $B_H$ to machine precision (`sum(rescaled) == B_H`) while preserving sub-hourly temporal structure ([`Nowcast.swift:175-238`](WeatherCore/Blend/Nowcast.swift#L175-L238)):

Let $S = q_0 + q_1 + q_2 + q_3$ be the raw quarter sum:
1. **Dry / Near-Zero Raw Sum ($S \le 10^{-9}\text{ mm}$, `rawZeroMm = 1e-9`):**  
   The blended hourly total is distributed equally across all 4 quarters:

   $`\displaystyle q'_j = \frac{B_H}{4}, \qquad j \in \{0, 1, 2, 3\}`$

2. **Wet Raw Sum ($S > 10^{-9}\text{ mm}$):**  
   Let $`j^* = \arg\max_{j \in \{0,1,2,3\}} q_j`$ be the **first largest quarter**. The other three quarters are scaled proportionally, and the largest quarter absorbs the exact floating-point remainder:

   $`\displaystyle q'_j = q_j \cdot \frac{B_H}{S} \quad (j \neq j^*), \qquad q'_{j^*} = \max\!\left(0,\; B_H - \sum_{j \neq j^*} q'_j\right)`$

   This guarantees $\sum_{j=0}^3 q'_j = B_H$ without rounding drift.

---

## 5. Sky Condition Derivation, Hydrometeor Classification & Daily Aggregation

**Implementation:** [`WeatherCore/Blend/ConditionRules.swift`](WeatherCore/Blend/ConditionRules.swift), [`WeatherCore/Blend/Daily.swift`](WeatherCore/Blend/Daily.swift), [`WeatherCore/Blend/RainRules.swift`](WeatherCore/Blend/RainRules.swift)

### 5.1 WMO Code 4677 Consensus Voting & Hydrometeor Rules (`WxConditionRules.derive`)

Each hourly slot's `WxCondition` is derived by combining WMO Code Table 4677 weather codes (`wmoCode`) from the ensemble members with the blended physical variables (`tempC`, `cloudPct`, `precipMm`, `precipProb`):

1. **Thunderstorm Majority Vote (`{95, 96, 97, 99}`):**  
   If at least half (`hits * 2 >= supplied`) of the members reporting a valid WMO code at hour $t_S$ report a thunderstorm code, the condition is `.thunderstorm`.
2. **Snow Majority Vote (`{71, 73, 75, 77, 85, 86}`) Gated by Temperature:**  
   If at least half of WMO-reporting members report snow **and** the blended temperature is not above `snowMaxTempC = 2.0 °C` ($T \le 2.0^\circ\text{C}$), the condition is `.snow`.
3. **Sleet / Freezing Rain Majority Vote (`{56, 57, 66, 67}`):**  
   If at least half of WMO-reporting members report freezing drizzle or freezing rain, the condition is `.sleet`.
4. **Wet-Hour Threshold (`isWetHour`):**  
   An hour is classified as **wet** if and only if:

   $`\displaystyle \text{precipMm} \ge 0.1\text{ mm/h} \quad \land \quad \left(\text{precipProb} \ge 30.0\% \;\lor\; \text{precipProb is NaN}\right)`$

   When an hour is wet and no WMO majority selected thunderstorm/snow/sleet:
   - If $T < 0.0^\circ\text{C}$ (`freezeTempC = 0.0`): `.snow`
   - If $0.0^\circ\text{C} \le T < 1.5^\circ\text{C}$ (`sleetMaxTempC = 1.5`): `.sleet`
   - If $T \ge 1.5^\circ\text{C}$ (or `tempC` is `NaN`):
     - **Showers vs. Steady Rain:** Classified as `.showers` when cloud cover is broken (`cloudPct < 87.5%`, `oktas7CloudPct = 87.5`, i.e. $< 7\text{ oktas}$) **and** rain rate is below heavy (`precipMm < 7.6 mm/h`); otherwise classified as steady `.rain` (`heavyRainMmH`).
5. **Dry-Hour Fog & Cloud Oktas:**  
   When an hour is dry:
   - If at least half of WMO-reporting members report fog (`{45, 48}`): `.fog`.
   - Otherwise, classified by blended cloud cover percentage (`cloudCondition`):
     - `cloudPct < 20.0%` (`clearCloudPct`): `.clear`
     - `20.0% <= cloudPct < 60.0%` (`partlyCloudyPct`): `.partlyCloudy`
     - `60.0% <= cloudPct < 85.0%` (`mostlyCloudyPct`): `.mostlyCloudy`
     - `cloudPct >= 85.0%`: `.overcast`

### 5.2 Daily Roll-Up & Severe Persistence (`WxDaily.buildDays`)

**Implementation:** [`Daily.swift:32-215`](WeatherCore/Blend/Daily.swift#L32-L215)

Hours are grouped into local civil calendar days (`[midnight, next_midnight)`) in the place's IANA timezone, accounting for Daylight Saving Time transitions (23-hour spring-forward and 25-hour fall-back days via binary search on `TimeZone.secondsFromGMT`).
- **Minimum Coverage:** A calendar day requires at least `minHoursPerDay = 6` hours in the forecast (except "today", which is always included if $\ge 1$ hour remains).
- **Daily Condition Selection (`dayCondition`):**
  1. **Severe Persistence Rule:** If **any** hour of the day has `.thunderstorm`, `.snow`, or `.sleet`, the most frequent severe condition wins (`thunderstorm > snow > sleet` on ties) so hazardous weather is never hidden by a mostly-sunny afternoon.
  2. **Wet-Hour Count Rule:** If $\ge 3$ hours of the day are wet (or $\ge 1$ wet hour on a short partial day with $< 6$ hours), the most frequent wet condition wins.
  3. **Daylight Cloud Cover:** Otherwise, derived from the mean `cloudPct` across daylight hours (`isDay == true`), falling back to all hours in polar night.

### 5.3 48-Hour Rain Outlook State Machine (`WxRainRules.outlook`)

**Implementation:** [`RainRules.swift:45-268`](WeatherCore/Blend/RainRules.swift#L45-L268)

Scans a 48-hour window $[t_{\text{now}}, t_{\text{now}} + 48\text{ h}]$ (using 15-minute `quarters` where available and `hours` elsewhere):

| Rain Intensity Tier | Rate Interval ($\text{mm/h}$) | AMS / WMO Equivalence |
| :--- | :--- | :--- |
| `.none` | $< 0.1\text{ mm/h}$ | Trace / Dry (`wetMmH = 0.1`) |
| `.light` | $[0.1, 2.5)\text{ mm/h}$ | Light rain (`lightMaxMmH = 2.5`) |
| `.moderate` | $[2.5, 7.6)\text{ mm/h}$ | Moderate rain (`moderateMaxMmH = 7.6`) |
| `.heavy` | $\ge 7.6\text{ mm/h}$ | Heavy rain ($\ge 0.30\text{ in/h}$) |

The state machine transitions into one of 5 states:
- `.now`: Currently wet at $t_{\text{now}}$; computes `endS` (first dry slot after the current wet spell, or $0$ if wet through the end of coverage) and `peakS` / `peakIntensity`.
- `.expected`: Dry now, but a wet slot (`>= 0.5 mm/h` for quarters, or `>= 0.1 mm/h` with `prob >= 30%` for hours) begins within 48 hours; records `startS`, `endS`, `peakS`, `peakIntensity`, and `probabilityMax`.
- `.possible`: No slot meets the wet-amount threshold, but at least one hour in the next 48 hours has `precipProb >= 50.0%` (`possibleProbPct = 50.0`).
- `.dry`: Full 48-hour coverage is present with no wet or possible slots.
- `.unavailable`: Coverage is incomplete ($< 48\text{ h}$) or contains `NaN` gaps with no rain detected before the gap.

---

## 6. Live Physical Station Assimilation & 3D Anisotropic Kernel Fusion

**Implementation:** [`WeatherCore/Blend/StationFusion.swift`](WeatherCore/Blend/StationFusion.swift) (the fusion, pure), [`WeatherCore/Providers/StationNetworks.swift`](WeatherCore/Providers/StationNetworks.swift) (request builders and parsers), [`WeatherCore/Storage/StationCatalog.swift`](WeatherCore/Storage/StationCatalog.swift) (station health), [`WeatherCore/Blend/LocalBias.swift`](WeatherCore/Blend/LocalBias.swift) (learned forecast bias), [`Weather/Detail/StationNetworkFetcher.swift`](Weather/Detail/StationNetworkFetcher.swift) and [`Weather/Detail/LiveStationFetcher.swift`](Weather/Detail/LiveStationFetcher.swift) (HTTP and orchestration)

While `WeatherCore` produces the multi-model NWP grid blend, the station layer grounds the "now" values (and, through §6.9, the forecast) in real observations. **Every country goes through the same pool and the same algorithm**; what differs is only which networks cover the place. Ten networks are keyless; five more are used once the user saves their own free key in Settings › Stations (§6.10).

| Network (`WxStationNetwork`) | Coverage | Cadence | Endpoint | Trust prior (temp / wind) |
| :--- | :--- | :--- | :--- | :--- |
| `metar` | Worldwide airports | hourly + specials | `aviationweather.gov/api/data/metar` (one bbox query covering 95 km; longitude half-width ÷ cos lat) | 1.0 / 1.0 |
| `nwsASOS` | US airports (3 nearest) | 5 min | `api.weather.gov/stations/{id}/observations/latest` (MADIS QC flags X/Q/B dropped) | 1.0 / 1.0 |
| `iemMesonet` | US non-airport networks | 5–60 min | `mesonet.agron.iastate.edu/api/1/currents.json?wfo=XXX` (one request per NWS forecast office, from `/points` `cwa`) | USCRN 1.0/0.8, SCAN/ISUSM 0.85/0.6, RWIS 0.6/0.35, DCP 0.5/0.3; ASOS/AWOS/COOP skipped |
| `ecccSWOB` | Canada | 1–60 min | `api.weather.gc.ca` SWOB real-time collection | MSC, NAV CANADA, DND 1.0; partner networks 0.6 / 0.35 |
| `dwdSYNOP` | Germany (+ border margin) | 10 min | Bright Sky `sources` → up to 8 nearest live SYNOP → `current_weather?source_id=` (`fallback_source_ids` values dropped) | 1.0 |
| `dmi` | Denmark | 10 min | `opendataapi.dmi.dk/v2/metObs` | Synop 1.0, others 0.9 |
| `fmi` | Finland | 10 min | `opendata.fmi.fi/wfs` multipointcoverage | 1.0 |
| `smhi` | Sweden | hourly | `opendata-download-metobs.smhi.se` latest-hour, all stations, 8 parameters | CORE 1.0, ADDITIONAL 0.9 |
| `geosphere` | Austria | 10 min | `dataset.api.hub.geosphere.at` TAWES current | 1.0 |
| `meteoSwiss` | Switzerland | 10 min | `data.geo.admin.ch` open data per-station `ogd-smn_<abbr>_t_now.csv` | 1.0 |
| `metOffice` (key) | United Kingdom | hourly | Weather DataHub Land Observations, header `apikey`: `observation-land/1/nearest?lat=&lon=&max=5` (2 dp; cached 7 days) → `observation-land/1/{geohash}` for at most the 3 nearest stations (each cached 1 h; the free plan allows 360 calls a day). Stations are identified by geohash, decoded to their position; the 0–30 weather code gives condition and cloud | 1.0 |
| `knmi` (key) | Netherlands | 10 min | KNMI EDR API, header `Authorization: <key>`: `collections/10-minute-in-situ-meteorological-observations/cube?bbox=…&datetime=<last hour>&parameter-name=ta,t10,rh,rh10,td,td10,ff,gff,fx,rg,n,nc,ww` (CoverageJSON; cached 5 min) and `/locations` (names, heights; 24 h). An Open Data API key is refused (403) | 1.0 |
| `frost` (key) | Norway | 10 min – hourly | Frost API, HTTP Basic `client_id:`: `sources/v0.jsonld?…nearest(POINT(lon lat))` (40 sensor systems; 24 h) → `observations/v0.jsonld?referencetime=latest&maxage=PT3H` (5 min); main sensor, quality code < 5, 2 m temperature and 10 m wind preferred | MET Norway 1.0; other station holders 0.7 / 0.4 |
| `meteoFrance` (key) | France | 6 min | Météo-France DPPaquetObs v2, header `apikey`: `paquet/stations/infrahoraire-6m?date=<newest 6-min slot at least 10 min old>` (all of France, ~2,000 stations; cached 6 min) and `liste-stations` (CSV; 24 h). Kelvin → °C, 6-min rain × 10 → mm/h | RADOME 1.0; ETENDU 0.85 / 0.6 |
| `aemet` (key) | Spain | hourly | AEMET OpenData, header `api_key`: `observacion/convencional/todas` returns an envelope whose `datos` URL (followed only on `opendata.aemet.es`) holds all ~830 stations; ISO-8859-15 tolerated; an expired data URL is retried once; cached 15 min | 1.0 |

National networks are queried inside boxes with a ~50 km margin beyond the border, so places near a border also get the neighbour's stations. Responses are cached per URL (120–600 s for reports, 24 h for station lists) with in-flight request sharing; a network that cannot be reached falls back to its readings of the last 90 minutes in the station catalog (§6.7). Station elevations missing from a network come from the Open-Meteo elevation API (Copernicus DEM) and are kept in the catalog. Also fused (§6.6): **Open-Meteo 90 m DEM downscaled current analysis**; air quality uses **US EPA AirNow** monitors with an Open-Meteo CAMS fallback (§8.2).

### 6.1 Same-Site Merge and the 3D Anisotropic Spatial Kernel

Reports older than the age limit are dropped **before** the same-site merge. Reports closer than $1.5\text{ km}$ are then one site (an airport METAR and its ASOS/SYNOP/SWOB twin): the freshest report wins and older ones only fill variables it lacks — present weather is borrowed from a twin only when that report is at most $90\text{ min}$ old; the site's trust is the best of its sensors.

Station $i$ at great-circle distance $d_i$ (km) and elevation difference $\Delta z_i = z_{\text{target}} - z_i$ (m, clamped to $\pm 1800$) receives

```math
W_{\text{horiz}}(d_i) = \exp\!\left(-\frac{d_i^2}{2 L_h^2}\right) \cdot \frac{1}{1 + (d_i / d_0)^2}, \qquad L_h = 22.0\text{ km},\quad d_0 = 8.0\text{ km}
```

```math
W_{\text{vert}}(\Delta z_i) = \exp\!\left(-\frac{\Delta z_i^2}{2 L_z^2}\right), \qquad L_z = 350.0\text{ m}
```

```math
W_{\text{prior},i} = W_{\text{horiz}}(d_i) \cdot W_{\text{vert}}(\Delta z_i) \cdot \text{trust}_i \cdot \text{health}_i
```

where `trust` is the network-class prior of the table above and `health` the station's measured track record (§6.7). Candidates must lie within $95\text{ km}$ and be at most $3\text{ h}$ old. **The pool** is the $12$ sites of largest $W_{\text{prior}}$ within $60\text{ km}$ (not merely the nearest, so a crowd of low-trust gauges cannot push out a first-class station a little farther away); if none is that close, the nearest usable site alone.

- **Why Cauchy × Gaussian horizontally?** The inner Cauchy factor provides sharp localization when a station is within a few kilometers, while the outer Gaussian smoothly suppresses stations beyond $50\text{ km}$.
- **Why $L_z = 350\text{ m}$?** Boundary layers decouple across ridges and inversions (~300–400 m deep); a station $700\text{ m}$ above the target is attenuated by $e^{-2} \approx 0.135$.

### 6.2 Diurnal Boundary-Layer Lapse Rate Elevation Correction

Temperatures and dewpoints are reduced to the target elevation before blending:

```math
T_{\text{reduced},i} = T_i + \Gamma_T \cdot \Delta z_i, \qquad \Gamma_T = \begin{cases} -0.0068\text{ }^\circ\text{C/m} & \text{sun up (mixed boundary layer)} \\ -0.0042\text{ }^\circ\text{C/m} & \text{night (stable boundary layer)} \end{cases}
```

```math
T_{d,\text{reduced},i} = \min\!\big(T_{\text{reduced},i},\; T_{d,i} - 0.0019 \cdot \Delta z_i\big)
```

A station $300\text{ m}$ above the target ($\Delta z = -300$) is warmed by $`2.0\,^\circ\text{C}`$ by day and $`1.3\,^\circ\text{C}`$ at night. A dewpoint missing from a report is derived from its relative humidity (Magnus, §7.1).

### 6.3 Shepard (1968) Directional De-Clustering

A tight cluster of sites on one bearing must not outvote an isolated site on the other side. With $\theta_i$ the bearing from the target to site $i$:

```math
S_i = \sum_{j \neq i} \min\!\left(3,\; \sqrt{\frac{W_{\text{prior},j}}{W_{\text{prior},i}}}\right) \cdot \left(\frac{1 + \cos(\theta_i - \theta_j)}{2}\right)^{4}, \qquad W_{\text{dir},i} = \frac{1}{1 + S_i}
```

A site shadowed by a stronger one on the same bearing loses weight; a site alone in its direction keeps $W_{\text{dir}} = 1$.

### 6.4 Variable-Specific Temporal Exponential Decay

For observation age $\Delta t_i$ (a report without a time counts as $20\text{ min}$ old):

```math
W_{\text{time},i}^{(\text{var})} = \exp\!\left(-\frac{\Delta t_i}{\tau_{\text{var}}}\right), \qquad \tau_{\text{temp}} = 2700\text{ s},\quad \tau_{\text{wind}} = 1200\text{ s},\quad \tau_{\text{sky/precip}} = 900\text{ s}
```

Wind is further weighted by $\text{windTrust}_i / \text{trust}_i$ (many road-weather and hydrological sites measure wind well below 10 m). The gust is the mean wind plus the weighted RMS gust excess, reported only when that excess is at least $3.5\text{ km/h}$. Wind direction is fused as a vector, never as an average of degrees (§6.4.1 below). Present weather comes from the nearest site that codes weather, within $38\text{ km}$ and $90\text{ min}$ (its "no weather" counts; sites that never code weather are skipped). An automated station's ceilometer sees only low cloud: its "mostly clear" report ($`< 25\%`$) under substantial model cloud aloft ($`> 30\%`$) is combined with that cloud by random overlap (§8.1).

#### 6.4.1 Wind Direction as a Speed-Weighted Vector Mean

Each report with speed $V_i > 0$ and a direction $\theta_i$ (the bearing the wind blows **from**) contributes the vector $V_i(\sin\theta_i, \cos\theta_i)$ with the wind weight $w_i$ above. A calm report ($V_i = 0$) is a zero vector whose weight still counts; a moving report without a direction is left out. With $\bar u$, $\bar v$ and $\bar V$ the weighted means of $V_i\sin\theta_i$, $V_i\cos\theta_i$ and $V_i$ over those reports:

```math
\theta = \mathrm{atan2}(\bar u, \bar v) \bmod 360^\circ, \qquad R = \sqrt{\bar u^2 + \bar v^2}
```

$\theta$ is reported only when $R \ge 1\text{ km/h}$ (otherwise the air is calm) and $`R \ge 0.25\,\bar V`$ (otherwise the directions are too spread or opposed), so $350^\circ$ and $10^\circ$ fuse to $0^\circ$, never $180^\circ$. A site's speed and direction always come from the same report (the same-site merge copies them together), and each network's direction is read from the same averaging window as its speed. In the "now" card the stations' direction falls back to Open-Meteo's current `wind_direction_10m`; with neither, no arrow is drawn. Directions stay out of the hourly forecast blend and its cache.

### 6.5 Robust Buddy Check (Median Absolute Deviation)

With $N \ge 3$ sites in the pool, from the elevation-reduced temperatures:

```math
M = \mathrm{median}_i\, T_{\text{reduced},i}, \qquad \sigma = \max\!\big(1.5\,^\circ\text{C},\; 1.4826 \cdot \mathrm{median}_i |T_{\text{reduced},i} - M|\big), \qquad r_i = |T_{\text{reduced},i} - M|
```

```math
W_{\text{QC},i} = \begin{cases} 1 & r_i \le 3\sigma \\[4pt] \left(\dfrac{3\sigma}{r_i}\right)^{2} & r_i > 3\sigma \end{cases}
```

The floor keeps real mesoscale contrasts of up to $`4.5\,^\circ\text{C}`$ (sea breeze, urban heat island, cold-air pool) unpenalized; the penalty only catches gross errors (a sun-baked, indoor or failed sensor). Persistent smaller errors are the job of the health record (§6.7). Each site's weight is $W_i = W_{\text{prior},i} \cdot W_{\text{dir},i} \cdot W_{\text{QC},i} \cdot W_{\text{time},i}^{(\text{var})}$.

### 6.6 Observation-to-Model Fusion and Short-Range Bias Decay

The pool's kernel-weighted **effective distance** $\bar d$ and **effective age** $\bar t$ (weighted means over the temperature weights) set the confidence in the stations against Open-Meteo's 90 m DEM downscaled analysis:

```math
\alpha_{\text{obs}} = \mathrm{clamp}_{[0.35,\, 0.95]}\!\left(0.35 + 0.60 \cdot \exp\!\left(-\left(\frac{\bar d}{38\text{ km}}\right)^{2}\right) \cdot \exp\!\left(-\frac{\bar t}{3600\text{ s}}\right)\right), \qquad X_{\text{fused}} = \alpha_{\text{obs}} X_{\text{obs}} + (1 - \alpha_{\text{obs}}) X_{\text{model}}
```

for temperature, humidity and wind ($\alpha \approx 0.95$ at $0\text{ km}$, $0.74$ at $25\text{ km}$, $0.40$ at $60\text{ km}$ for fresh reports). Following **Model Output Statistics** nowcast practice (Glahn & Lowry, 1972), the remaining innovation $\Delta T_0 = T_{\text{fused}} - T_{\text{forecast}}(t_{\text{now}})$ (clamped to $`\pm 8\,^\circ\text{C}`$) is carried into the next 6 hours of the strip with

```math
T(t_k) = T_{\text{forecast}}(t_k) + \Delta T_0 \cdot \exp\!\left(-\frac{t_k - t_{\text{now}}}{3.5\text{ h}}\right)
```

where $T_{\text{forecast}}$ already includes the learned local bias (§6.9), so the two never double-count.

### 6.7 Station Catalog: Reachability, Testing and Health (`WxStationCatalog`)

Every station ever retrieved is kept in `<config>/weather/stations.json` (at most 6000 records) with its metadata, DEM elevation, last report and track record.

- **Reachability.** Each fetch records which stations it was expected to return (its box, its forecast-office area, or its requested ids). An expected station that did not report accumulates silence by the time since the previous check, **at most 1 h per check**, so time with the app closed never counts; after $72\text{ h}$ of silence while the app was checking, the station is dropped. A new report resets the clock; a returning station starts again on probation.
- **Leave-one-out testing (`WxStationFusion.crossValidate`).** On every refresh, each site with at least two usable neighbours within $40\text{ km}$ (reports at most $90\text{ min}$ old) is predicted from its neighbours with the same kernel, trust, health, Shepard and buddy check; the residual $e = T_{\text{reduced}} - \hat T$ (clipped to $`\pm 15\,^\circ\text{C}`$) updates the station's record (at most once per $9\text{ min}$) as exponentially weighted moving averages ($`\alpha = \max(0.08,\, 1/(n+1))`$) of the bias, kept **separately by day and by night** (a sun-exposed sensor is only wrong by day), and of the squared error.
- **Health.** After 3 tests, with $E = \sqrt{\text{bias}^2 + \text{scatter}^2}$ (the bias of the current day/night half once it has 3 tests, else the overall mean bias; the scatter from the mean squared error):

```math
\text{health} = \underbrace{\min\!\left(1,\; 0.6 + 0.4\,\frac{n_{\text{tests}}}{6}\right)}_{\text{probation}} \cdot \begin{cases} 1 & E \le 1.5\,^\circ\text{C} \\[2pt] \dfrac{1}{1 + \left(\frac{E - 1.5}{1.5}\right)^{2}} & 1.5 < E < 8 \\[6pt] 0 & E \ge 8\,^\circ\text{C} \end{cases} \cdot \underbrace{[\text{not stuck}]}_{\text{not METAR/ASOS, unchanged} \ge 8\text{ h} \Rightarrow 0}
```

METARs and NWS ASOS 5-minute reports (whole degrees, often steady overnight) are exempt from the stuck test. Health multiplies the prior weight (§6.1) in both the blend and the cross-validation.

### 6.8 Station Credits

The forecast page credits every network whose reports could enter the blend ([`StationNetworks.swift`](WeatherCore/Providers/StationNetworks.swift) `credits(for:)`): NOAA AWC / NWS and the Iowa Environmental Mesonet (public domain, credit appreciated); Environment and Climate Change Canada's Data Server End-use Licence statement, linked to the licence; DWD, DMI, FMI, SMHI, GeoSphere Austria, MeteoSwiss, KNMI ("Source: KNMI", linked to the dataset) and MET Norway ("Data from The Norwegian Meteorological Institute") by name (CC BY 4.0), followed by one CC BY 4.0 link noting that the readings are quality-checked and blended; "Powered by Met Office data" (DataHub licence); and "Source: Météo-France" and "Source: AEMET" with the time of the network's newest report used (`credits(for:newestReportS:)`, e.g. ", data of 25 Oct 14:00 UTC"), since Licence Ouverte 2.0 and AEMET's legal notice require the source and the date of the data. The snapshot keeps each network's newest report time for this. The Air Quality card adds its own credit (§8.2).

### 6.9 Learned Local Forecast Bias (`WxLocalBias`)

Models carry systematic local errors that one grid point cannot see (a valley that runs $`3\,^\circ\text{C}`$ colder at dawn, a coast that stays warmer at night). When the station pool is close and fresh ($\bar d \le 25\text{ km}$, $\bar t \le 45\text{ min}$), the fused station temperature is compared with the **uncorrected** model blend at that moment, and the error $e = T_{\text{obs}} - T_{\text{model}}$ is learned per place in **24 mean-solar-hour bins**:

- **Sampling:** at most one sample per bin every $20\text{ min}$; $`|e| > 10\,^\circ\text{C}`$ is rejected as implausible; $b_h \leftarrow b_h + \alpha (e - b_h)$ with $`\alpha = \max(0.07,\, 1/(n_h+1))`$ (a plain mean for the first samples, then a ~2-week memory).
- **Applying:** the correction at solar hour $h$ is the $[1, 2, 1]$-smoothed bias of bins $h-1, h, h+1$, with an effective sample count $n_{\text{eff}} = n_h + \tfrac12(n_{h-1} + n_{h+1})$; nothing is applied below $n_{\text{eff}} = 3$, confidence $\min(1, n_{\text{eff}}/6)$ above; the correction is capped at $`\pm 4\,^\circ\text{C}`$.
- **Staleness:** a place not updated for more than 30 days (the season has changed) fades with an e-folding time of 30 days until new samples arrive.
- **Effect:** every forecast hour's temperature and feels-like are shifted by the correction of its solar hour, and the days (highs/lows) are rebuilt from the shifted hours (`WxDaily.build`). `AppModel.Place.modelForecast` keeps the raw blend; `Place.forecast` (what every view shows) is the corrected one. The record is saved in `<config>/weather/local-bias.json`, survives restarts, and is deleted with its place. Learning happens on each Mac while the app runs.

### 6.10 Networks That Need the User's Key

**Implementation:** [`KeyedStationNetworks.swift`](WeatherCore/Providers/KeyedStationNetworks.swift) (pure URL builders and parsers, tested against real and published responses), [`StationNetworkInfo.swift`](WeatherCore/Providers/StationNetworkInfo.swift) (names, coverage, and the sign-up steps and limits shown in Settings and the Help Book), [`StationKeys.swift`](Weather/Detail/StationKeys.swift) (Keychain), [`StationNetworkFetcher.swift`](Weather/Detail/StationNetworkFetcher.swift).

- **Keys** live in the login Keychain (generic passwords, service `io.github.wtp128pro.Weather.station-keys`, account = the network's raw value), are trimmed on save, never logged, and sent only to their own host over HTTPS. The HTTP cache key includes the request headers, so a replaced key is never answered from the old key's cache. AEMET and Météo-France keys are JSON Web Tokens: their `exp` claim is read (not verified) to show the expiry in Settings.
- **Gathering.** `StationNetworkFetcher.gather(…, configuration:)` skips networks the user turned off and keyed networks without a key, and records each network's outcome (`StationNetworkStatus`: ok with the report count, key refused (401/403, or AEMET's empty answer), rate limited (429), failed, unreachable) with its time and place for the Stations tab. A key or switch change bumps `LiveStationStore.configRevision`, so every place is fetched again.
- **Budgets.** The fetchers stay far inside the free plans: Met Office at most 3 stations per place, each at most hourly; KNMI one box query per 5 min; Frost two requests per place per 5 min; Météo-France one national 6-minute package per 6 min; AEMET two requests per 15 min. A network that cannot be reached contributes its catalog readings of the last 90 minutes (§6.7), as the keyless ones do.
- **Not used:** the Met Office's keyless AWS bucket (1–2 h behind, no gusts, CC BY-SA), and keyless Météo-France files (rebuilt once a day).

### 6.11 Settings › Stations

**Implementation:** [`StationsSettingsTab.swift`](Weather/Settings/StationsSettingsTab.swift), [`StationSettings.swift`](WeatherCore/Storage/StationSettings.swift), `AppModel` (`stationSettings`, `localCorrections`).

- **Learned Local Corrections:** on/off for all places (`WxStationSettings.localCorrectionsEnabled`; learning continues while off, and `AppModel.shown` applies the bias only when on), and per place a status (`WxLocalBias.summary`), the correction now, today's 24 local clock hours as bars (`WxLocalBias.samples`), Reset and Reset All.
- **Networks** with and without a key: key entry (Save / Replace / Remove), the expiry, the service's sign-up steps, an on/off switch per network (`WxStationSettings.disabledNetworks`) and the status line.
- **Stations near the selected place** (`WxStationCatalog.nearby`, 60 km): each station's weight and why (`WxStationCatalog.assessment`: probation, good, reduced, excluded, stuck), and Forget All Stations (`removeAll()`).
- The settings are saved in `<config>/weather/station-settings.json`.

---

## 7. Psychrometrics, Thermodynamics & Apparent Temperature

**Implementation:** [`Weather/Detail/LiveStationFetcher.swift:485-580`](Weather/Detail/LiveStationFetcher.swift#L485-L580)

### 7.1 Magnus-Tetens Saturation Vapor Pressure (Alduchov & Eskridge, 1996)

Given dry-bulb temperature $T$ ($^\circ\text{C}$) and dewpoint temperature $T_d$ ($^\circ\text{C}$), relative humidity $`\text{RH} \in [0, 100]\%`$ is computed via the improved **Alduchov & Eskridge (1996)** Magnus coefficients ($a = 17.625$, $b = 243.04^\circ\text{C}$):

```math
\text{RH}(T, T_d) = 100 \cdot \exp\!\left(\frac{17.625 \, T_d}{243.04 + T_d} - \frac{17.625 \, T}{243.04 + T}\right)
```

Conversely, when inverting $(T, \text{RH})$ to obtain dewpoint $T_d$:

```math
\gamma(T, \text{RH}) = \ln\!\left(\frac{\text{RH}}{100}\right) + \frac{17.625 \, T}{243.04 + T}, \qquad T_d = \frac{243.04 \, \gamma(T, \text{RH})}{17.625 - \gamma(T, \text{RH})}
```

### 7.2 Psychrometric Wet-Bulb Temperature (Stull, 2011)

Displayed on the Humidity card alongside the dewpoint, the thermodynamic wet-bulb temperature $T_w$ ($^\circ\text{C}$) is evaluated using **Stull's (2011)** empirical inverse psychrometric formula (accurate to $\pm 0.3^\circ\text{C}$ across $`\text{RH} \in [5\%, 99\%]`$ and $T \in [-20^\circ\text{C}, 50^\circ\text{C}]$):

```math
\begin{aligned}
T_w &= T \arctan\!\Big(0.151977 \sqrt{\text{RH} + 8.313659}\Big) + \arctan(T + \text{RH}) - \arctan(\text{RH} - 1.676331)
\\ &\quad + 0.00391838 \, \text{RH}^{3/2} \arctan(0.023101 \, \text{RH}) - 4.686035
\end{aligned}
```

### 7.3 NWS Heat Index (Rothfusz, 1990) & Wind Chill (Osczevski & Bluestein, 2005)

To compute apparent ("Feels Like") temperature from assimilated surface observations $(T, \text{RH}, V_{\text{km/h}})$:

1. **Cold Regime ($T \le 10.0^\circ\text{C}$ and $V > 4.8\text{ km/h}$):**  
   Uses the North American **NWS / Environment Canada Wind Chill Index** (Osczevski & Bluestein, 2005):

   $`\displaystyle T_{\text{wc}} = 13.12 + 0.6215 \, T - 11.37 \, V^{0.16} + 0.3965 \, T \, V^{0.16} \quad (^\circ\text{C})`$

2. **Warm Regime ($T \ge 26.7^\circ\text{C} = 80^\circ\text{F}$ and $`\text{RH} \ge 40\%`$):**  
   Converts $T$ to Fahrenheit $T_F = 1.8 T + 32$ and evaluates the **NWS Rothfusz (1990)** Steadman multiple regression polynomial:

   $`\displaystyle \begin{aligned}
   \text{HI}_F &= -42.379 + 2.04901523 \, T_F + 10.14333127 \, R - 0.22475541 \, T_F R
   \\ &\quad - 0.00683783 \, T_F^2 - 0.05481717 \, R^2 + 0.00122874 \, T_F^2 R
   \\ &\quad + 0.00085282 \, T_F R^2 - 0.00000199 \, T_F^2 R^2
   \end{aligned}`$

   with standard NWS low-humidity ($`R < 13\%, T_F \in [80, 112]^\circ\text{F}`$) and high-humidity ($`R > 85\%, T_F \in [80, 87]^\circ\text{F}`$) adjustments.
3. **Turbulent Gust Excess Blending:**  
   Station wind speed and gusts are blended separately: sustained wind $V$ is blended linearly across stations, while turbulent gust excess $\Delta G_i = \max(0, G_i - V_i)$ is combined via **root-mean-square (RMS)** turbulent kinetic energy scaling:

   $`\displaystyle G_{\text{blended}} = V_{\text{blended}} + \sqrt{\frac{\sum_i w_i (\Delta G_i)^2}{\sum_i w_i}}`$

---

## 8. Radiative Cloud Transmittance & the Air Quality Card

**Implementation:** [`Weather/Detail/LiveStationFetcher.swift`](Weather/Detail/LiveStationFetcher.swift) (cloud cover, HTTP), [`WeatherCore/Providers/AirQuality.swift`](WeatherCore/Providers/AirQuality.swift) (air quality, pure)

### 8.1 Multi-Layer Random-Overlap Radiative Cloud Cover

Aviation METAR reports provide up to 4 cloud decks (`FEW` $= 1\text{–}2$ oktas $`\approx 18\%`$, `SCT` $= 3\text{–}4$ oktas $`\approx 44\%`$, `BKN` $= 5\text{–}7$ oktas $`\approx 75\%`$, `OVC` $= 8$ oktas $`= 100\%`$, `CLR`/`SKC`/`CAVOK` $`= 0\%`$) with cloud base height in feet AGL. High thin cirrus (`> 18,000 ft`) has much higher shortwave solar transmittance than low stratus (`< 6,500 ft`). We model the effective radiative cloud fraction $C_{\text{eff}}$ via **random-overlap radiative transmittance**:

```math
C_{\text{eff}} = 100 \cdot \left(1 - \prod_{k=1}^{K} \big(1 - \alpha_k \, c_k\big)\right)
```

where $c_k \in [0, 1]$ is layer $k$'s geometric sky fraction and $\alpha_k$ is its altitude-dependent optical opacity weight:
- Low deck ($z_{\text{base}} < 6{,}500\text{ ft}$): $\alpha_k = 1.00$
- Mid deck ($6{,}500\text{ ft} \le z_{\text{base}} < 18{,}000\text{ ft}$): $\alpha_k = 0.85$
- High cirrus deck ($z_{\text{base}} \ge 18{,}000\text{ ft}$): $\alpha_k = 0.55$

### 8.2 The Air Quality Card: One Monitor As Reported, Else the CAMS Forecast

The card shows a real reading or nothing; it never estimates air quality from the weather (an earlier version did, and showed the estimate like a measurement).

1. **Nearest monitor (outside Europe).** AirNow's public ArcGIS layers are queried within $45\text{ km}$: the current layer (`Air_Now_Current_Monitors_Ozone_and_PM`) for the latest reading of every monitor, and in parallel the hourly layer (`Air_Now_Monitor_Data_Public`, which keeps about 27 h) for the hours $`[t_h - 27\text{ h},\, t_h - 23\text{ h}]`$. The card shows `OZONEPM_AQI` (the higher of the ozone and particle NowCast indices) of the **nearest** monitor whose newest reading is at most $3\text{ h}$ old, as reported; when the current layer has none, the hourly layer's last 3 hours are used. Readings are not interpolated between monitors: AirNow's Data Exchange Guidelines ask that observed values be disseminated as received, marked preliminary, and credited to the reporting agency and the EPA AirNow program (the card's credit: *"Air quality: South Coast AQMD via U.S. EPA AirNow (preliminary data)"*).
2. **CAMS forecast (elsewhere, or no monitor).** Open-Meteo's air-quality API (`current=us_aqi,european_aqi,pm2_5,nitrogen_dioxide&hourly=us_aqi&past_days=1&timeformat=unixtime`): CAMS European (0.1°) or global (0.4°). The card says it is a model forecast, adds PM2.5 and NO₂, and the European AQI in Europe; credit *"Air quality: Copernicus Atmosphere Monitoring Service (CAMS) via Open-Meteo"*, as Open-Meteo's terms require.
3. **Yesterday.** The comparison uses the **same source 24 hours earlier**: the same monitor (by AQS site id) within ±30 min of $t - 24\text{ h}$, or the CAMS hourly value whose time is the current hour minus 24 h. Within ±8 the sentence says *similar*, otherwise *better* or *worse*, with yesterday's value. (Before: the monitor path took the oldest of the 30 newest records of all monitors — a few hours earlier, at another monitor — and the CAMS path the 24th value from the end after dropping gaps, i.e. 00:00 UTC today.)
4. **No reading.** The card shows the dash; a later refresh in which neither source answers keeps the previous reading while it is less than 3 h old.

The scale has six equal bands in the EPA category colours (TAD 2018: green, yellow, orange, red, purple, maroon), and `scalePosition` places a value inside its own category's band:
- `0–50`: **Good**
- `51–100`: **Moderate**
- `101–150`: **Unhealthy for Sensitive Groups**
- `151–200`: **Unhealthy**
- `201–300`: **Very Unhealthy**
- `301–500`: **Hazardous**

---

## 9. Solar Position & Spherical Geodesy

**Implementation:** [`WeatherCore/Core/Geo.swift`](WeatherCore/Core/Geo.swift)

### 9.1 Haversine Great-Circle Distance (`WxGeo.haversineKm`)

Using the IUGG mean spherical Earth radius $R_\oplus = 6371.0088\text{ km}$ (Moritz, 2000):

```math
a = \mathrm{clamp}_{[0, 1]}\!\left(\sin^2\!\left(\frac{\Delta \phi}{2}\right) + \cos \phi_1 \cos \phi_2 \sin^2\!\left(\frac{\Delta \lambda}{2}\right)\right), \qquad d = 2 R_\oplus \arcsin(\sqrt{a})
```

Antipodal rounding noise where $a$ slightly exceeds $1.0$ in IEEE-754 arithmetic is clamped to $1.0$ so $\sqrt{a}$ and $\arcsin(\sqrt{a})$ never produce `NaN`.

### 9.2 NOAA / Meeus Solar Position Algorithm (`WxGeo.isDaylight`)

To determine whether an hourly timestamp $t_S$ is in daylight (`isDay`) at $(\phi, \lambda)$ without requiring external ephemeris tables, [`Geo.swift:120-210`](WeatherCore/Core/Geo.swift#L120-L210) implements the **NOAA Global Monitoring Laboratory / Meeus (1998)** astronomical algorithm:

1. **Julian Century from J2000.0 ($2000\text{-}01\text{-}01\text{ }12\text{:}00\text{ UTC} = 946728000\text{ s}$):**

   $`\displaystyle T = \frac{(t_S - 946728000) / 86400.0}{36525.0}`$

2. **Geometric Mean Longitude $L_0$, Mean Anomaly $M$, and Eccentricity $e$:**

   $`\displaystyle L_0 = (280.46646 + 36000.76983 \, T + 0.0003032 \, T^2) \bmod 360^\circ`$

   $`\displaystyle M = 357.52911 + 35999.05029 \, T - 0.0001537 \, T^2`$

   $`\displaystyle e = 0.016708634 - 0.000042037 \, T - 0.0000001267 \, T^2`$

3. **Equation of Center $C$, Apparent Solar Longitude $\lambda_\odot$, and Obliquity $\varepsilon$:**

   $`\displaystyle C = (1.914602 - 0.004817 \, T - 0.000014 \, T^2)\sin M + (0.019993 - 0.000101 \, T)\sin(2M) + 0.000289\sin(3M)`$

   $`\displaystyle \Omega = 125.04 - 1934.136 \, T, \qquad \lambda_\odot = L_0 + C - 0.00569 - 0.00478 \sin \Omega`$

   $`\displaystyle \varepsilon_0 = 23.439291 - 0.0130042 \, T - 1.639\times 10^{-7} T^2 + 5.036\times 10^{-7} T^3, \qquad \varepsilon = \varepsilon_0 + 0.00256 \cos \Omega`$

4. **Solar Declination $\delta$, Equation of Time $\text{EoT}$ (minutes), and Solar Elevation $\alpha_\odot$:**

   $`\displaystyle \sin \delta = \sin \varepsilon \sin \lambda_\odot`$

   $`\displaystyle y = \tan^2(\varepsilon / 2), \qquad \text{EoT} = 4 \cdot \frac{180}{\pi}\Big(y \sin(2L_0) - 2e \sin M + 4e y \sin M \cos(2L_0) - \tfrac{1}{2} y^2 \sin(4L_0) - \tfrac{5}{4} e^2 \sin(2M)\Big)`$

   $`\displaystyle \text{TST} = \left(\frac{t_S \bmod 86400}{60.0} + \text{EoT} + 4 \lambda\right) \bmod 1440, \qquad H = \frac{\text{TST}}{4} - 180^\circ`$

   $`\displaystyle \sin \alpha_\odot = \sin \phi \sin \delta + \cos \phi \cos \delta \cos H`$

5. **Refraction-Corrected Horizon Criterion (`horizonDeg = -0.833°`):**  
   Daylight is true when $\alpha_\odot > -0.833^\circ$ (accounting for $34'$ of standard atmospheric refraction plus $16'$ of solar semi-diameter).

---

## 10. Rain Graph & Bars Visual Encoding

**Implementation:** [`WeatherCore/ViewModels/ChartData.swift`](WeatherCore/ViewModels/ChartData.swift), [`Weather/Detail/DetailRainChart.swift`](Weather/Detail/DetailRainChart.swift), [`Weather/Detail/DetailView.swift`](Weather/Detail/DetailView.swift)

The Rain card in the detail pane displays up to two charts side-by-side:
1. **Next 2 hours (`view == .nowcast`, 15-minute intervals):** 8 quarter-hour slots ($8 \times 15\text{ min} = 2\text{ hours}$).
2. **Next 24 hours (`view == .hourly`, 1-hour intervals):** 24 hourly slots.

### Visual Series & Axis Legend
- **Vertical Aqua-to-Cobalt Rounded Bars (`Bars: Rain rate, left axis`):**
  - Represent the **expected precipitation rate** in `in/h` (Imperial) or `mm/h` (Metric).
  - Quarter-hour precip amounts $q_i$ ($\text{mm}$ per 15 min) are converted to an hourly intensity rate via $R_i = 4 \cdot q_i$ ($\text{mm/h}$).
  - **Dynamic Left Y-Axis Scale (`scale`):** Minimum top-of-scale is `2.5 mm/h` (`0.10 in/h` in Imperial, converted as $0.10 \times 25.4 = 2.54\text{ mm/h}$), expanding automatically to the peak rate in the window (`maxMmH`, capped at $500\text{ mm/h}$).
  - **Explicit Left Axis Labels:** Top scale badge (`Rate · 0.10 in/h` or `Rate · 2.5 mm/h`), 50% midpoint badge (`0.05 in/h` or `1.3 mm/h`), and baseline badge (`0 in/h` or `0 mm/h`).
  - **Direct Bar Callouts:** Up to two peak non-zero bars are annotated directly above the bar cap with their formatted rate.
- **Monotone Cubic Hermite Curve (`Line: Rain chance %, right axis`):**
  - Shown on the 24-hour chart; represents the **hourly probability of precipitation** ($`0\%\text{ to }100\%`$).
  - Interpolated via a monotone cubic Hermite spline (Fritsch & Carlson, 1980) with tangents clamped to $`[0\%, 100\%]`$ so the curve never overshoots the plot bounds.
  - **Explicit Right Axis Labels:** `100%` (top), `50%` (middle dashed line), and `0%` (bottom baseline), color-coded in warm amber-rose to match the probability curve.
  - **Interactive Hover Readout:** Hovering over any slot displays a vertical guide line and a floating banner showing `<Time> · Bar: <rate> · Chance: <prob>%`.

---

## 11. Multi-Source Street-Address Geocoding & Proximity Deduplication

**Implementation:** [`WeatherCore/Providers/AddressGeocoder.swift`](WeatherCore/Providers/AddressGeocoder.swift), [`WeatherCore/Storage/Places.swift`](WeatherCore/Storage/Places.swift)

### 11.1 Five-Source Parallel Geocoding Cascade (`WxAddressGeocoder`)
When a user searches for a street address, postal code, landmark, or city in the `Add a City` picker (`⌘N`), `WxAddressGeocoder` queries 5 sources in parallel:
1. **Apple MapKit `MKLocalSearch`** (native rooftop & POI geocoding on macOS).
2. **US Census Bureau TIGER/Line Geocoder** (`geocoding.geo.census.gov` — authoritative US street-range interpolation).
3. **OpenStreetMap Nominatim** (`nominatim.openstreetmap.org` — global building/street database).
4. **OpenStreetMap Photon (Komoot)** (`photon.komoot.io` — typo-tolerant global search).
5. **Open-Meteo GeoNames Search** (`geocoding-api.open-meteo.com` — global municipalities).

### 11.2 Two-Tier Proximity Deduplication
- **Street-Address / POI Search (`AddressGeocoder.swift`):** Deduplicates candidates within `0.15 km` ($150\text{ m}$) so distinct neighborhoods or street addresses within the same city remain selectable.
- **Saved Places List (`WxPlaces.duplicateKm = 5.0 km`, `Places.swift`):** Standard city entries within $5.0\text{ km}$ are deduplicated unless marked `isCustomLocation == true` (custom pin or street address), in which case only exact coordinate keys (`%.4f,%.4f`, $\sim 11\text{ m}$) are considered duplicates.

---

## 12. Refresh Scheduler, Provider Rate-Limiting & Atomic Storage

**Implementation:** [`WeatherCore/Sched/Scheduler.swift`](WeatherCore/Sched/Scheduler.swift), [`WeatherCore/Service/ServicePipeline.swift`](WeatherCore/Service/ServicePipeline.swift), [`WeatherCore/Storage/FileIO.swift`](WeatherCore/Storage/FileIO.swift)

### 12.1 Scheduler Freshness Windows & Concurrency Cap (`WxScheduler`)
- **Event Freshness (`freshEventS = 120 s`):** When a window becomes visible, gains focus, comes online, or a place is selected, places whose forecast is younger than $120\text{ s}$ are considered fresh and skipped.
- **Periodic Freshness (`freshPeriodicS = 540 s`, `periodicIntervalS = 600 s`):** Every 10 minutes while the window is visible and online, places older than $540\text{ s}$ ($9\text{ min}$) are refreshed.
- **Concurrency Cap (`maxInFlight = 3`):** At most 3 places are fetched concurrently; the currently selected place always takes priority at the head of the queue.
- **Failure Backoff (`backoffBaseS = 30 s`, `backoffCapS = 900 s`):** Consecutive failures for a place back off exponentially: $30\text{ s}, 60\text{ s}, 120\text{ s}, 240\text{ s}, 480\text{ s}, 900\text{ s}$.

### 12.2 Provider Rate-Limiting & RFC 9111 Conditional Caching
- **MET Norway (`METNorwayProvider.swift`):** Enforces a strict `minIntervalS = 600 s` (10-minute) floor per coordinate key, honors HTTP `Expires` headers, and sends `If-Modified-Since` conditional requests (`304 Not Modified` reuses the cached `WxSourceResult`).
- **NOAA NWS (`NWSProvider.swift`):** Caches `/points/{lat},{lon}` grid metadata for `gridTTL = 7 days` (up to 64 entries) and pauses all NWS requests for `rateLimitPauseUs = 5,000,000 µs` ($5\text{ s}$) on HTTP `429` or `503`.
- **Service Orchestrator (`ServiceOrchestrator`):** Enforces a `cooldownUs = 60,000,000 µs` ($60\text{ s}$) per-place rate-limit cooldown if all providers return `.rateLimited`.

### 12.3 Crash-Safe Atomic Persistence (`FileIO.swift`)
All JSON stores (`places.json`, `settings.json`, `forecasts.json`, `weights.json`, `stations.json`, `local-bias.json`, `station-settings.json`) are written via a temporary sibling file (`<name>.tmp.<pid>.<counter>`) with mode `0600`, flushed to physical non-volatile media via `fcntl(fd, F_FULLFSYNC)` (falling back to `fsync`), atomically renamed over the target path via POSIX `rename(2)`, and followed by `fsync` on the parent directory descriptor. An unreadable `places.json` or `settings.json` (damaged, a foreign version, a read error) is not overwritten: the first save after the failed load renames it aside to `<name>.unreadable-XXXXXX` and writes a new file. The `places.json` format, including the per-place `units` member, is described in §13.1.

---

## 13. Per-Place Units & Migration

**Implementation:** [`WeatherCore/Storage/Places.swift`](WeatherCore/Storage/Places.swift), [`WeatherCore/App/AppModel.swift`](WeatherCore/App/AppModel.swift), [`WeatherCore/Core/Geo.swift`](WeatherCore/Core/Geo.swift) (`WxGeo.defaultUnits`)

Units are a property of each saved place, not of the app. The units live in the place list beside each `WxPlace` (not in `WxPlace` itself), so they never change a place's key, its forecast, its requests or its alerts; a units change only re-renders.

### 13.1 Storage (`places.json`, `settings.json`)
- **`places.json`** keeps `"version": 1` and adds an optional per-place member `"units": "imperial"` or `"metric"`, written last in the place's object and only when set. An unknown or malformed value reads as unset and never drops the place. An older build reads the file, ignores the member and drops it on its next save.
- **`settings.json`** keeps its `units` member (the C schema, ADR-04); it now means the **default units for new places** (`AppModel.defaultUnits`, Settings › General › *Default Units for New Places*). Changing it never changes a saved place.

### 13.2 Choosing and Changing Units
- **Country default (`WxGeo.defaultUnits(countryCode:fallback:)`):** Imperial for `US`, `PR`, `GU`, `VI`, `AS`, `MP`, `UM`, `LR` and `MM`; Metric for every other two-letter ASCII code (either case); the fallback (the default units for new places) for an empty or malformed code. `AppModel` applies no country rule itself: the add window's units picker (labelled *Units for* plus the highlighted place's name and region, *Units* with no results) is preselected from the highlighted place's country, and the first-run page's picker (labelled with the highlighted city the same way; *Units for these cities* only when no city is highlighted) from the highlighted city's country; in either, a choice the user makes holds for every place added there. Both pass the chosen units to `add(_:units:)` / `addCustomLocation(_:customName:streetAddress:units:)` (nil means the default).
- **Switching:** `AppModel.toggleUnits()` / `setUnits(_:)` — the toolbar button and `⌘U` — act on the selected place (*Switch Selected Place to Celsius* / *Fahrenheit*); with no place selected they change the default (*Set Default Units to Celsius* / *Fahrenheit*). `AppModel.units` is the selected place's units, else the default; each item's units are its saved units, else the default.

### 13.3 Migration
At load, before the list announces changes, every place saved without units (a `places.json` from before per-place units) is given the `settings.json` units — what the app showed it in — and one save of the list is scheduled (3 s debounce). A relaunch finds every place with units, changes nothing and saves nothing.

---

## 14. Official Weather Alerts

**Implementation:** [`WeatherCore/Alerts/AlertsService.swift`](WeatherCore/Alerts/AlertsService.swift), [`WeatherCore/Alerts/AlertRegions.swift`](WeatherCore/Alerts/AlertRegions.swift), [`WeatherCore/Alerts/AlertsFetchers.swift`](WeatherCore/Alerts/AlertsFetchers.swift), [`WeatherCore/Alerts/WxAlert.swift`](WeatherCore/Alerts/WxAlert.swift), [`WeatherCore/App/AppModel.swift`](WeatherCore/App/AppModel.swift), [`WeatherCore/Net/HTTPClient.swift`](WeatherCore/Net/HTTPClient.swift)

### 14.1 Routing (`AlertsService.source(countryCode:lat:lon:)`)
Exactly one source per place, by ISO 3166-1 country code (two ASCII letters, either case; the ASCII check comes before upper-casing, so no non-ASCII letter can fold into a covered code):
- `US`, `PR`, `VI`, `GU`, `AS`, `MP`, `UM` → **NOAA NWS** (`api.weather.gov`, point query); an empty code → NWS when the point lies in the NWS area (`WxGeo.inUSNWS`), else not covered.
- `DE` → **DWD via Bright Sky** (point query); `NO` → **MET Norway MetAlerts** (point query); `CA` → **Environment Canada** (point query).
- A country with a MeteoAlarm feed (`WxAlertRegions.feedSlug`, the only country-to-feed table: `AT`, `BA`, `BE`, `BG`, `CH`, `CY`, `CZ`, `DK`, `EE`, `ES`, `FI`, `FR`, `GB`, `GR`, `HR`, `HU`, `IE`, `IL`, `IS`, `IT`, `LT`, `LU`, `LV`, `MD`, `ME`, `MK`, `MT`, `NL`, `PL`, `PT`, `RO`, `RS`, `SE`, `SI`, `SK`, `UA` — 35 European countries and Israel) → **MeteoAlarm** (`feeds.meteoalarm.org`, the country's whole feed). Germany and Norway are never merged with MeteoAlarm.
- Anything else, including a code that is not two ASCII letters, is **not covered**; no request is sent.

### 14.2 MeteoAlarm Region Matching (`WxAlertRegions`)
The app bundles a region table (`WeatherCore/Resources/MeteoAlarmRegions.json`, built by `scripts/alerts/build_meteoalarm_regions.py`; MeteoAlarm geocodes and NUTS geometry). For each CAP area of a warning: an area with its own polygons is decided by them alone; otherwise its geocodes are looked up by type (`EMMA_ID`, `NUTS3`, `NUTS2`) and code. The one alias: Met Éireann files Irish land warnings under FIPS 10-4 county codes, which are looked up as the `EMMA_ID` region of the same county. A code the table does not carry never matches — there is no nearest-region, country-wide or area-name fallback — and a warning that cannot be placed is dropped. A warning matches a place when any of its areas contains the place (even-odd ray casting over all rings).

**Coverage:** in a country with bundled regions a place is covered only inside a region whose geocode type and code the country's feed actually files; elsewhere the result is *not covered*, never "no alerts", and no feed is downloaded for it. The polygon-only feeds (EE, LU, SE, CH, UA, GB, IL) are covered by country code and match by the warnings' polygons only.

**Known limitation:** alert areas follow each issuer's published region shapes, which can differ from local boundaries near borders and coasts. MeteoAlarm's own Irish county outlines put a few border towns in a neighbouring county (Waterford city centre falls in County Kilkenny's polygon; also Youghal, Carrick-on-Shannon and Killaloe — 8 of 369 towns over 1,000 people), so a warning for their own county may not reach them while a neighbour's does; some coastal places (Howth, Bray, Greystones, Malahide; islands such as Tory and Cape Clear) are reached only by marine warnings or read *not covered*. The table's 0.004° simplification can also move a coast or border by a few hundred metres.

### 14.3 Cadence and Reuse (`AlertsService`)
- **No timer:** nothing fetches except `refresh(_:)`, so an issuer is never asked more often than the forecast is refreshed.
- **MeteoAlarm feed window (`feedWindowUS`, 30 min):** a successful country feed answer is reused for $30\text{ min}$ however many places and refreshes ask, so while downloads succeed a feed is downloaded at most once per $30\text{ min}$; concurrent requests join the one in flight, later ones reuse its answer. A failed answer is reused only for the failure hold below.
- **Failure hold (`failedFeedHoldUS` = `RefreshScheduler.freshUS`, 120 s):** a failed feed answer (thrown error, deadline, non-2xx, unreadable or oversized body) is shared per feed URL by every place of that country — including refreshes whose coverage check was still running when it arrived — for $120\text{ s}$ of the answer's age. The hold is by time, not by refresh round: any refresh that asks within $120\text{ s}$ of the failure, an event round included (for example when the network comes back), takes the held failure without downloading, and a refresh after $120\text{ s}$ tries again. A round longer than 120 s can cost one more download of a failing feed per further 120 s. An attempt ended by `cancelAll()` is never held.
- **Point reuse (`pointReuseUS`, 5 min):** an NWS, Bright Sky, MET Norway or ECCC answer younger than $5\text{ min}$ is reused, also for another place at the same rounded point; a moved place is asked again; a failed point answer is not reused.

### 14.4 Currency, States and Failure Isolation
- **Expiry and windows:** a result is computed when read (`result(for:)`) against the injected clock: alerts whose message expired or whose event ended are left out (`WxAlert.isCurrent`), and an answer as old as its source's window or older (30 min for a feed, the forecast period `RefreshScheduler.periodUS`, 10 min, for a point source) is **stale**, never current. Ages are wall-clock time (a system sleep makes an answer stale), floored by the monotonic time elapsed.
- **States (`WxAlertsResult.State`):** `notFetched` → *Checking for alerts…*; `current` → the alert cards, or *No active alerts*; `unavailable` → *Alerts could not be checked right now.*; `stale` → *Alerts could not be checked recently.* plus the time last checked, with no cards and no sidebar indicator; `notCovered` → *Alerts not available*. Not-fetched and unavailable are never shown as "no alerts".
- **Failure isolation:** the service never touches the forecast and never throws. Each fetch races a deadline (`fetchTimeoutUS`, 120 s, above the transport's own) and cancellation; a thrown error, timeout, cancellation, over-cap body or unreadable answer is *unavailable* — except that a place whose previous alert set is still within its source window keeps it (current until the window passes, then stale) rather than lose a valid warning to one failed refetch.

### 14.5 The AppModel Hook
Each item carries exactly what `AlertsService.result(for:)` reports for its place. When a forecast request of a place **completes** (a forecast or a failure, never a cancelled request) and only after it was applied and reported to the `RefreshEngine`, `AppModel` kicks `refresh(place)` and never awaits it — unless the network is down or shutdown has begun. An item's alert state is re-read from the service when a kick's result lands (only the place's newest kick counts), on every display tick, at once when the window becomes visible, at once on a system clock change (`NSSystemClockDidChange`), and by a wake-up on the injected clock. While the window is visible (online or offline; offline the display tick stops), the wake-up fires at the earliest upcoming alert expiry or source-window end among the items, but never sleeps longer than $60\text{ s}$ (the display tick's period), so a system sleep or a clock change that moves wall time against monotonic time is caught up within a minute; every re-read re-arms it. **The wake-up only re-reads: it never fetches and never kicks.** A removed place's alert work is cancelled and its late result dropped; shutdown cancels all alert work and writes no alert state afterwards; a units change touches none of it. Alerts are shown only in the window (sidebar triangle by level with a count; detail-pane cards); the app posts no system notifications.

### 14.6 Transport (`WxAlertsFetchers`, `HTTPClient`)
- **One host-pinned `HTTPClient` per source**, with the project User-Agent and no key, token or credential; a URL is sent only when it starts with its source's origin.
- **Per-client body cap (`HTTPPolicy.maxBodyBytes(host:)`):** 16 MiB for `feeds.meteoalarm.org` (country feeds exceed 4 MiB), 4 MiB for the four point hosts.
- **Declared statuses (`get(_:accept:ifModifiedSince:answering:)`):** NWS's `400` (point out of bounds) and Bright Sky's `404` are returned with their body under the client's cap and parsed as *not covered*; every other non-2xx is a thrown error (*unavailable*).
- **MET Norway terms:** coordinates rounded to 4 decimals; `Expires` honoured (the answer is reused without a request until then), then `If-Modified-Since` with the kept `Last-Modified`, a `304` answered with the kept body.

---

## 15. Architectural Decision Records (ADRs)

| ADR | Decision | Rationale |
| :--- | :--- | :--- |
| **ADR-01** | **Preserve Bundle ID `io.github.wtp128pro.Weather` while renaming display name to `Neginato Mezora`** | Keeps Apple Developer ID provisioning profiles, notarization tickets, Keychain / UserDefaults domains, and macOS sandbox container paths (`~/Library/Containers/io.github.wtp128pro.Weather/`) 100% compatible without data migration loss. |
| **ADR-02** | **Weighted Median for Continuous Variables, Weighted Mean for Probability** | Eliminates single-model outlier contamination ("ensemble drizzle bias") on physical quantities while preserving calibrated probability expectations. |
| **ADR-03** | **Native macOS Settings (`⌘,`) Replacing Hamburger Popover** | Aligns with macOS Human Interface Guidelines and `Neginato` (`../../music`), providing dedicated grouped tabs (`Sources`, `Weights`, `Stations`, `General`) with interactive sliders for both provider and per-model weights. |
| **ADR-04** | **Persist Custom Weights in `weights.json` Separate from `settings.json`** | Guarantees byte-for-byte backward compatibility with the strict C `settings.json` schema (`version`, `units`, `disabled_providers`, `selected`) and its fuzz/roundtrip test suite. Since per-place units, `units` is the default units for new places; each place's units live in `places.json` (§13). |
| **ADR-05** | **Dual-Series Labeled Rain Charts with Direct Peak Callouts & Hover Inspection** | Resolves ambiguity between bars (Rain rate in `in/h` or `mm/h`, left Y-axis) and curve (Rain chance in `%`, right Y-axis) via explicit pill legends, color-matched axis labels (`Rate · <max>/h`, `<mid>/h`, `0`, `100%`, `50%`, `0%`), peak badges, and live hover inspection. |
| **ADR-06** | **One station pool and one algorithm for every country, from every keyless network** | Airports alone leave most places 20–60 km from the nearest report; national, road-weather and research networks are denser. Trust priors and a measured per-station health record (leave-one-out cross-validation, persisted in `stations.json`) let lower-grade sites help without letting a bad sensor hurt. Networks that need a key join the same pool when the user supplies one (ADR-08). |
| **ADR-07** | **Learned local bias corrects the shown forecast; the raw blend is kept** | `Place.modelForecast` stays the pure model blend, so learning compares observations with the uncorrected model and never feeds on its own corrections; `Place.forecast` is the corrected one. The station catalog's silence clock advances only while the app runs (at most 1 h per check), so closing the app never ages the catalog; the learned bias fades on wall-clock idle time (`WxLocalBias.strength`, after 30 days without updates), whether or not the app was running. |
| **ADR-08** | **Keyed national networks use the user's own free key, kept in the Keychain** | The Met Office, KNMI, MET Norway Frost, Météo-France and AEMET publish real-time station data only to registered users, free. The app cannot ship a shared key (each service's terms tie a key to its registrant, and quotas are per key), so the user registers and pastes their key; Settings gives each service's exact steps and limits. Keys never touch a file or a log, and requests stay well inside the free quotas. |
| **ADR-09** | **Air quality: a real reading or nothing** | A number estimated from wind, rain and heat looked like a measurement and could not be checked. The card shows the nearest AirNow monitor as reported (AirNow's guidelines: as received, preliminary, credited) or the CAMS forecast, says which, and compares with the same source 24 h earlier; without either it shows the dash. |
| **ADR-10** | **Units belong to each place; `settings.json` keeps only the default** | A user with places in several countries reads each in its own units. Keeping the member in `places.json` at version 1 lets older builds still read the file; a one-time migration gives every existing place the units it was shown in, so nothing visibly changes on upgrade. |
| **ADR-11** | **Official alerts from one keyless issuer per place, on the forecast's cadence, isolated from it** | Each issuer is authoritative for its area and needs no key. Kicking alerts only after a completed forecast refresh (no timer; a successful MeteoAlarm feed shared per country for 30 min, a failed one for 120 s) keeps the request rate bounded by the forecast's; a separate, never-awaited path means a failing or hanging issuer cannot delay or change the forecast; a stale or failed check is never shown as "no alerts". |

---

## 16. Academic, Institutional & Standard Citations

1. **Alduchov, O. A., & Eskridge, R. E. (1996).** *Improved Magnus Form Approximation of Saturation Vapor Pressure.* Journal of Applied Meteorology, 35(4), 601–609. `https://doi.org/10.1175/1520-0450(1996)035<0601:IMFAOS>2.0.CO;2`
2. **Benjamin, S. G., et al. (2016).** *A North American Hourly Assimilation and Model Forecast Cycle: The Rapid Refresh.* Monthly Weather Review, 144(4), 1669–1694 (NOAA HRRR 3 km architecture). `https://doi.org/10.1175/MWR-D-15-0242.1`
3. **Edgeworth, F. Y. (1888).** *On a New Method of Reducing Observations Relating to Several Quantities.* Philosophical Magazine, Series 5, 25(154), 184–191 (Weighted median estimator).
4. **ECMWF (2024).** *IFS Documentation Cy48r1 — Part IV: Physical Processes.* European Centre for Medium-Range Weather Forecasts, Reading, UK.
5. **Fritsch, F. N., & Carlson, R. E. (1980).** *Monotone Piecewise Cubic Interpolation.* SIAM Journal on Numerical Analysis, 17(2), 238–246. `https://doi.org/10.1137/0717021`
6. **Glahn, H. R., & Lowry, D. A. (1972).** *The Use of Model Output Statistics (MOS) in Objective Weather Forecasting.* Journal of Applied Meteorology, 11(8), 1203–1211.
7. **Goldberg, D. (1991).** *What Every Computer Scientist Should Know About Floating-Point Arithmetic.* ACM Computing Surveys, 23(1), 5–48 (Exact radix-2 `frexp`/`ldexp` scaling).
8. **Hamill, T. M., et al. (2017).** *The U.S. National Blend of Models for Statistical Postprocessing of Probability of Precipitation and Deterministic Guidance.* Bulletin of the American Meteorological Society, 98(12), 2599–2617.
9. **Meeus, J. (1998).** *Astronomical Algorithms* (2nd ed.). Willmann-Bell, Richmond, VA (Solar position, Julian century, Equation of Time).
10. **Moritz, H. (2000).** *Geodetic Reference System 1980.* Journal of Geodesy, 74(1), 128–162 (IUGG mean spherical Earth radius $R = 6371.0088\text{ km}$).
11. **Osczevski, R., & Bluestein, M. (2005).** *The New Wind Chill Equivalent Temperature Chart.* Bulletin of the American Meteorological Society, 86(10), 1453–1458.
12. **Rothfusz, L. P. (1990).** *The Heat Index Equation (or, More Than You Ever Wanted to Know About Heat Index).* NWS Southern Region Technical Attachment, SR/SSD 90-23, Fort Worth, TX.
13. **Rousseeuw, P. J., & Croux, C. (1993).** *Alternatives to the Median Absolute Deviation.* Journal of the American Statistical Association, 88(424), 1273–1283 (Scale factor $1.4826$ for Gaussian consistency).
14. **Shepard, D. (1968).** *A Two-Dimensional Interpolation Function for Irregularly-Spaced Data.* Proceedings of the 1968 23rd ACM National Conference, 517–524 (Directional isolation shadow weighting).
15. **Stull, R. (2011).** *Wet-Bulb Temperature from Relative Humidity and Air Temperature.* Journal of Applied Meteorology and Climatology, 50(11), 2267–2269. `https://doi.org/10.1175/JAMC-D-11-0143.1`
16. **US Environmental Protection Agency (2018).** *Technical Assistance Document for the Reporting of Daily Air Quality — the Air Quality Index (AQI).* EPA-454/B-18-007 (40 CFR Part 58 Appendix G).
17. **World Meteorological Organization (2019).** *Manual on Codes — International Codes, Volume I.1, Part A: Alphanumeric Codes* (WMO-No. 306, Code Table 4677: Present weather).
18. **Zängl, G., Reinert, D., Rípodas, P., & Baldauf, M. (2015).** *The ICON (ICOsahedral Non-hydrostatic) Modelling Framework of DWD and MPI-M.* Quarterly Journal of the Royal Meteorological Society, 141(687), 563–579.
