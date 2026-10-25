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

## 2. Settings Dialogue (`⌘,`) — Sources, Weights & Stations

Open **Settings** via `Neginato Mezora > Settings…` (`⌘,`, Sources tab), `Neginato Mezora > Data Sources & Weights…` (Weights tab), `Neginato Mezora > Stations & Keys…` (Stations tab), or the **gear (`⚙`)** button in the top-right toolbar:

1. **Sources Tab:**
   - Toggle **Open-Meteo**, **National Weather Service**, **MET Norway**, **DWD Bright Sky**, and **Environment Canada** on or off.
   - View real-time status for the currently selected location (e.g., `Used for this place (7 forecast models)`).
   - Adjust each provider's **Source weight multiplier** (`0.10×` to `3.00×`, default `1.00×`).
   - Inspect data attribution and open official license links (`CC BY 4.0`, `NLOD`, Environment and Climate Change Canada's `Data Server End-use Licence`, `US government work`).
2. **Weights Tab:**
   - Select any regional profile (`Inspect Regional Profile`: United States, UK & Ireland, Netherlands & Benelux, Germany & Central Europe, Canada, Nordic & Baltic, Rest of Europe, or Rest of World) and variable group (`Temperature & Feels Like`, `Wind & Gusts`, `Cloud Cover`, `Relative Humidity`, `Precipitation Amount`, `Precipitation Chance`) to inspect the 4 lead-time horizon bands (`H0: 0–3h`, `H1: 3–18h`, `H2: 18–72h`, `H3: 72h+`) plus `World`.
   - Adjust individual model multipliers (`0.00×` to `3.00×`) for all 13 NWP models (`NOAA NWS`, `HRRR`, `NBM`, `ECMWF IFS`, `GFS`, `ICON`, `GEM`, `UKMO`, `Météo-France`, `KNMI HARMONIE`, `MET Norway`, `DWD MOSMIX`, `ECCC HRDPS`).
   - Click **Reset All to 1.00×** at any time to restore the baseline heuristic table.
3. **Stations Tab:**
   - **Learned Local Corrections:** turn the corrections on or off for all places (learning continues while off); see, for every place, how many hours of the day are learned, the correction applied now, and a bar per local hour of today; **Reset** one place or **Reset All…**.
   - **Networks That Need Your Free Key:** Met Office (UK), KNMI (Netherlands), MET Norway Frost (Norway), Météo-France (France) and AEMET (Spain). Paste your free key (stored in the login Keychain, sent only to its own service), follow the built-in sign-up steps, see the key's expiry (AEMET keys expire after 3 months) and a live status line (working, key refused, limit reached, unreachable).
   - **Networks Used Without a Key:** a switch per network, with its status and credit.
   - **Stations Near the selected place:** every station within 60 km with its weight and the reason (good, on probation, reduced, not used, stuck); **Forget All Stations…** clears the catalog.
4. **General Tab:**
   - Switch between **Imperial (`°F, mph, in`)** and **Metric (`°C, km/h, mm`)**.
   - Open the **Neginato Mezora Help Book (`⌘?`)** or the **About Neginato Mezora** panel.

---

## 3. Live Physical Station & Air Quality Assimilation

For every selected location, **Neginato Mezora** queries nearby physical weather stations and air quality monitors in real time:
- **Every reachable station, one algorithm everywhere:** Airport METARs worldwide; in the US, 5-minute NWS ASOS reports and the Iowa Environmental Mesonet's road-weather, hydrological and research stations; in Canada, Environment Canada's SWOB stations (including partner networks); in Europe, the national networks of Germany (DWD), Denmark (DMI), Finland (FMI), Sweden (SMHI), Austria (GeoSphere) and Switzerland (MeteoSwiss). Up to 12 sites within 60 km are blended using 3D anisotropic distance & elevation weighting, diurnal lapse-rate reduction, Shepard directional de-clustering, and MAD outlier quality control.
- **Stations are tested on every refresh:** each station is compared with what its neighbours predict for it; one that is biased (including only by day, like a sun-exposed sensor), noisy or stuck loses weight or is excluded. Stations that stop reporting for 3 days of app use are dropped; new or returning stations start on probation. The catalog is kept on disk, so restarts lose nothing, and time with the app closed never counts.
- **The forecast learns from the stations:** when close, fresh stations are available, the difference between what they measure and what the models said is learned for each place and hour of the day (e.g. a valley that runs 3 °C colder at dawn). After a few days the whole forecast — hourly temperatures, feels-like and daily highs/lows — is corrected by up to ±4 °C. The learning stays on this Mac and fades out after a month without updates.
- **More stations with a free key:** in the UK, the Netherlands, Norway, France and Spain, the national network joins the same pool once you save its free key (Settings › Stations; the Help Book walks through each sign-up).
- **Credits:** the forecast page names every station network whose data is shown, as their licences ask (with the date of the data for Météo-France and AEMET).
- **Air Quality card — a real reading or nothing:** outside Europe, the nearest US EPA AirNow monitor within 45 km (US and Canada), shown exactly as reported and marked preliminary; elsewhere the Copernicus CAMS air-quality forecast (via Open-Meteo), labelled as a model forecast, with PM2.5, NO₂ and in Europe the European AQI. The comparison with yesterday uses the same monitor (or the CAMS value) 24 hours earlier. The scale uses the six EPA category colours. Without data the card shows a dash; nothing is estimated from the weather.
- **10-Day Temperature Range Bars & Cloud Cover:** proportional daily temperature range bars on one shared scale with a current-temperature dot, and cloud cover in which high thin cloud counts less than low thick cloud.

---

## 4. Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `⌘N` | Open **Add a City / Street Address / Coordinates** picker |
| `⌘R` | Refresh the selected place immediately |
| `⌘U` | Toggle display units between Imperial (`°F`) and Metric (`°C`) |
| `⌘,` | Open **Neginato Mezora Settings** (`Sources`, `Weights`, `Stations`, `General`) |
| `⌘?` | Open **Neginato Mezora Help Book** |
| `⌘Q` | Flush pending saves and quit Neginato Mezora |
