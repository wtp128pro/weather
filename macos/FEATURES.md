# Neginato Mezora — Feature & User Guide

For full mathematical derivations, weight matrices, and academic citations, see **[`ALGORITHMS_AND_ARCHITECTURE.md`](ALGORITHMS_AND_ARCHITECTURE.md)**.

---

## 1. Rain Graph & Bars Guide

The **Rain** card at the top of the detail pane answers two distinct questions simultaneously—*how hard will it rain* (**Bars**) and *how likely is it to rain* (**Curve**):

| Visual Element | Series Pill Legend | Y-Axis | Meaning & Units |
| :--- | :--- | :--- | :--- |
| **Cyan-Blue Vertical Bars** | `Bars: Rain rate (in/h, left)` or `(mm/h, left)` | **Left Axis** (`Rate · <max>/h`, `<mid>/h`, `0`) | Expected precipitation intensity during that 15-minute or 1-hour slot. Direct callout badges annotate the highest non-zero bars. |
| **Amber-Rose Smooth Curve** | `Line: Rain chance (%, right)` | **Right Axis** (`100%`, `50%`, `0%`) | Probability of measurable precipitation ($\ge 0.1\text{ mm/h}$) during each hour of the 24-hour outlook. |
| **Hover Inspection Guide** | Floating banner on hover | Both Axes | Hovering over any slot displays the exact time, bar rain rate, and curve rain chance percentage. |

- **Next 2 hours (15-min bars):** Appears automatically across the US, Canada, UK, Netherlands, Germany, and Europe whenever 15-minute sub-hourly nowcast data is available and covers at least the next 30 minutes.
- **Next 24 hours (Hourly bars & curve):** Always shown when hourly forecast data is available.

---

## 2. Settings Dialogue (`⌘,`) — Data Sources & Weights

Open **Settings** via `Neginato Mezora > Settings…` (`⌘,`), `Neginato Mezora > Data Sources & Weights…`, or the **gear (`⚙`)** button in the top-right toolbar:

1. **Sources Tab:**
   - Toggle **Open-Meteo**, **National Weather Service**, **MET Norway**, **DWD Bright Sky**, and **Environment Canada** on or off.
   - View real-time status for the currently selected location (e.g., `Used for this place (7 forecast models)`).
   - Adjust each provider's **Source weight multiplier** (`0.10×` to `3.00×`, default `1.00×`).
   - Inspect data attribution and open official license links (`CC BY 4.0`, `NLOD`, `Open Government Licence – Canada`, `US government work`).
2. **Weights Tab:**
   - Select any regional profile (`Inspect Regional Profile`: United States, UK & Ireland, Netherlands & Benelux, Germany & Central Europe, Canada, Nordic & Baltic, Rest of Europe, or Rest of World) and variable group (`Temperature & Feels Like`, `Wind & Gusts`, `Cloud Cover`, `Relative Humidity`, `Precipitation Amount`, `Precipitation Chance`) to inspect the 4 lead-time horizon bands (`H0: 0–3h`, `H1: 3–18h`, `H2: 18–72h`, `H3: 72h+`) plus `World`.
   - Adjust individual model multipliers (`0.00×` to `3.00×`) for all 13 NWP models (`NOAA NWS`, `HRRR`, `NBM`, `ECMWF IFS`, `GFS`, `ICON`, `GEM`, `UKMO`, `Météo-France`, `KNMI HARMONIE`, `MET Norway`, `DWD MOSMIX`, `ECCC HRDPS`).
   - Click **Reset All to 1.00×** at any time to restore the baseline heuristic table.
3. **General Tab:**
   - Switch between **Imperial (`°F, mph, in`)** and **Metric (`°C, km/h, mm`)**.
   - Open the **Neginato Mezora Help Book (`⌘?`)** or the **About Neginato Mezora** panel.

---

## 3. Live Physical Station & Air Quality Assimilation

For every selected location, **Neginato Mezora** queries nearby physical weather stations and air quality monitors in real time:
- **AviationWeather METAR + NWS ASOS + DWD/KNMI Bright Sky SYNOP:** Assimilates up to 16 airport/ASOS/AWOS stations within 95 km plus 10-minute DWD/KNMI surface observations using 3D anisotropic distance & elevation weighting, diurnal lapse-rate reduction, Shepard directional de-clustering, and MAD outlier quality control.
- **US EPA AirNow & Copernicus CAMS / EEA:** Displays real-time Air Quality Index (AQI / EAQI), pollutant concentrations (`PM2.5`, `NO₂`, `O3`), health guidance, and 24-hour AQI trend comparison.
- **10-Day Temperature Range Bars & Cloud Cover:** Displays proportional daily temperature range bars with current-temperature indicators, wet-bulb and dewpoint temperatures, and radiative cloud cover breakdowns.

---

## 4. Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `⌘N` | Open **Add a City / Street Address / Coordinates** picker |
| `⌘R` | Refresh the selected place immediately |
| `⌘U` | Toggle display units between Imperial (`°F`) and Metric (`°C`) |
| `⌘,` | Open **Neginato Mezora Settings** (`Sources`, `Weights`, `General`) |
| `⌘?` | Open **Neginato Mezora Help Book** |
| `⌘Q` | Flush pending saves and quit Neginato Mezora |
