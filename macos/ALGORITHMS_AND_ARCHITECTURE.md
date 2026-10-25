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
6. [Live Physical Station Assimilation & 3D Anisotropic Kernel Fusion (`LiveStationFetcher.swift`)](#6-live-physical-station-assimilation--3d-anisotropic-kernel-fusion)
7. [Psychrometrics, Thermodynamics & Apparent Temperature (`LiveStationFetcher.swift`, `Format.swift`)](#7-psychrometrics-thermodynamics--apparent-temperature)
8. [Radiative Cloud Transmittance & EPA AirNow AQI Interpolation (`LiveStationFetcher.swift`)](#8-radiative-cloud-transmittance--epa-airnow-aqi-interpolation)
9. [Solar Position & Spherical Geodesy (`Geo.swift`)](#9-solar-position--spherical-geodesy)
10. [Rain Graph & Bars Visual Encoding (`ChartData.swift`, `DetailRainChart.swift`, `DetailView.swift`)](#10-rain-graph--bars-visual-encoding)
11. [Multi-Source Street-Address Geocoding & Proximity Deduplication (`AddressGeocoder.swift`, `Places.swift`)](#11-multi-source-street-address-geocoding--proximity-deduplication)
12. [Refresh Scheduler, Provider Rate-Limiting & Atomic Storage (`Scheduler.swift`, `RefreshEngine.swift`, `FileIO.swift`)](#12-refresh-scheduler-provider-rate-limiting--atomic-storage)
13. [Architectural Decision Records (ADRs)](#13-architectural-decision-records-adrs)
14. [Academic, Institutional & Standard Citations](#14-academic-institutional--standard-citations)

---

## 1. Executive Overview & Architectural Philosophy

**Neginato Mezora** is a native macOS meteorological workstation and hyper-local precipitation nowcasting application. It synthesizes numerical weather prediction (NWP) guidance from up to **10 distinct forecast models across 3 independent upstream providers** (`Open-Meteo`, `NOAA National Weather Service`, and `MET Norway`), fuses them with **real-time physical surface observations** (`NOAA/FAA AviationWeather METAR`, `Open-Meteo 90m DEM surface analysis`, and `US EPA AirNow`), and renders high-contrast Apple Weather–inspired visual cards.

The system is split into two strict layers:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         Weather (macOS SwiftUI Target)                       │
│  ShellWindow · DetailView · DetailRainChart · SettingsView · HelpWindowMgr   │
│  LiveStationFetcher (3D Anisotropic Station & AirNow Assimilation)           │
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                       WeatherCore (Framework Target)                         │
│  AppModel · ServiceOrchestrator · RefreshEngine · WxScheduler                │
│  WxBlend · WxWeights · WxWeightedMedian · WxNowcast · WxRainRules · WxGeo    │
│  OpenMeteoProvider · NWSProvider · METNorwayProvider · AddressGeocoder       │
│  WxPlaces · WxSettings · WxForecastCache · StoreJSON · FileIO (F_FULLFSYNC)  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Core Design Tenets
1. **Robust Order Statistics over Arithmetic Averaging:** Continuous atmospheric variables (temperature, feels-like, wind speed, gusts, cloud fraction, relative humidity, and precipitation amount) are combined via a **weighted median** rather than a weighted mean so a single outlier NWP model cannot skew the forecast ([`Blend.swift`](WeatherCore/Blend/Blend.swift), [`WeightedMedian.swift`](WeatherCore/Blend/WeightedMedian.swift)).
2. **Horizon-Dependent Model Trust:** Short-range convection-allowing models (`NOAA HRRR` 3 km) dominate the 0–18 h window, calibrated multi-model ensembles (`NOAA NBM`) and human-edited grids (`NWS NDFD`) anchor medium/extended ranges, and global spectral models (`ECMWF IFS`, `DWD ICON`, `UKMO`, `Météo-France`, `NOAA GFS`, `ECCC GEM`) provide global coverage ([`Weights.swift`](WeatherCore/Blend/Weights.swift)).
3. **User-Transparent & Customizable Weights:** All provider and per-model weights are exposed in the native **Settings (`⌘,`)** dialogue ([`SettingsView.swift`](Weather/Settings/SettingsView.swift)), allowing users to inspect the baseline table across all 6 variable groups and 4 horizon bands and apply custom `[0.00×, 3.00×]` multipliers persisted to `weights.json`.
4. **Physical Observation Grounding:** Model grid points can miss sub-grid coastal breezes, valley inversions, and urban heat islands. [`LiveStationFetcher.swift`](Weather/Detail/LiveStationFetcher.swift) assimilates live airport/ASOS/AWOS METARs within 95 km using a 3D anisotropic kernel with environmental lapse-rate elevation reduction, Shepard directional isolation, and Median Absolute Deviation (MAD) buddy quality control.

---

## 2. Multi-Model Ensemble Blending & Weighted Median

**Implementation:** [`WeatherCore/Blend/Blend.swift`](WeatherCore/Blend/Blend.swift), [`WeatherCore/Blend/WeightedMedian.swift`](WeatherCore/Blend/WeightedMedian.swift)

### 2.1 Why Weighted Median Instead of Weighted Mean?

In multi-model NWP ensembles, individual models frequently exhibit phase or amplitude errors (e.g., one model stalls a frontal boundary 30 km too far west, predicting $18\text{ mm/h}$ of rain while six other models predict $0\text{ mm/h}$). Under an arithmetic weighted mean, a single wet outlier produces artificial drizzle across dry hours ("ensemble drizzle bias"). The **weighted median** (Edgeworth, 1888) has a breakdown point of $50\%$—any minority of outlier models with less than half the total weight cannot pull the blended estimate away from the consensus regime.

Precipitation probability (`precipProb`), by contrast, is already a calibrated probability in $[0, 100]\%$ and is combined via a **weighted arithmetic mean** so every model's wet/dry signal contributes proportionally to the final risk percentage.

### 2.2 Numerical Stability via IEEE-754 `frexp`/`ldexp` Weight Scaling

**Implementation:** [`WeightedMedian.swift:22-121`](WeatherCore/Blend/WeightedMedian.swift#L22-L121)

Given $n \in [1, 64]$ candidate pairs $(x_i, w_i)$ filtered to finite $x_i$ and strictly positive finite weights $w_i > 0$:

1. **Power-of-Two Exponent Normalization:**  
   Directly summing arbitrary positive IEEE-754 `Double` weights can overflow to $+\infty$ (when $w_i \sim 10^{308}$) or underflow to $0$ (when $w_i \sim 10^{-320}$). To guarantee exactness without altering the binary significands (mantissas) of the weights, we find:
   $$w_{\max} = \max_{1 \le i \le k} w_i, \qquad (m, e_{\max}) = \operatorname{frexp}(w_{\max})$$
   where $m \in [0.5, 1.0)$ and $w_{\max} = m \cdot 2^{e_{\max}}$. Every weight is rescaled by an exact power of two via $\operatorname{ldexp}$:
   $$\tilde{w}_i = \operatorname{ldexp}(w_i, -e_{\max}) = w_i \cdot 2^{-e_{\max}} \in [0, 1)$$
   Because $\operatorname{ldexp}$ only adjusts the 11-bit IEEE-754 exponent field, **zero rounding error** is introduced into the mantissas, and the total weight satisfies:
   $$0.5 \le \sum_{i=1}^k \tilde{w}_i < k \le 64$$
   which is guaranteed never to overflow or underflow (Goldberg, 1991).

2. **Stable Insertion Sort:**  
   The surviving pairs $(x_i, \tilde{w}_i)$ are sorted in ascending order of $x_i$ using a deterministic insertion sort (`j > 0 && xs[j - 1] > x`). Because $k \le 64$, insertion sort is cache-optimal and preserves member registration order for equal values.

3. **50% Cumulative Weight Threshold & Exact Tie-Breaking:**  
   Let $H = \frac{1}{2} \sum_{i=1}^k \tilde{w}_i$ be the half-weight threshold, and let $C_i = \sum_{m=0}^{i} \tilde{w}_m$ be the running cumulative weight:
   - The walk stops at the first index $i$ where $C_i \ge H$.
   - **Strict Exceedance ($C_i > H$):** The weighted median is $x_i$.
   - **Exact Split ($C_i == H$):** When the cumulative weight lands exactly on $H$, any zero-weight padding entries are skipped to find the next positive-weight element $x_j$ ($j > i$), and the tie is broken by their overflow-safe midpoint (`meanOfPair`):
     $$\operatorname{meanOfPair}(a, b) = \begin{cases} \dfrac{a + b}{2} & \text{if } (a < 0) \neq (b < 0) \quad \text{(opposite signs: } a+b \text{ cannot overflow)} \\[6pt] a + \dfrac{b - a}{2} & \text{if } \operatorname{sgn}(a) = \operatorname{sgn}(b) \quad \text{(same sign: } b-a \text{ cannot overflow)} \end{cases}$$

### 2.3 Per-Hour Ensemble Synthesis Rules

**Implementation:** [`Blend.swift:120-260`](WeatherCore/Blend/Blend.swift#L120-L260)

For each valid UTC hour $t_S$ in the union of all member timelines (capped at `WxLimits.forecastMaxHours = 240` hours):

| Output Field | Blending Estimator | Weight Group (`WxVar`) | Post-Processing & Special Rules |
| :--- | :--- | :--- | :--- |
| `tempC` | Weighted Median | `.temp` | Unweighted interquartile/range spread `tempSpreadC = max(tempC) - min(tempC)` when $\ge 2$ members report finite `tempC` (else `NaN`). |
| `feelsC` | Weighted Median | `.temp` | Uses member-reported apparent temperature. |
| `windKmh` | Weighted Median | `.wind` | Clamped $\ge 0$. |
| `gustKmh` | Weighted Median | `.wind` | Enforces physical invariant `gustKmh = max(gustKmh, windKmh)` when both are finite. |
| `cloudPct` | Weighted Median | `.cloud` | Clamped to $[0, 100]\%$. |
| `humidityPct` | Weighted Median | `.humidity` | Clamped to $[0, 100]\%$. |
| `precipMm` | Weighted Median | `.precipMm` | Also records `precipMmMax = max_i(precipMm_i)` across all members with positive `.precipMm` weight. |
| `precipProb` | Weighted Mean (or Derived Fallback) | `.precipProb` | See **§2.4** below. |

### 2.4 Precipitation Probability & Wet-Member Derivation Fallback

**Implementation:** [`Blend.swift:208-237`](WeatherCore/Blend/Blend.swift#L208-L237)

1. **Primary (Weighted Mean of Reported Probabilities):**  
   If at least one member supplies a finite `precipProb` with weight $w_i = \operatorname{weight}(\text{src}_i, \text{model}_i, \text{.precipProb}, h, \text{us}) > 0$:
   $$P_{\text{precip}} = \operatorname{clamp}_{[0, 100]}\!\left(\frac{\sum_i \tilde{w}_i \, P_i}{\sum_i \tilde{w}_i}\right)$$
   where $\tilde{w}_i = \operatorname{ldexp}(w_i, -e_{\max})$.

2. **Secondary Fallback (Derived from Wet-Member Fraction):**  
   Some global models (such as `MET Norway` and certain regional NWP feeds) report hourly precipitation amount (`precipMm`) without an explicit probability field. If no member reports `precipProb` at hour $t_S$, the probability is derived from the weighted fraction of members predicting measurable rain (`precipMm >= 0.1 mm/h`, `derivedWetMm = 0.1`):
   $$P_{\text{derived}} = 100 \cdot \frac{\sum_{i \,:\, R_i \ge 0.1} \tilde{w}_{i,\text{mm}}}{\sum_{i \,:\, R_i \text{ finite}} \tilde{w}_{i,\text{mm}}}$$
   using the `.precipMm` weights $w_{i,\text{mm}}$.

### 2.5 Sub-Hourly Linear Interpolation for "Now"

**Implementation:** [`Blend.swift:326-389`](WeatherCore/Blend/Blend.swift#L326-L389) (`WxBlend.interpolateAt`)

When displaying current conditions at wall-clock time $t_{\text{now}}$ between two consecutive hourly slots $h_0$ ($t_0 \le t_{\text{now}} < t_0 + 3600$) and $h_1$ ($t_1 = t_0 + 3600$), continuous fields are linearly interpolated with fraction $\alpha = (t_{\text{now}} - t_0) / 3600 \in [0, 1)$:
$$\operatorname{lerpKnown}(a, b, \alpha) = \begin{cases} a + \alpha (b - a) & \text{if } a, b \text{ finite} \\ a & \text{if only } a \text{ finite} \\ b & \text{if only } b \text{ finite} \\ \text{NaN} & \text{otherwise} \end{cases}$$
Discrete fields (`condition`, `isDay`, `nMembers`, `tS`) are taken from the enclosing hour $h_0$.

---

## 3. Heuristic Forecast Weights, Horizon Bands & User Multipliers

**Implementation:** [`WeatherCore/Blend/Weights.swift`](WeatherCore/Blend/Weights.swift)

### 3.1 Forecast Horizon Bands (`bandOf`)

Forecast lead time (horizon) in hours is defined as:
$$h = \frac{t_{\text{valid}} - t_{\text{now}}}{3600}$$
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
| `open-meteo:knmi` (KNMI HARMONIE) | Benelux / North Sea | `2.0` | `2.0` | `2.0` | `1.0` | `2.0` | `1.0` |
| `met-no:ecmwf` (MET Norway) | Worldwide | `0.5` | `1.0` | `1.0` | `1.0` | `1.0` | `1.0` |
| `dwd-brightsky:mosmix` (DWD MOSMIX) | DE / NL / Central Europe | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) |
| `eccc:hrdps` (ECCC GeoMet) | Canada | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) | `0.0` (US) |

### 3.3 Regional 4-Band Horizon Profiles (`WxRegion`) & World Weights

Instead of a binary `US vs. Rest-of-World` split, [`Geo.swift`](WeatherCore/Core/Geo.swift) and [`Weights.swift`](WeatherCore/Blend/Weights.swift) classify every location into one of 8 meteorological domains (`WxRegion`) with 4-band lead-time horizon weights (`H0: 0–3h`, `H1: 3–18h`, `H2: 18–72h`, `H3: 72h+`) so that national convection-allowing models lead in short ranges (`0–48 h`) and gracefully hand off to `ECMWF IFS` and `DWD ICON` in medium/extended ranges (`72 h+`):

| Region (`WxRegion`) | Primary Short-Range (H0/H1, 0–18h) | Medium/Extended Anchor (H2/H3, 18h+) | Sub-Hourly 15-min Nowcast Model |
| :--- | :--- | :--- | :--- |
| `.ukIreland` (UK & Ireland) | `open-meteo:ukmo` (UKV 2 km, weight `4.5`), `meteofrance` (`2.5`), `ecmwf` (`2.5`) | `open-meteo:ecmwf` (`3.5`), `ukmo` (`2.5`), `icon` (`2.2`) | `ukmo_seamless` |
| `.beneluxNorthSea` (Netherlands & Benelux) | `open-meteo:knmi` (HARMONIE 2 km, `4.5`, $0\text{ at }72\text{h+}$), `dwd-brightsky:mosmix` (`3.2`), `icon` (`3.5`), `ukmo` (`2.8`) | `open-meteo:ecmwf` (`3.5`), `dwd-brightsky:mosmix` (`2.8`), `icon` (`2.5`) | `knmi_seamless` |
| `.centralEurope` (Germany, CH, AT) | `open-meteo:icon` (ICON-D2 2 km, `4.5`), `dwd-brightsky:mosmix` (`3.8`), `meteofrance` (`2.5`), `ecmwf` (`2.5`) | `open-meteo:ecmwf` (`3.5`), `dwd-brightsky:mosmix` (`3.2`), `icon` (`3.0`) | `icon_seamless` |
| `.canada` (Canada) | `eccc:hrdps` (MSC GeoMet, `4.2`), `open-meteo:gem` (HRDPS 2.5 km + RDPS, `4.0`), `hrrr` (`3.2`, $\le 48\text{h}$) | `open-meteo:ecmwf` (`3.2`), `gem` (`2.8`), `eccc:hrdps` (`2.8`), `gfs` (`2.0`) | `gem_seamless` |
| `.nordic` (Nordic & Baltic) | `met-no:ecmwf` (MEPS 2.5 km, `4.2`), `ecmwf` (`3.0`), `icon` (`2.5`) | `open-meteo:ecmwf` (`3.5`), `met-no:ecmwf` (`2.5`), `icon` (`2.2`) | `icon_seamless` |

In `.world` (Rest of World), US/regional-only models receive weight `0.0`, while global models use flat horizon weights defined by `WORLD_MAIN(w)` (`[w, w, w, 1.0, w, 1.0]`):

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

### 3.4 User-Configurable Source & Model Multipliers (`WxWeightMultipliers`)

**Implementation:** [`Weights.swift:16-140`](WeatherCore/Blend/Weights.swift#L16-L140), [`AppModel.swift:874-919`](WeatherCore/App/AppModel.swift#L874-L919), [`SettingsView.swift`](Weather/Settings/SettingsView.swift)

In **Settings (`⌘,`)**, users can adjust:
- **Per-Source Multiplier** $M_{\text{src}}(\text{sourceID}) \in [0.00, 3.00]$ (default $1.00$)
- **Per-Model Multiplier** $M_{\text{model}}(\text{sourceID}, \text{modelID}) \in [0.00, 3.00]$ (default $1.00$)

The effective weight used by `WxWeights.weight(...)` is:
$$w_{\text{eff}}(s, m, v, h, \text{us}) = w_{\text{base}}(s, m, v, h, \text{us}) \times M_{\text{src}}(s) \times M_{\text{model}}(s, m)$$
Custom multipliers are persisted atomically to `<configDirectory>/weather/weights.json` (keeping `settings.json` strictly compatible with the C schema) and immediately trigger `engine.sourcesChanged()` so active places re-blend.

---

## 4. 15-Minute HRRR Nowcast & Mass-Conserving Sub-Hourly Rescaling

**Implementation:** [`WeatherCore/Blend/Nowcast.swift`](WeatherCore/Blend/Nowcast.swift), [`WeatherCore/Providers/OpenMeteoProvider.swift`](WeatherCore/Providers/OpenMeteoProvider.swift)

### 4.1 Parallel CONUS Sub-Hourly Fetching (`OpenMeteoProvider`)

For places inside the Continental United States (`WxGeo.inCONUS`: $\text{lat} \in [24.0^\circ, 50.0^\circ]$, $\text{lon} \in [-125.0^\circ, -66.0^\circ]$, or `countryCode == "US"` within those bounds), `OpenMeteoProvider` issues two concurrent HTTPS requests:
- **Request A (Main Multi-Model Hourly):** Queries `ncep_hrrr_conus,ncep_nbm_conus,ecmwf_ifs025,gfs_seamless,icon_seamless,gem_seamless`.
- **Request B (15-Minute HRRR Nowcast):** Queries `models=ncep_hrrr_conus&minutely_15=precipitation&forecast_minutely_15=12` with a **2,000 ms grace window** (`nowcastGraceMs = 2000`) after Request A completes so a slow sub-hourly response never blocks the main forecast.

### 4.2 Contiguous Run Validation (`WxNowcast.extract`)

From the `hrrr15` member's quarter-hour slots (each $900\text{ s} = 15\text{ min}$, aligned to `:00`, `:15`, `:30`, `:45`), [`Nowcast.swift:52-135`](WeatherCore/Blend/Nowcast.swift#L52-L135) extracts the **first contiguous run** of valid quarter-hour slots starting at or before the current quarter $q_0 = \lfloor t_{\text{now}} / 900 \rfloor \times 900$:
- Every slot must satisfy $t_k = t_{k-1} + 900$ with finite $R_k \ge 0$ (`<= 500 mm`).
- **Minimum Horizon Coverage:** The contiguous run must reach at least $t_{\text{now}} + 1800\text{ s}$ ($30\text{ minutes}$ ahead) and is capped at `maxQuarters = 12` ($3\text{ hours}$).

### 4.3 Hourly Sum Substitution (`substituteHrrrHours`)

When the `hrrr15` run contains all 4 quarter-hours $[H, H+900, H+1800, H+2700]$ of an aligned UTC hour $H$, their sum:
$$R_{\text{HRRR}, H} = \sum_{j=0}^{3} q_{H + 900j}$$
replaces the hourly `open-meteo:hrrr` member's `precipMm` at hour $H$ **before** multi-model ensemble blending.

### 4.4 Mass-Conserving Quarter Rescaling (`rescaleQuarters`)

After multi-model blending produces the consensus hourly precipitation $B_H$ at hour $H$, the 4 sub-hourly quarters $q_0, q_1, q_2, q_3$ must be rescaled so their sum equals $B_H$ to machine precision (`sum(rescaled) == B_H`) while preserving sub-hourly temporal structure ([`Nowcast.swift:175-238`](WeatherCore/Blend/Nowcast.swift#L175-L238)):

Let $S = q_0 + q_1 + q_2 + q_3$ be the raw quarter sum:
1. **Dry / Near-Zero Raw Sum ($S \le 10^{-9}\text{ mm}$, `rawZeroMm = 1e-9`):**  
   The blended hourly total is distributed equally across all 4 quarters:
   $$q'_j = \frac{B_H}{4}, \qquad j \in \{0, 1, 2, 3\}$$
2. **Wet Raw Sum ($S > 10^{-9}\text{ mm}$):**  
   Let $j^* = \arg\max_{j \in \{0,1,2,3\}} q_j$ be the **first largest quarter**. The other three quarters are scaled proportionally, and the largest quarter absorbs the exact floating-point remainder:
   $$q'_j = q_j \cdot \frac{B_H}{S} \quad (j \neq j^*), \qquad q'_{j^*} = \max\!\left(0,\; B_H - \sum_{j \neq j^*} q'_j\right)$$
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
   $$\text{precipMm} \ge 0.1\text{ mm/h} \quad \land \quad \left(\text{precipProb} \ge 30.0\% \;\lor\; \text{precipProb is NaN}\right)$$
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

**Implementation:** [`Weather/Detail/LiveStationFetcher.swift`](Weather/Detail/LiveStationFetcher.swift)

While `WeatherCore` produces the multi-model NWP grid blend, [`LiveStationFetcher.swift`](Weather/Detail/LiveStationFetcher.swift) performs real-time **mesoscale data assimilation** every 5 minutes (300 s cache TTL) by querying:
1. **NOAA / FAA AviationWeather METAR API** (`https://aviationweather.gov/api/data/metar`) in a $\pm 0.55^\circ \text{ lat} \times \pm 0.70^\circ \text{ lon}$ bounding box around the target coordinate (up to 16 physical airport/ASOS/AWOS stations within $95\text{ km}$).
2. **Open-Meteo 90m DEM Downscaled Current Analysis** (`https://api.open-meteo.com/v1/forecast?current=...`).
3. **US EPA AirNow Real-Time Observations** (`https://www.airnowapi.org` / EnviroFlash + Open-Meteo CAMS/GEOS-CF fallback).

### 6.1 3D Anisotropic Spatial Distance Kernel

Station $i$ at horizontal great-circle distance $d_i$ ($\text{km}$) and elevation difference $\Delta z_i = z_{\text{station},i} - z_{\text{target}}$ ($\text{m}$) receives a base spatial weight $W_{\text{spatial},i}$ combining a horizontal Cauchy-Gaussian product kernel with a vertical Gaussian boundary-layer decoupling kernel ([`LiveStationFetcher.swift:268-281`](Weather/Detail/LiveStationFetcher.swift#L268-L281)):

$$W_{\text{horiz}}(d_i) = \exp\!\left(-\frac{d_i^2}{2 L_h^2}\right) \cdot \frac{1}{1 + (d_i / d_0)^2}, \qquad L_h = 22.0\text{ km},\quad d_0 = 8.0\text{ km}$$

$$W_{\text{vert}}(\Delta z_i) = \exp\!\left(-\frac{\Delta z_i^2}{2 L_z^2}\right), \qquad L_z = 350.0\text{ m}$$

$$W_{\text{spatial},i} = W_{\text{horiz}}(d_i) \cdot W_{\text{vert}}(\Delta z_i)$$

- **Why Cauchy × Gaussian horizontally?** The inner Cauchy factor $\left(1 + (d_i / 8\text{ km})^2\right)^{-1}$ provides sharp local localization when an airport or ASOS station is within a few kilometers, while the outer Gaussian $\exp(-d_i^2 / (2 \cdot 22^2))$ smoothly suppresses stations beyond $50\text{ km}$.
- **Why $L_z = 350\text{ m}$ vertically?** Atmospheric boundary layers decouple across mountain ridges and marine inversions (~300–400 m depth); a mountaintop station $700\text{ m}$ above a valley floor is attenuated by $\exp(-490000 / 245000) = e^{-2} \approx 0.135$.

### 6.2 Diurnal Boundary-Layer Lapse Rate Elevation Correction

Before blending temperatures or dewpoints from station $i$ at elevation $z_i$ to the target elevation $z_{\text{target}}$, observations are adiabatically reduced to $z_{\text{target}}$ ([`LiveStationFetcher.swift:283-295`](Weather/Detail/LiveStationFetcher.swift#L283-L295)):

$$T_{\text{reduced},i} = T_i + \Gamma_T \cdot (z_i - z_{\text{target}}), \qquad \Gamma_T = \begin{cases} +0.0068\text{ }^\circ\text{C/m} & \text{Daytime (mixed convective boundary layer)} \\ +0.0042\text{ }^\circ\text{C/m} & \text{Nighttime (radiatively stratified boundary layer)} \end{cases}$$

$$T_{d,\text{reduced},i} = T_{d,i} + \Gamma_{Td} \cdot (z_i - z_{\text{target}}), \qquad \Gamma_{Td} = +0.0019\text{ }^\circ\text{C/m}$$

(Note: when $z_i > z_{\text{target}}$, $(z_i - z_{\text{target}}) > 0$, so descending to a lower target elevation warms the parcel by $+\Gamma \Delta z$, matching the ICAO Standard Atmosphere lapse rate of $6.5\text{ K/km}$ during daytime and a damped nocturnal inversion lapse rate of $4.2\text{ K/km}$ at night.)

### 6.3 Shepard (1968) Directional Isolation (Angular De-Clustering)

When three airport stations cluster tightly to the north of a city while only one station lies to the south, naive distance weighting over-represents the northern cluster. Following **Shepard (1968)** ([`LiveStationFetcher.swift:297-318`](Weather/Detail/LiveStationFetcher.swift#L297-L318)), we compute the initial compass bearing $\theta_i$ from the target to each station $i$ and evaluate the angular shadow cast by other stations $j \neq i$:

$$S_i = \frac{\sum_{j \neq i} W_{\text{spatial},j} \cdot \max\!\big(0, \cos(\theta_i - \theta_j)\big)}{\sum_{j \neq i} W_{\text{spatial},j}}, \qquad W_{\text{dir},i} = \frac{1}{1 + 0.85 \, S_i}$$

Stations sharing the same azimuth ($\theta_i \approx \theta_j \implies \cos(\theta_i - \theta_j) \approx 1$) have their weights damped by up to $1 / 1.85 \approx 0.54$, whereas an isolated station in its own quadrant ($S_i \approx 0$) retains full weight $W_{\text{dir},i} = 1.0$.

### 6.4 Variable-Specific Temporal Exponential Decay

Observations age at different physical rates depending on atmospheric decorrelation scales ([`LiveStationFetcher.swift:320-335`](Weather/Detail/LiveStationFetcher.swift#L320-L335)). For observation age $\Delta t_i = \max(0, t_{\text{now}} - t_{\text{obs},i})$ (rejected if $\Delta t_i > 5400\text{ s} = 90\text{ min}$):

$$W_{\text{time},i}^{(\text{var})} = \exp\!\left(-\frac{\Delta t_i}{\tau_{\text{var}}}\right), \qquad \begin{cases} \tau_{\text{temp}} = 2700\text{ s} & (45\text{ min — thermal inertia}) \\ \tau_{\text{wind}} = 1200\text{ s} & (20\text{ min — mesoscale gust fronts}) \\ \tau_{\text{wx}} = 900\text{ s} & (15\text{ min — convective precipitation/sky}) \end{cases}$$

### 6.5 Spatial Buddy Quality Control via Median Absolute Deviation (MAD)

To reject malfunctioning sensors (e.g., an ASOS thermometer stuck or sun-heated on a tarmac), when $N \ge 3$ stations report a variable, we compute the median $M = \operatorname{median}(x_1, \dots, x_N)$ and the Median Absolute Deviation (Rousseeuw & Croux, 1993) ([`LiveStationFetcher.swift:337-360`](Weather/Detail/LiveStationFetcher.swift#L337-L360)):

$$\operatorname{MAD} = \max\!\big(\sigma_{\min},\; 1.4826 \cdot \operatorname{median}_i |x_i - M|\big)$$

where $\sigma_{\min} = 1.2^\circ\text{C}$ for temperature/dewpoint and $4.0\text{ km/h}$ for wind. A Huber-style quadratic tail penalty down-weights any station deviating by more than $3.2 \times \operatorname{MAD}$:

$$W_{\text{QC},i} = \begin{cases} 1.0 & \text{if } |x_i - M| \le 3.2 \cdot \operatorname{MAD} \\[6pt] \dfrac{1}{1 + \left(\dfrac{|x_i - M|}{3.2 \cdot \operatorname{MAD}}\right)^4} & \text{if } |x_i - M| > 3.2 \cdot \operatorname{MAD} \end{cases}$$

### 6.6 Multiscale Observation-to-Model Fusion & MOS Exponential Bias Decay

The assimilated station observation $X_{\text{obs}}$ is fused with the 90m DEM downscaled model analysis $X_{\text{model}}$ using an adaptive confidence weight $\alpha_{\text{obs}} \in [0.35, 0.95]$ governed by the nearest station distance $d_{\min}$ and age $\Delta t_{\min}$ ([`LiveStationFetcher.swift:415-455`](Weather/Detail/LiveStationFetcher.swift#L415-L455)):

$$\alpha_{\text{obs}} = \operatorname{clamp}_{[0.35, 0.95]}\!\left(\exp\!\left(-\frac{d_{\min}}{38.0\text{ km}}\right) \cdot \exp\!\left(-\frac{\Delta t_{\min}}{3600\text{ s}}\right) \cdot \min\!\left(1.0,\; 0.70 + 0.10 \, N_{\text{stations}}\right)\right)$$

$$X_{\text{fused}} = \alpha_{\text{obs}} X_{\text{obs}} + (1 - \alpha_{\text{obs}}) X_{\text{model}}$$

Furthermore, siguiendo **Model Output Statistics (MOS)** nowcast bias correction (Glahn & Lowry, 1972), the observed temperature innovation $\Delta T_0 = T_{\text{fused}}(t_{\text{now}}) - T_{\text{NWP}}(t_{\text{now}})$ is propagated into the upcoming 6 hours of the hourly strip with an exponential relaxation timescale $\tau_{\text{MOS}} = 3.5\text{ hours}$:

$$T_{\text{corrected}}(t_k) = T_{\text{NWP}}(t_k) + \Delta T_0 \cdot \exp\!\left(-\frac{t_k - t_{\text{now}}}{3.5\text{ h}}\right), \qquad 0 \le t_k - t_{\text{now}} \le 6\text{ h}$$

---

## 7. Psychrometrics, Thermodynamics & Apparent Temperature

**Implementation:** [`Weather/Detail/LiveStationFetcher.swift:485-580`](Weather/Detail/LiveStationFetcher.swift#L485-L580)

### 7.1 Magnus-Tetens Saturation Vapor Pressure (Alduchov & Eskridge, 1996)

Given dry-bulb temperature $T$ ($^\circ\text{C}$) and dewpoint temperature $T_d$ ($^\circ\text{C}$), relative humidity $\text{RH} \in [0, 100]\%$ is computed via the improved **Alduchov & Eskridge (1996)** Magnus coefficients ($a = 17.625$, $b = 243.04^\circ\text{C}$):

$$\text{RH}(T, T_d) = 100 \cdot \exp\!\left(\frac{17.625 \, T_d}{243.04 + T_d} - \frac{17.625 \, T}{243.04 + T}\right)$$

Conversely, when inverting $(T, \text{RH})$ to obtain dewpoint $T_d$:

$$\gamma(T, \text{RH}) = \ln\!\left(\frac{\text{RH}}{100}\right) + \frac{17.625 \, T}{243.04 + T}, \qquad T_d = \frac{243.04 \, \gamma(T, \text{RH})}{17.625 - \gamma(T, \text{RH})}$$

### 7.2 Psychrometric Wet-Bulb Temperature (Stull, 2011)

Displayed on the Humidity card alongside the dewpoint, the thermodynamic wet-bulb temperature $T_w$ ($^\circ\text{C}$) is evaluated using **Stull's (2011)** empirical inverse psychrometric formula (accurate to $\pm 0.3^\circ\text{C}$ across $\text{RH} \in [5\%, 99\%]$ and $T \in [-20^\circ\text{C}, 50^\circ\text{C}]$):

$$\begin{aligned}
T_w &= T \arctan\!\Big(0.151977 \sqrt{\text{RH} + 8.313659}\Big) + \arctan(T + \text{RH}) - \arctan(\text{RH} - 1.676331) \\
&\quad + 0.00391838 \, \text{RH}^{3/2} \arctan(0.023101 \, \text{RH}) - 4.686035
\end{aligned}$$

### 7.3 NWS Heat Index (Rothfusz, 1990) & Wind Chill (Osczevski & Bluestein, 2005)

To compute apparent ("Feels Like") temperature from assimilated surface observations $(T, \text{RH}, V_{\text{km/h}})$:

1. **Cold Regime ($T \le 10.0^\circ\text{C}$ and $V > 4.8\text{ km/h}$):**  
   Uses the North American **NWS / Environment Canada Wind Chill Index** (Osczevski & Bluestein, 2005):
   $$T_{\text{wc}} = 13.12 + 0.6215 \, T - 11.37 \, V^{0.16} + 0.3965 \, T \, V^{0.16} \quad (^\circ\text{C})$$
2. **Warm Regime ($T \ge 26.7^\circ\text{C} = 80^\circ\text{F}$ and $\text{RH} \ge 40\%$):**  
   Converts $T$ to Fahrenheit $T_F = 1.8 T + 32$ and evaluates the **NWS Rothfusz (1990)** Steadman multiple regression polynomial:
   $$\begin{aligned}
   \text{HI}_F &= -42.379 + 2.04901523 \, T_F + 10.14333127 \, R - 0.22475541 \, T_F R \\
   &\quad - 0.00683783 \, T_F^2 - 0.05481717 \, R^2 + 0.00122874 \, T_F^2 R \\
   &\quad + 0.00085282 \, T_F R^2 - 0.00000199 \, T_F^2 R^2
   \end{aligned}$$
   with standard NWS low-humidity ($R < 13\%, T_F \in [80, 112]^\circ\text{F}$) and high-humidity ($R > 85\%, T_F \in [80, 87]^\circ\text{F}$) adjustments.
3. **Turbulent Gust Excess Blending:**  
   Station wind speed and gusts are blended separately: sustained wind $V$ is blended linearly across stations, while turbulent gust excess $\Delta G_i = \max(0, G_i - V_i)$ is combined via **root-mean-square (RMS)** turbulent kinetic energy scaling:
   $$G_{\text{blended}} = V_{\text{blended}} + \sqrt{\frac{\sum_i w_i (\Delta G_i)^2}{\sum_i w_i}}$$

---

## 8. Radiative Cloud Transmittance & EPA AirNow AQI Interpolation

**Implementation:** [`Weather/Detail/LiveStationFetcher.swift:362-414, 620-730`](Weather/Detail/LiveStationFetcher.swift#L362-L414)

### 8.1 Multi-Layer Random-Overlap Radiative Cloud Cover

Aviation METAR reports provide up to 4 cloud decks (`FEW` $= 1\text{–}2$ oktas $\approx 18\%$, `SCT` $= 3\text{–}4$ oktas $\approx 44\%$, `BKN` $= 5\text{–}7$ oktas $\approx 75\%$, `OVC` $= 8$ oktas $= 100\%$, `CLR`/`SKC`/`CAVOK` $= 0\%$) with cloud base height in feet AGL. High thin cirrus (`> 18,000 ft`) has much higher shortwave solar transmittance than low stratus (`< 6,500 ft`). We model the effective radiative cloud fraction $C_{\text{eff}}$ via **random-overlap radiative transmittance**:

$$C_{\text{eff}} = 100 \cdot \left(1 - \prod_{k=1}^{K} \big(1 - \alpha_k \, c_k\big)\right)$$

where $c_k \in [0, 1]$ is layer $k$'s geometric sky fraction and $\alpha_k$ is its altitude-dependent optical opacity weight:
- Low deck ($z_{\text{base}} < 6{,}500\text{ ft}$): $\alpha_k = 1.00$
- Mid deck ($6{,}500\text{ ft} \le z_{\text{base}} < 18{,}000\text{ ft}$): $\alpha_k = 0.85$
- High cirrus deck ($z_{\text{base}} \ge 18{,}000\text{ ft}$): $\alpha_k = 0.55$

### 8.2 US EPA AirNow Inverse-Distance-Squared AQI Interpolation

For US locations, [`LiveStationFetcher.swift`](Weather/Detail/LiveStationFetcher.swift) queries real-time EPA AirNow monitors (`O3`, `PM2.5`, `PM10`) and interpolates the Air Quality Index using inverse-distance-squared weighting with a $2.0\text{ km}$ core softening radius:

$$w_{\text{AQI},i} = \frac{1}{\max(d_i, 2.0\text{ km})^2}, \qquad \text{AQI}_{\text{interp}} = \operatorname{round}\!\left(\frac{\sum_i w_{\text{AQI},i} \, \text{AQI}_i}{\sum_i w_{\text{AQI},i}}\right)$$

and classifies into the 6 statutory US EPA categories (40 CFR Part 58 Appendix G):
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

$$a = \operatorname{clamp}_{[0, 1]}\!\left(\sin^2\!\left(\frac{\Delta \phi}{2}\right) + \cos \phi_1 \cos \phi_2 \sin^2\!\left(\frac{\Delta \lambda}{2}\right)\right), \qquad d = 2 R_\oplus \arcsin(\sqrt{a})$$

Antipodal rounding noise where $a$ slightly exceeds $1.0$ in IEEE-754 arithmetic is clamped to $1.0$ so $\sqrt{a}$ and $\arcsin(\sqrt{a})$ never produce `NaN`.

### 9.2 NOAA / Meeus Solar Position Algorithm (`WxGeo.isDaylight`)

To determine whether an hourly timestamp $t_S$ is in daylight (`isDay`) at $(\phi, \lambda)$ without requiring external ephemeris tables, [`Geo.swift:120-210`](WeatherCore/Core/Geo.swift#L120-L210) implements the **NOAA Global Monitoring Laboratory / Meeus (1998)** astronomical algorithm:

1. **Julian Century from J2000.0 ($2000\text{-}01\text{-}01\text{ }12\text{:}00\text{ UTC} = 946728000\text{ s}$):**
   $$T = \frac{(t_S - 946728000) / 86400.0}{36525.0}$$
2. **Geometric Mean Longitude $L_0$, Mean Anomaly $M$, and Eccentricity $e$:**
   $$L_0 = (280.46646 + 36000.76983 \, T + 0.0003032 \, T^2) \bmod 360^\circ$$
   $$M = 357.52911 + 35999.05029 \, T - 0.0001537 \, T^2$$
   $$e = 0.016708634 - 0.000042037 \, T - 0.0000001267 \, T^2$$
3. **Equation of Center $C$, Apparent Solar Longitude $\lambda_\odot$, and Obliquity $\varepsilon$:**
   $$C = (1.914602 - 0.004817 \, T - 0.000014 \, T^2)\sin M + (0.019993 - 0.000101 \, T)\sin(2M) + 0.000289\sin(3M)$$
   $$\Omega = 125.04 - 1934.136 \, T, \qquad \lambda_\odot = L_0 + C - 0.00569 - 0.00478 \sin \Omega$$
   $$\varepsilon_0 = 23.439291 - 0.0130042 \, T - 1.639\times 10^{-7} T^2 + 5.036\times 10^{-7} T^3, \qquad \varepsilon = \varepsilon_0 + 0.00256 \cos \Omega$$
4. **Solar Declination $\delta$, Equation of Time $\text{EoT}$ (minutes), and Solar Elevation $\alpha_\odot$:**
   $$\sin \delta = \sin \varepsilon \sin \lambda_\odot$$
   $$y = \tan^2(\varepsilon / 2), \qquad \text{EoT} = 4 \cdot \frac{180}{\pi}\Big(y \sin(2L_0) - 2e \sin M + 4e y \sin M \cos(2L_0) - \tfrac{1}{2} y^2 \sin(4L_0) - \tfrac{5}{4} e^2 \sin(2M)\Big)$$
   $$\text{TST} = \left(\frac{t_S \bmod 86400}{60.0} + \text{EoT} + 4 \lambda\right) \bmod 1440, \qquad H = \frac{\text{TST}}{4} - 180^\circ$$
   $$\sin \alpha_\odot = \sin \phi \sin \delta + \cos \phi \cos \delta \cos H$$
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
  - Shown on the 24-hour chart; represents the **hourly probability of precipitation** ($0\%\text{ to }100\%$).
  - Interpolated via a monotone cubic Hermite spline (Fritsch & Carlson, 1980) with tangents clamped to $[0\%, 100\%]$ so the curve never overshoots the plot bounds.
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
All JSON stores (`places.json`, `settings.json`, `forecasts.json`, `weights.json`) are written via a temporary sibling file (`<name>.tmp.<pid>.<counter>`) with mode `0600`, flushed to physical non-volatile media via `fcntl(fd, F_FULLFSYNC)` (falling back to `fsync`), atomically renamed over the target path via POSIX `rename(2)`, and followed by `fsync` on the parent directory descriptor.

---

## 13. Architectural Decision Records (ADRs)

| ADR | Decision | Rationale |
| :--- | :--- | :--- |
| **ADR-01** | **Preserve Bundle ID `io.github.wtp128pro.Weather` while renaming display name to `Neginato Mezora`** | Keeps Apple Developer ID provisioning profiles, notarization tickets, Keychain / UserDefaults domains, and macOS sandbox container paths (`~/Library/Containers/io.github.wtp128pro.Weather/`) 100% compatible without data migration loss. |
| **ADR-02** | **Weighted Median for Continuous Variables, Weighted Mean for Probability** | Eliminates single-model outlier contamination ("ensemble drizzle bias") on physical quantities while preserving calibrated probability expectations. |
| **ADR-03** | **Native macOS Settings (`⌘,`) Replacing Hamburger Popover** | Aligns with macOS Human Interface Guidelines and `Neginato` (`../../music`), providing dedicated grouped tabs (`Sources`, `Weights`, `General`) with interactive sliders for both provider and per-model weights. |
| **ADR-04** | **Persist Custom Weights in `weights.json` Separate from `settings.json`** | Guarantees byte-for-byte backward compatibility with the strict C `settings.json` schema (`version`, `units`, `disabled_providers`, `selected`) and its fuzz/roundtrip test suite. |
| **ADR-05** | **Dual-Series Labeled Rain Charts with Direct Peak Callouts & Hover Inspection** | Resolves ambiguity between bars (Rain rate in `in/h` or `mm/h`, left Y-axis) and curve (Rain chance in `%`, right Y-axis) via explicit pill legends, color-matched axis labels (`Rate · <max>/h`, `<mid>/h`, `0`, `100%`, `50%`, `0%`), peak badges, and live hover inspection. |

---

## 14. Academic, Institutional & Standard Citations

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
