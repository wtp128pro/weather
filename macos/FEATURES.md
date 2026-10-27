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
   - Inspect data attribution and open official license links (`CC BY 4.0`, `NLOD`, Environment and Climate Change Canada's `Data Server End-use Licence`, `US government work`). The **Weather alerts** credits (§4) are listed in the **About Neginato Mezora** panel (the app menu, or the General tab), not here.
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
   - **Default Units for New Places:** **Imperial (`°F, mph, in`)** or **Metric (`°C, km/h, mm`)**. It sets the units a new place starts with when none is chosen for it; places already saved keep their own (§5).
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
- **Now-card wind compass:** a dial on the right of the now card with the speed in the centre, gusts and the direction the wind comes from (e.g. `from NNE 31°`) beneath it, a dot at that bearing and an arrow pointing downwind. The direction is the speed-weighted vector average of the nearby stations that report one, falling back to Open-Meteo's current `wind_direction_10m`; with no direction, or calm wind, no arrow is drawn. Humidity has its own pill beside Feels like and High · Low.
- **10-Day Temperature Range Bars & Cloud Cover:** proportional daily temperature range bars on one shared scale with a current-temperature dot, and cloud cover in which high thin cloud counts less than low thick cloud.

---

## 4. Official Weather Alerts

Every place shows the warnings its official issuer has in force — no key, no account:

| Place | Issuer |
| :--- | :--- |
| United States and its territories (and a place without a country inside the NWS area) | NOAA National Weather Service (`api.weather.gov`) |
| Germany | Deutscher Wetterdienst, via Bright Sky |
| Norway | MET Norway (MetAlerts) |
| Canada | Environment and Climate Change Canada |
| Austria, Belgium, Bosnia and Herzegovina, Bulgaria, Croatia, Cyprus, Czechia, Denmark, Estonia, Finland, France, Greece, Hungary, Iceland, Ireland, Italy, Latvia, Lithuania, Luxembourg, Malta, Moldova, Montenegro, the Netherlands, North Macedonia, Poland, Portugal, Romania, Serbia, Slovakia, Slovenia, Spain, Sweden, Switzerland, Ukraine, the United Kingdom, and Israel | MeteoAlarm (the country's feed) |
| Any other country | none: `Alerts not available` |

- **Matching MeteoAlarm warnings to a place:** each warning area is matched against the region table bundled with the app (MeteoAlarm geocodes with EuroGeographics boundaries) or against the warning's own polygons; a warning that cannot be placed is dropped, and a place outside every region its country's feed uses reads `Alerts not available`.
- **Sidebar:** a warning triangle after the place's name, coloured by the highest level (red, orange, yellow, minor), with a count when there is more than one alert.
- **Alerts section (detail pane):** one card per current alert with the event, level, start and end times, headline, an expandable description, the instructions and a link to the source when the issuer gives one.
- **States:** `Checking for alerts…` (not yet checked), `No active alerts`, `Alerts could not be checked right now.` (the check failed and no earlier set is still valid), `Alerts could not be checked recently.` plus the time last checked (the last set is too old; it is hidden, not shown as current), and `Alerts not available` (no issuer covers the place).
- **How often:** alerts are checked after each completed forecast refresh, never while offline and never on a timer of their own. A successful download of a country's MeteoAlarm feed is reused by all its places for 30 minutes; a failed one is held for only 120 seconds, shared by every place in that country, and a later refresh tries again. An answer from the other four issuers is reused for 5 minutes. An alert disappears when it expires, without a new download. A failed or slow alert check never delays or changes the forecast; a still-valid set survives one failed check.
- **Window only:** alerts are shown in the app window; there are no system notifications.
- **Limits:** alert areas follow each issuer's published region shapes, which can differ from local boundaries near borders and coasts. A few Irish border towns (Waterford city centre, Youghal, Carrick-on-Shannon, Killaloe) lie inside a neighbouring county's MeteoAlarm outline, so a warning for their own county may not reach them while a neighbour's does; some coastal places and islands (for example Howth, Bray, Greystones, Malahide, Tory Island, Cape Clear) are reached only by marine warnings or read `Alerts not available`. After a failed MeteoAlarm download, a refresh round that lasts longer than 120 seconds can cost one more download of that feed for each further 120 seconds.

---

## 5. Units Per Place

- **Each place has its own units:** Imperial (`°F, mph, in`) or Metric (`°C, km/h, mm`), shown in its sidebar row, detail pane and charts.
- **Adding a place:** the units picker in the add window is labelled with the highlighted place (**Units for** *name, region*; just **Units** while there are no results) and preselected from that place's country — Imperial for the US, Puerto Rico, Guam, the US Virgin Islands, American Samoa, the Northern Mariana Islands, the US Minor Outlying Islands, Liberia and Myanmar; Metric elsewhere; the default for new places when the country is unknown. A choice you make there holds for every place that window adds. On first run, the picker under the city suggestions is labelled with the highlighted city the same way and preselected from its country; a choice you make holds for every city added there.
- **Changing a place:** the toolbar units button and `⌘U` switch the selected place (tooltip and menu command **Switch Selected Place to Celsius** / **Fahrenheit**); with no place selected they change the **Default Units for New Places** (also in Settings › General), and the tooltip and menu command read **Set Default Units to Celsius** / **Fahrenheit**.
- **Upgrading:** places saved by an earlier version have no units of their own; on the first launch of this version each takes the units the app was set to, and the list is saved once.

---

## 6. Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `⌘N` | Open **Add a City / Street Address / Coordinates** picker |
| `⌘R` | Refresh the selected place immediately |
| `⌘U` | **Switch Selected Place to Celsius** / **Fahrenheit**; with no place selected, **Set Default Units to Celsius** / **Fahrenheit** (the default units for new places) |
| `⌘,` | Open **Neginato Mezora Settings** (`Sources`, `Weights`, `Stations`, `General`) |
| `⌘?` | Open **Neginato Mezora Help Book** |
| `⌘Q` | Flush pending saves and quit Neginato Mezora |
