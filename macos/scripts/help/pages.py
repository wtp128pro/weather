#!/usr/bin/env python3
"""The bodies of the Help Book pages (HTML), keyed by page id (SECTIONS in _helplib.py).

Every statement here describes what the app does; keep it in step with the code. The weight
tables of the sources-weights page come from weight_tables.html (weight_tables.py), and
HelpBookTests checks them against WxWeights.
"""

from __future__ import annotations
from pathlib import Path

WEIGHT_TABLES_MARKER = "<!-- WEIGHT_TABLES -->"
WEIGHT_TABLES = Path(__file__).resolve().parent / "weight_tables.html"

PAGE_BODIES: dict[str, str] = {
    "index": """
<h1>Welcome to Neginato Mezora</h1>
<p><strong>Neginato Mezora</strong> shows the weather for the places you save, with an emphasis on accuracy and on <em>when it will rain</em>. Every forecast is a blend of up to 13 forecast models from five free services (Open-Meteo, the US National Weather Service, MET Norway, the German weather service DWD via Bright Sky, and Environment Canada). The current conditions are grounded in live readings of nearby weather stations, and the forecast learns each place's local quirks from those stations.</p>

<div class="callout">
    <strong>Start here</strong>
    <ol>
        <li><strong>Add a place:</strong> press <kbd>⌘N</kbd> (or the <strong>+</strong> button) and type a city, street address, ZIP or postal code, landmark, or coordinates. See <a href="places.html">Adding &amp; Managing Places</a>.</li>
        <li><strong>Read the forecast:</strong> select the place in the sidebar. The detail pane shows now, rain, air quality, clouds, the next 48 hours and the next days. See <a href="forecast-page.html">Reading the Forecast</a>.</li>
        <li><strong>Get more stations (optional):</strong> in the UK, the Netherlands, Norway, France and Spain, a free key from the national weather service adds its stations. See <a href="station-keys.html">Free Keys for More Stations</a>.</li>
    </ol>
</div>

<h2>What the app does for accuracy</h2>
<table>
    <thead>
        <tr><th>Layer</th><th>What it does</th><th>Learn more</th></tr>
    </thead>
    <tbody>
        <tr><td><strong>Model blend</strong></td><td>Up to 13 forecast models are combined hour by hour with a weighted median, with weights that depend on the region and on how far ahead the hour is (high-resolution national models lead the first hours; the best global models lead later).</td><td><a href="sources-weights.html">Data Sources &amp; Weights</a>, <a href="algorithms.html">Algorithms</a></td></tr>
        <tr><td><strong>15-minute rain</strong></td><td>Where a 15-minute model is available (US, Canada, UK, Netherlands, Germany and much of Europe), the next 2 hours of rain are shown in 15-minute steps.</td><td><a href="rain-chart.html">Rain Graph &amp; Bars</a></td></tr>
        <tr><td><strong>Live stations</strong></td><td>Every station network that covers the place is read at each refresh (airports worldwide plus national, road-weather and research networks), the stations are tested against each other, and the trusted ones are blended into the "now" values.</td><td><a href="live-stations.html">Live Station Observations</a></td></tr>
        <tr><td><strong>Learned local corrections</strong></td><td>For each place and hour of the day, the app learns how far the models run from what close stations measure, and corrects the forecast temperatures, feels-like, highs and lows by up to ±4 °C (±7 °F).</td><td><a href="local-corrections.html">Learned Local Corrections</a></td></tr>
        <tr><td><strong>Air quality</strong></td><td>The nearest air-quality monitor's reading as reported (US and Canada), otherwise the CAMS air-quality forecast. Never estimated from the weather.</td><td><a href="forecast-page.html">Reading the Forecast</a></td></tr>
        <tr><td><strong>Weather alerts</strong></td><td>The official warnings in force for the place, as its issuer published them: the national weather service in the US, Canada, Germany and Norway, MeteoAlarm in 35 more European countries and Israel. Shown on the forecast page and as a warning sign in the sidebar; never made up or estimated by the app.</td><td><a href="weather-alerts.html">Weather Alerts</a></td></tr>
    </tbody>
</table>

<h2>Where things are</h2>
<ul>
    <li><strong>Sidebar:</strong> your saved places (up to 50), each with its temperature in that place's own units, a rain hint and, when an official alert is in force, a warning sign. Drag to reorder; the <strong>…</strong> button names, moves or removes a place.</li>
    <li><strong>Toolbar:</strong> <strong>+</strong> (add a place), refresh, the unit button (<strong>°F</strong>/<strong>°C</strong>, the selected place's units), and the gear (Settings).</li>
    <li><strong>Settings (<kbd>⌘,</kbd>):</strong> four tabs: <strong>Sources</strong>, <strong>Weights</strong>, <strong>Stations</strong> and <strong>General</strong>. The app menu also has <strong>Data Sources &amp; Weights…</strong> and <strong>Stations &amp; Keys…</strong>, which open those tabs directly.</li>
    <li><strong>Help (<kbd>⌘?</kbd>):</strong> this book. The search field at the top left searches every page, and the Help menu opens the main pages directly.</li>
</ul>

<h2>All help pages</h2>
<ul>
    <li><a href="places.html">Adding &amp; Managing Places</a></li>
    <li><a href="forecast-page.html">Reading the Forecast</a></li>
    <li><a href="rain-chart.html">Rain Graph &amp; Bars Guide</a></li>
    <li><a href="weather-alerts.html">Weather Alerts</a></li>
    <li><a href="units-refresh.html">Units, Refreshing &amp; Offline</a></li>
    <li><a href="shortcuts.html">Keyboard Shortcuts &amp; Menus</a></li>
    <li><a href="sources-weights.html">Settings: Data Sources &amp; Weights</a></li>
    <li><a href="stations-settings.html">Settings: Stations</a></li>
    <li><a href="station-keys.html">Free Keys for More Stations</a></li>
    <li><a href="local-corrections.html">Learned Local Corrections</a></li>
    <li><a href="live-stations.html">Live Station Observations</a></li>
    <li><a href="algorithms.html">Ensemble Blending &amp; Citations</a></li>
    <li><a href="privacy.html">Privacy, Data &amp; Storage</a></li>
    <li><a href="troubleshooting.html">Troubleshooting &amp; FAQ</a></li>
</ul>
""",
    "places": """
<h1>Adding &amp; Managing Places</h1>
<p>You can save up to <strong>50 places</strong>. The list, its order, the names you give and the selected place are kept between launches.</p>

<h2>Adding a place</h2>
<p>Press <kbd>⌘N</kbd>, click <strong>+</strong> in the toolbar, or (when the list is empty) click <strong>Add a city</strong>. The <strong>Add a city</strong> window opens.</p>
<ol>
    <li><strong>Type what you are looking for</strong> in <em>Address, Landmark, or City</em>: a city ("Lyon"), a street address ("1600 Pennsylvania Ave NW, Washington"), a ZIP or postal code, a landmark, or coordinates such as <code>25.76, -80.19</code>, <code>25.76 -80.19</code> or <code>25.76°, -80.19°</code>. At least 2 characters are needed. With an empty field the window suggests a few cities.</li>
    <li><strong>Optionally give it a name</strong> in <em>Location Name</em>: type one, or click a preset (Home, Work, Friend's place, Family, School, Gym, Vacation; click again to clear it). The name replaces the place name in the sidebar and in the forecast header, and picks a matching symbol (a house for Home, a briefcase for Work, and so on).</li>
    <li><strong>Check the units</strong> in the units menu, labelled <strong>Units for</strong> and the name (with its state or province) of the result that would be added (<strong>Units</strong> while there is no result): <strong>Imperial (°F, mph, in)</strong> or <strong>Metric (°C, km/h, mm)</strong>. Until you pick one yourself it follows the result that would be added, by its country: Imperial for the United States and its territories, Liberia and Myanmar, Metric elsewhere, and the <a href="units-refresh.html">default units for new places</a> when the country is not known. Once you pick, your pick is saved with every place this window adds. Each place keeps its own units.</li>
    <li><strong>Add it:</strong> double-click a result, press Return or Space on the highlighted result, or click its <strong>Add</strong> button. Return in the name field adds the highlighted (or first) result. A place you already saved shows <strong>Added</strong>.</li>
</ol>
<p>The window closes after a successful add, and the new place is selected. <kbd>Esc</kbd> closes the window without adding. There is no map to pick a point on: to save an exact spot, type its coordinates.</p>
<p>With an empty list, the first page suggests a few cities to add with one click. Its units menu works the same way for them: it is labelled <strong>Units for</strong> and the city under the pointer or keyboard focus (the first city when neither is on one), and follows that city's country until you pick. A pick there is not carried into the Add a city window.</p>

<h3>How the search works</h3>
<ul>
    <li>Two searches run side by side as you type: a weather-location search of cities (Open-Meteo, up to 10 results), and an address search that asks Apple Maps, OpenStreetMap Nominatim and Photon, plus the US Census geocoder for text that starts with a house number.</li>
    <li>When the address search finds anything, its results are shown (up to 20, duplicates merged: the same title within 150 m, or the same city within 5 km). Otherwise the city results are shown.</li>
    <li>Typed coordinates are named by a reverse lookup; when that fails the result is titled with the coordinates and described as <em>Exact coordinates</em>.</li>
    <li>The status line tells you what is happening: <em>Searching addresses and weather locations…</em>, <em>Matching addresses &amp; locations (N)</em>, <em>Type at least 2 letters</em>, <em>No results</em>, or <em>Search failed: …</em>.</li>
</ul>

<h3>When a place cannot be added</h3>
<table>
    <thead><tr><th>Message</th><th>Why</th><th>What to do</th></tr></thead>
    <tbody>
        <tr><td><em>This location is already in your list</em></td><td>A city within 5 km of a saved city, or a named or address place with the same name and region within 50 m of a saved one.</td><td>Give it a distinct Location Name (for example "Home" or "Work"); named places may sit close to each other.</td></tr>
        <tr><td><em>You can save at most 50 places</em></td><td>The list is full.</td><td>Remove a place first.</td></tr>
        <tr><td><em>Could not add this location</em></td><td>The place data was not usable (or saving failed).</td><td>Try another result.</td></tr>
    </tbody>
</table>

<h2>The sidebar</h2>
<p>Each row shows the condition icon, the name (or your Location Name), the region ("State, Country"), a rain hint, and the temperature with its unit in the place's own units (for example <strong>77°F</strong> beside a place in <strong>18°C</strong>). The rain hint is the first of: <em>Raining until 3:30 PM</em>, <em>Raining now</em>, <em>Rain in 25 min</em>, <em>Rain starting now</em>, <em>Rain at 4 PM</em>, <em>Rain tomorrow, 4 PM</em>, <em>Rain Friday, 4 PM</em>, <em>Rain expected</em>, <em>Showers possible</em>, <em>Dry for 48 h</em>; or <em>Loading…</em>, <em>Can't load forecast</em>, <em>Offline</em>, <em>No data yet</em>, <em>No rain data</em>. When a nearby station reports precipitation while the forecast says dry, the hint says so (for example <em>Light rain now</em>).</p>
<p>An orange pill marks a row whose forecast is <strong>Offline</strong>, <strong>Stale</strong> (the last refresh failed) or <strong>Updating…</strong>; offline and stale rows are dimmed. Hover over a row for the full place name.</p>
<p>A <strong>warning triangle</strong> after the name marks a place with an official alert in force. Its colour is the highest level among them (red, orange, yellow; light blue for minor, white for an unknown level), and a number beside it counts the alerts when there is more than one. VoiceOver reads the alerts with the row, for example "Alert: Tornado Warning (red)". See <a href="weather-alerts.html">Weather Alerts</a>.</p>

<h3>Selecting, reordering and removing</h3>
<ul>
    <li><strong>Select</strong> a row with a click or the arrow keys. The selection is remembered.</li>
    <li><strong>Reorder:</strong> drag a row onto another row; a blue line shows where it will go. Or use <strong>Move up</strong> / <strong>Move down</strong> in the row's <strong>…</strong> menu.</li>
    <li><strong>Remove:</strong> <strong>…</strong> › <strong>Remove</strong>. There is no confirmation and no undo; the place's cached forecast and its <a href="local-corrections.html">learned local corrections</a> are forgotten with it.</li>
</ul>

<h3>Naming a place</h3>
<p>Use <strong>…</strong> › <strong>Set Location Name</strong> for a preset (and <strong>Clear Custom Name</strong>), or <strong>…</strong> › <strong>Name / Edit Location…</strong> (also the <strong>Name Location</strong> / <strong>Edit Name</strong> button in the forecast header) for the <em>Name &amp; Address Details</em> sheet:</p>
<ul>
    <li><strong>Location Name</strong>: your name for the place, with the same presets.</li>
    <li><strong>Street Address / Locality Subtitle</strong>: the line shown under the name.</li>
    <li>The coordinates are shown for reference; they do not change. <strong>Save</strong> (or Return) keeps the forecast and the list position; <strong>Clear Name</strong> removes the custom name.</li>
</ul>
""",
    "forecast-page": """
<h1>Reading the Forecast</h1>
<p>Select a place in the sidebar to see its forecast. From top to bottom: the header, <strong>Now</strong>, <strong>Alerts</strong>, <strong>Rain</strong>, <strong>Air Quality</strong> and <strong>Clouds</strong> side by side, <strong>Next 48 hours</strong>, <strong>Next days</strong>, the footer, the credits, and (when a source failed) a <em>Not available right now</em> line. The background colour follows the current sky, day or night. All times are in the place's own time zone.</p>

<h2>Header</h2>
<p>The place name with its region (or your Location Name with its address line), and a <strong>Name Location</strong> / <strong>Edit Name</strong> button (see <a href="places.html">Naming a place</a>).</p>

<h2>Now</h2>
<ul>
    <li>The condition icon, the temperature (for example <strong>77°F</strong>) and the condition: Clear, Mostly clear, Partly cloudy, Mostly cloudy, Overcast, Fog, Drizzle, Light rain, Rain, Heavy rain, Showers, Thunderstorm, Snow or Sleet.</li>
    <li><strong>Feels like</strong>: wind chill when it is cold and windy, heat index when it is hot and humid, otherwise the temperature.</li>
    <li><strong>High · Low</strong> of today. When the forecast only covers the rest of today, it says so, for example <em>(from 2 PM)</em>. If the live temperature is already outside the forecast range, the range is widened to include it.</li>
    <li><strong>Humidity</strong>, in its own pill beside them.</li>
    <li><strong>Wind compass</strong>, on the right: the wind speed in the centre and, below the dial, the <strong>gusts</strong> (when they are reported meaningfully above the mean wind) and the direction the wind comes from, for example <em>from NNE 31°</em>. The dot on the ring marks where the wind comes from; the arrow points the way it blows. The direction is the speed-weighted average of the nearby stations' readings, or Open-Meteo's current conditions when no station reports one. When the wind is calm or its direction is unknown, the dial shows only the speed (or <em>Calm</em>) and no arrow. In a narrow window the dial is smaller and its caption shorter.</li>
</ul>
<div class="callout">
    <strong>Where "now" comes from</strong><br>
    When stations are near, the Now values are a blend of the live station readings (tested and weighted; see <a href="live-stations.html">Live Station Observations</a>) and a high-resolution model analysis for the exact spot. The closer and fresher the stations, the more they count: about 95% for a station next door, about 75% at 25 km, about 40% at 60 km. Without stations the model values are shown. The footer names the nearest station.
</div>

<h2>Alerts</h2>
<p>The official warnings in force for the place, one card each, highest level first; or one line saying there are none or why none can be shown. The card is also shown while the forecast is loading or could not be loaded; that page scrolls when the alerts do not fit. See <a href="weather-alerts.html">Weather Alerts</a>.</p>

<h2>Rain</h2>
<p>A headline and a detail line, then one or two charts.</p>
<ul>
    <li><strong>Headlines</strong> include <em>No rain expected for the next 48 hours</em>, <em>Raining now</em> (with <em>easing soon</em>, <em>easing around 4 PM</em> or <em>expected to continue for hours</em>), <em>Rain starting in 25 minutes</em>, <em>Rain expected tomorrow around 4 PM</em>, and <em>Showers possible … (40% chance)</em>.</li>
    <li><strong>Detail line:</strong> how heavy (Very light below 0.5 mm/h, Light below 2.5, Moderate below 7.6, Heavy above) and when it peaks, with the chance of rain, or <em>No steady rain in the forecast, just a chance.</em></li>
    <li><strong>Live:</strong> if the forecast says dry but a nearby station reports precipitation, the headline says so (for example <em>Light rain reported now</em>, with the station and its rate). If the 15-minute data shows rain starting within 90 minutes, the headline gives the minutes.</li>
    <li><strong>Charts:</strong> <em>Next 2 hours</em> (15-minute bars, when available) and <em>Next 24 hours</em> (hourly bars and a chance curve). See the <a href="rain-chart.html">Rain Graph &amp; Bars Guide</a>.</li>
</ul>

<h2>Air Quality</h2>
<p>The US Air Quality Index (AQI, 0–500) with its category, on a scale of six equal bands in the official EPA colours: <strong>Good</strong> (0–50, green), <strong>Moderate</strong> (51–100, yellow), <strong>Unhealthy for Sensitive Groups</strong> (101–150, orange), <strong>Unhealthy</strong> (151–200, red), <strong>Very Unhealthy</strong> (201–300, purple) and <strong>Hazardous</strong> (301–500, maroon). The marker always sits in the band of its category. Below the scale:</p>
<ul>
    <li><strong>A comparison with yesterday</strong>: the same source's value 24 hours earlier, for example <em>Air quality index is 44, similar to yesterday at this time (37).</em> Within 8 points it is <em>similar</em>; otherwise <em>better</em> (lower) or <em>worse</em> (higher). Without a value from yesterday the sentence gives the category instead (<em>which is good</em>).</li>
    <li><strong>Where the value comes from</strong>, in a smaller line.</li>
</ul>
<table>
    <thead><tr><th>Source</th><th>When</th><th>What you see</th></tr></thead>
    <tbody>
        <tr><td><strong>A monitor</strong> (US EPA AirNow)</td><td>Outside Europe, when an AirNow monitor within 45 km (28 mi) has reported in the last 3 hours. AirNow has monitors across the United States and Canada.</td><td>The latest hourly reading of the <strong>nearest</strong> such monitor, exactly as reported (the higher of its ozone and particle indices), never averaged with other monitors. <em>Measured at Pasadena, 8.7 mi away, at 2 PM. Preliminary data.</em> AirNow's data are preliminary: the agencies have not yet validated them, and they can change.</td></tr>
        <tr><td><strong>A forecast</strong> (CAMS, via Open-Meteo)</td><td>Everywhere else: all of Europe, most of the world, and wherever no monitor is near.</td><td>The air-quality forecast of the Copernicus Atmosphere Monitoring Service for the hour, on an 11 km grid in Europe and 45 km elsewhere. <em>CAMS model forecast for 10 PM, not a local measurement.</em> It adds PM2.5 and NO₂ (µg/m³), and in Europe the European AQI, which uses its own scale.</td></tr>
        <tr><td><strong>No data</strong></td><td>Before the first answer, when neither source answers, and offline.</td><td>A dash and <em>No data</em>, with <em>No air-quality reading for this place yet. It is checked again at every refresh.</em> (offline: <em>Air quality needs a network connection.</em>). If a later refresh cannot reach either source, the last reading is kept while it is less than 3 hours old.</td></tr>
    </tbody>
</table>
<p>Nothing on this card is estimated from the weather. The credits line names its source, as the data terms ask: the reporting agency and U.S. EPA AirNow, or CAMS via Open-Meteo. For health advice and official alerts, follow your local air-quality agency.</p>

<h2>Clouds</h2>
<p>The cloud cover now (for example <em>Cloud cover 40% · Partly cloudy</em>) with a gauge, and how it will change (<em>Partly cloudy now, clearing around 4 PM</em>, <em>Clear skies for the next 24 hours</em>). Bands: Clear below 12.5%, Mostly clear below 37.5%, Partly cloudy below 62.5%, Mostly cloudy below 87.5%, Overcast above. With live stations, high thin cloud counts less than low thick cloud (what you actually see), and the sentence names the observing station.</p>

<h2>Next 48 hours</h2>
<p>One card per hour, scrolling sideways: the hour (<strong>Now</strong> for the current one), icon, temperature, rain chance and cloud cover. Rain chances of 30% or more, and wet hours, are highlighted. Hover for feels-like, wind and the rain amount. Wet hours near freezing show snow or sleet icons. With live stations, the Now card shows the live values, and the next 6 hours ease from the observed temperature into the forecast.</p>

<h2>Next days</h2>
<p>Up to 10 days: <em>Today</em>, <em>Tomorrow</em>, then weekdays. Each row has the day's icon, its chance of rain, the low, a range bar and the high. The bars share one scale, so you can compare days at a glance; a white dot marks the current temperature on today's bar. Hover for the rain amount and cloud cover; a day only partly covered by the forecast says so.</p>

<h2>Footer, badges and credits</h2>
<ul>
    <li><em>Updated 5 min ago · Sources: …</em> lists the services that answered. With stations: <em>· Station: KMIA (3.2 mi) +4 nearby</em>, the nearest station and how many more were blended.</li>
    <li>A spinner shows while the place refreshes. <strong>Offline</strong>: no network, showing the last forecast. <strong>Stale</strong>: the last refresh failed (hover for the reason); the previous forecast is shown.</li>
    <li>The <strong>credits</strong> line links every forecast service that answered, every station network whose readings are shown, and the air-quality source, as their licences require. Networks whose licence asks for the date of the data (Météo-France, AEMET) show the time of their newest report, for example <em>Source: AEMET, data of 25 Oct 14:00 UTC</em>.</li>
    <li><em>Not available right now: …</em> names services that failed this time; the forecast is blended from the others.</li>
</ul>
<p>When learned local corrections are on, the temperatures on this page (hours, days, highs and lows) include them. See <a href="local-corrections.html">Learned Local Corrections</a>.</p>
""",
    "rain-chart": """
<h1>Rain Graph &amp; Bars Guide</h1>
<p>The <strong>Rain</strong> card shows up to two charts side by side: <strong>Next 2 hours</strong> (15-minute bars) when 15-minute data is available for the place, and <strong>Next 24 hours</strong> (hourly bars and a chance curve), always. Each chart's legend names its series.</p>

<div class="callout">
    <strong>Bars = rain rate (how hard), left axis</strong><br>
    The blue bars show the expected precipitation rate in <code>in/h</code> (Imperial) or <code>mm/h</code> (Metric). Read them against the <strong>left axis</strong>: the top label (<code>Rate · 0.1 in/h</code> or <code>Rate · 2.5 mm/h</code>), the middle line (half of it) and <code>0</code>. The scale starts at 0.1 in/h (2.5 mm/h) and doubles until the largest bar fits, so light rain still shows. On the 2-hour chart each bar is the 15-minute amount expressed as an hourly rate.
</div>

<div class="callout amber">
    <strong>Curve = rain chance, right axis</strong><br>
    On the 24-hour chart the amber curve shows the chance of measurable precipitation (at least 0.1 mm, about 0.004 in) in each hour, read against the <strong>right axis</strong> (<code>100%</code>, <code>50%</code>, <code>0%</code>).
</div>

<h2>Callouts and hover</h2>
<ul>
    <li><strong>Peak bars:</strong> the two highest bars carry their rate (for example <code>0.08 in/h</code>).</li>
    <li><strong>Peak chance:</strong> the highest point of the curve is labelled (for example <code>Peak 80%</code>).</li>
    <li><strong>Hover</strong> over any slot for a guide line and a readout such as <code>3 PM · Bar: 0.06 in/h · Chance: 70%</code>; slots without a time label read <code>+2h</code> or <code>+30m</code>.</li>
    <li>The time axis shows up to 5 labels, starting with <strong>Now</strong>. A chart without data says <em>No data</em>.</li>
    <li>VoiceOver reads a summary of each chart, for example <em>Highest chance: 70% at 3 PM</em>.</li>
</ul>

<h2>How heavy is it?</h2>
<p>These are the bands the Rain card's sentences use.</p>
<table>
    <thead>
        <tr><th>Words used</th><th>Metric rate</th><th>Imperial rate</th><th>What it is like</th></tr>
    </thead>
    <tbody>
        <tr><td><strong>Very light</strong></td><td>below 0.5 mm/h</td><td>below 0.02 in/h</td><td>Drizzle or scattered drops; surfaces barely wet.</td></tr>
        <tr><td><strong>Light</strong></td><td>0.5 – 2.5 mm/h</td><td>0.02 – 0.10 in/h</td><td>Steady light rain; puddles form slowly.</td></tr>
        <tr><td><strong>Moderate</strong></td><td>2.5 – 7.6 mm/h</td><td>0.10 – 0.30 in/h</td><td>Puddles form quickly; spray off roofs and roads.</td></tr>
        <tr><td><strong>Heavy</strong></td><td>7.6 mm/h and more</td><td>0.30 in/h and more</td><td>Sheets of rain, fast runoff, poor visibility.</td></tr>
    </tbody>
</table>

<h2>Where the 2-hour chart comes from</h2>
<table>
    <thead><tr><th>Where</th><th>15-minute model</th></tr></thead>
    <tbody>
        <tr><td>Contiguous United States, and southern Canada</td><td>NOAA HRRR (3 km)</td></tr>
        <tr><td>Rest of Canada</td><td>Open-Meteo's best 15-minute model for the spot</td></tr>
        <tr><td>UK &amp; Ireland</td><td>UK Met Office (2 km)</td></tr>
        <tr><td>Netherlands, Belgium, Luxembourg</td><td>KNMI HARMONIE-AROME (2 km)</td></tr>
        <tr><td>Germany &amp; Central Europe</td><td>DWD ICON-D2 (2 km)</td></tr>
        <tr><td>Rest of Europe and the Nordic countries, south of 65°N and between 11°W and 25°E</td><td>Open-Meteo's best 15-minute model for the spot</td></tr>
        <tr><td>Alaska, Hawaii and the rest of the world</td><td>None: only the 24-hour chart is shown</td></tr>
    </tbody>
</table>
<p>The quarters are rescaled so that each hour's four quarters add up to the blended hourly amount, so the two charts never disagree about how much falls in an hour.</p>
""",
    "units-refresh": """
<h1>Units, Refreshing &amp; Offline</h1>

<h2>Units</h2>
<p>Every place has its own units, <strong>Imperial</strong> (°F, mph, inches) or <strong>Metric</strong> (°C, km/h, mm), saved with the place. The sidebar shows each place's temperature with its unit, and the forecast page uses the units of the place it shows.</p>
<ul>
    <li><strong>When you add a place</strong>, the units menu of the Add a city window (<strong>Units for</strong> and the place) sets them, preselected from the place's country (see <a href="places.html">Adding a place</a>).</li>
    <li><strong>To switch a saved place</strong>, select it and click the unit button in the toolbar (it shows the selected place's unit, <strong>°F</strong> or <strong>°C</strong>) or choose View › <strong>Switch Selected Place to Celsius</strong> (or <strong>to Fahrenheit</strong>; <kbd>⌘U</kbd>), the title the button's tooltip shows too. Only the selected place changes, at once; its forecast is kept, not fetched again.</li>
    <li><strong>With no place selected</strong> (for example with an empty list), the button and <kbd>⌘U</kbd>, then titled <strong>Set Default Units to Celsius</strong> (or <strong>to Fahrenheit</strong>), switch the default units for new places instead.</li>
    <li><strong>Settings › General › Default Units for New Places</strong> is used for a new place whose country is not known. Places you have already added keep their own units.</li>
    <li><strong>Settings › Stations</strong> shows its values in the selected place's units (the default units when none is selected).</li>
</ul>
<p>Temperatures, wind, rain amounts and rates, the rain chart scale, and station and monitor distances (mi or km) change; percentages and the air quality index do not. Times are shown in 12-hour form in each place's time zone.</p>

<h2>When forecasts refresh</h2>
<ul>
    <li>Forecasts are fetched only while the window is visible (on screen, not minimised or hidden) and the Mac is online.</li>
    <li>When the window appears, comes back to the front, or the network returns, places whose forecast is at least 2 minutes old are refreshed.</li>
    <li>Every 10 minutes, places whose forecast is at least 9 minutes old are refreshed. At most 3 places are fetched at once, the selected place first.</li>
    <li><kbd>⌘R</kbd> (View › Refresh, or the refresh button) refreshes the selected place now. It does nothing while that place is loading, within 10 seconds of its last refresh, for 60 seconds after a service asked for fewer requests, or while offline.</li>
    <li>Changing a source switch or a weight re-fetches every place once.</li>
    <li>A refresh waits up to 30 seconds for the services; one that has not answered by then is listed as <em>Not available right now</em>. Network errors are retried twice.</li>
    <li>Official alerts are checked after each completed forecast refresh of a place, never on their own timer and never while offline. How often each alert source is actually asked is on <a href="weather-alerts.html">Weather Alerts</a>.</li>
</ul>

<h2>Live stations and air quality</h2>
<ul>
    <li>Live station readings and air quality are fetched with each forecast refresh of a place, and again for every place when a station setting (a key, a network switch) changes.</li>
    <li>Answers are kept for a short time and shared by places close together: 2–10 minutes for most station networks, 15 minutes for AEMET, an hour per Met Office station (its free plan allows 360 calls a day); station lists are kept for a day (the Met Office's list of nearest stations for a week). Air quality: monitors 10 minutes, yesterday's monitor readings an hour, the CAMS forecast 15 minutes.</li>
    <li>A network that cannot be reached contributes its readings of the last 90 minutes.</li>
</ul>

<h2>Offline</h2>
<p>When the Mac loses its connection, rows show <strong>Offline</strong>, the forecast page shows the <strong>Offline</strong> badge and the last forecast (without live station values or air quality), and refreshing is off. Alerts are not checked, and alert answers are not kept between launches. A place with an alert answer (alerts or <em>No active alerts</em>) reads <em>Alerts could not be checked recently.</em> once that answer is older than its source's window; a place with no answer yet keeps <em>Checking for alerts…</em>, one whose last check failed keeps <em>Alerts could not be checked right now.</em>, and one no source covers keeps <em>Alerts not available</em>. As soon as the connection is back, places are refreshed. At launch, each place shows its last forecast from the cache with its age until the new one arrives.</p>

<h2>Saving and quitting</h2>
<p>Changes are saved a few seconds after you make them. Quitting (or closing the window, which quits) waits up to 5 seconds for pending saves.</p>
""",
    "shortcuts": """
<h1>Keyboard Shortcuts &amp; Menus</h1>
<h2>Shortcuts</h2>
<table>
    <thead><tr><th>Shortcut</th><th>Command</th></tr></thead>
    <tbody>
        <tr><td><kbd>⌘N</kbd></td><td>File › Add a City… (opens the <strong>Add a city</strong> window)</td></tr>
        <tr><td><kbd>⌘R</kbd></td><td>View › Refresh (the selected place)</td></tr>
        <tr><td><kbd>⌘U</kbd></td><td>View › Switch Selected Place to Celsius / Fahrenheit: switches the selected place between °F and °C (with no place selected, Set Default Units to Celsius / Fahrenheit switches the default units for new places)</td></tr>
        <tr><td><kbd>⌃⌘S</kbd></td><td>View › Show/Hide Sidebar</td></tr>
        <tr><td><kbd>⌘,</kbd></td><td>Neginato Mezora › Settings… (opens on the Sources tab)</td></tr>
        <tr><td><kbd>⌘?</kbd> (<kbd>⇧⌘/</kbd>)</td><td>Help › Neginato Mezora Help</td></tr>
        <tr><td><kbd>⌘Q</kbd></td><td>Quit (pending changes are saved first)</td></tr>
        <tr><td><kbd>↑</kbd> <kbd>↓</kbd></td><td>Select the previous or next place in the sidebar</td></tr>
        <tr><td><kbd>Esc</kbd></td><td>Close the Add a city window</td></tr>
        <tr><td><kbd>Return</kbd> / <kbd>Space</kbd></td><td>In the Add a city window: add the highlighted result</td></tr>
    </tbody>
</table>

<h2>Menus</h2>
<ul>
    <li><strong>Neginato Mezora:</strong> About Neginato Mezora; Settings… (<kbd>⌘,</kbd>, Sources tab); Data Sources &amp; Weights… (the Weights tab); Stations &amp; Keys… (the Stations tab); Quit.</li>
    <li><strong>File:</strong> Add a City… (<kbd>⌘N</kbd>).</li>
    <li><strong>View:</strong> Refresh (<kbd>⌘R</kbd>); Switch Selected Place to Celsius or Fahrenheit (<kbd>⌘U</kbd>; with no place selected, Set Default Units to Celsius or Fahrenheit); Show/Hide Sidebar.</li>
    <li><strong>Help:</strong> Neginato Mezora Help (<kbd>⌘?</kbd>), then direct links to Reading the Forecast, the Rain Graph &amp; Bars Guide, Data Sources &amp; Blend Weights, Station Settings, Free Keys for More Stations, Live Station Observations, Learned Local Corrections, Forecast Algorithms &amp; Citations, and Troubleshooting &amp; FAQ.</li>
</ul>

<h2>Toolbar</h2>
<table>
    <thead><tr><th>Button</th><th>What it does</th></tr></thead>
    <tbody>
        <tr><td><strong>+</strong></td><td>Add a city (<kbd>⌘N</kbd>).</td></tr>
        <tr><td>Refresh</td><td>Refresh this place (<kbd>⌘R</kbd>); dimmed while it loads or when offline.</td></tr>
        <tr><td><strong>°F</strong> / <strong>°C</strong></td><td>Shows the selected place's unit; click to switch that place (with no place selected, the default units for new places). Its tooltip is the <kbd>⌘U</kbd> title: <em>Switch Selected Place to Celsius</em> (or <em>to Fahrenheit</em>), or with no place selected <em>Set Default Units to Celsius</em> (or <em>to Fahrenheit</em>).</td></tr>
        <tr><td>Gear</td><td>Settings (<kbd>⌘,</kbd>).</td></tr>
    </tbody>
</table>
<p>Each sidebar row's <strong>…</strong> button holds Name / Edit Location…, Set Location Name, Move up, Move down and Remove (also available to VoiceOver as row actions). Rows have no right-click menu.</p>
""",
    "sources-weights": """
<h1>Settings: Data Sources &amp; Weights</h1>
<p>Open Settings with <kbd>⌘,</kbd> (it opens on the <strong>Sources</strong> tab), the gear button in the toolbar, or Neginato Mezora › Settings…. <strong>Neginato Mezora › Data Sources &amp; Weights…</strong> opens the <strong>Weights</strong> tab directly.</p>

<h2>The Sources tab</h2>
<p>One row per forecast service. Each row has a status dot and line, an on/off switch, a <strong>Source weight multiplier</strong>, and links to the service's credit and licence.</p>
<table>
    <thead><tr><th>Service</th><th>Models it supplies</th><th>Where</th><th>Licence</th></tr></thead>
    <tbody>
        <tr><td><strong>Open-Meteo</strong></td><td>ECMWF IFS, DWD ICON, NOAA GFS, ECCC GEM, UK Met Office, Météo-France ARPEGE/AROME, KNMI HARMONIE-AROME, and in the US and southern Canada NOAA HRRR and the National Blend of Models (NBM); the 15-minute rain; also current conditions, air quality and elevations</td><td>Worldwide (each model where it runs)</td><td>CC BY 4.0</td></tr>
        <tr><td><strong>National Weather Service</strong></td><td>The forecasters' 2.5 km grid (NDFD)</td><td>United States and territories</td><td>US public domain</td></tr>
        <tr><td><strong>MET Norway</strong></td><td>Locationforecast 2.0 (MEPS 2.5 km in the Nordic area, ECMWF elsewhere)</td><td>Worldwide</td><td>NLOD 2.0 / CC BY 4.0</td></tr>
        <tr><td><strong>Bright Sky (DWD)</strong></td><td>DWD MOSMIX station forecasts</td><td>Germany and neighbouring countries</td><td>CC BY 4.0 (DWD)</td></tr>
        <tr><td><strong>Environment Canada</strong></td><td>MSC GeoMet: HRDPS / RDPS and the official city forecast of the nearest city (within 75 km)</td><td>Canada</td><td>Data Server End-use Licence of Environment and Climate Change Canada</td></tr>
    </tbody>
</table>

<h3>Status lines</h3>
<table>
    <thead><tr><th>Dot</th><th>Status</th><th>Meaning</th></tr></thead>
    <tbody>
        <tr><td>green</td><td><em>Used for this place (3 forecast models)</em></td><td>The service answered for the selected place, with that many models.</td></tr>
        <tr><td>orange</td><td><em>Could not load: network error / timed out / server error / rate limited / unreadable answer / no data / invalid request / not available</em></td><td>The last fetch for the selected place failed; the forecast is blended from the other services.</td></tr>
        <tr><td>grey</td><td><em>Not used for this place</em></td><td>The service does not cover the selected place (for example the NWS outside the US).</td></tr>
        <tr><td>grey</td><td><em>Turned off</em></td><td>You switched it off. It is not fetched for any place.</td></tr>
    </tbody>
</table>

<h3>Switches and source multipliers</h3>
<ul>
    <li>The <strong>switch</strong> turns a service off for every place. Every place is fetched again, without it.</li>
    <li>The <strong>Source weight multiplier</strong> (0.10× to 3.00×, steps of 0.05, default 1.00×) scales the weight of all of that service's models. <strong>1.0×</strong> resets one row; <strong>Reset Source Weights</strong> (in the section header, shown when any is changed) resets them all.</li>
    <li>The note under the list is meant literally: the weights are rules of thumb, not statistics measured from past accuracy, so the app claims no accuracy figure.</li>
</ul>
<p>Station networks are not in this tab: they have their own switches in <a href="stations-settings.html">Settings › Stations</a>. Nor are the official alert sources: they have no switch and need no key; they and their credits are on <a href="weather-alerts.html">Weather Alerts</a>.</p>

<h2>The Weights tab</h2>
<p>Every forecast hour is a <strong>weighted median</strong> of the models that cover it (see <a href="algorithms.html">Algorithms</a>). A model's weight depends on the <strong>regional profile</strong> of the place, the <strong>variable</strong>, and how far ahead the hour is, in four <strong>horizon bands</strong>: <code>H0</code> 0–3 hours, <code>H1</code> 3–18 hours, <code>H2</code> 18–72 hours, <code>H3</code> beyond 72 hours.</p>
<ul>
    <li><strong>Inspect Regional Profile</strong> shows the weights of one profile. It starts on the profile of the place selected in the main window, and follows it when you select another place; it only changes what you see, not which profile a place uses.</li>
    <li><strong>Inspect Baseline Variable Group</strong>: Temperature &amp; Feels Like, Wind &amp; Gusts, Cloud Cover, Relative Humidity, Precipitation Amount, Precipitation Chance.</li>
    <li>Each model row shows its name and id, where it runs, its resolution, the four band weights of the chosen profile and variable, the worldwide baseline, and a <strong>Model multiplier</strong> (0.00× to 3.00×; 0 removes the model from the blend). <strong>1.0×</strong> resets one model; <strong>Reset All to 1.00×</strong> resets every multiplier.</li>
    <li>The weight used is <code>profile weight × source multiplier × model multiplier</code>. Multipliers apply in every region. Changing one re-fetches every place.</li>
</ul>

<h2>Regional profiles</h2>
<p>The profile follows the place's country; places without a country code use their coordinates. These tables are produced from the app's own weight code.</p>
<!-- WEIGHT_TABLES -->
<p>Precipitation chance is a weighted mean of the models that report a chance, combined with the share of models that forecast measurable rain when few report one. Models that only run in North America weigh 0 elsewhere: NWS outside the US, HRRR and NBM outside the US and southern Canada; HRRR stops after 48 hours.</p>
""",
    "stations-settings": """
<h1>Settings: Stations</h1>
<p>Open Settings (<kbd>⌘,</kbd>) and choose <strong>Stations</strong>, or use Neginato Mezora › <strong>Stations &amp; Keys…</strong>. The tab has four sections; the <strong>Help</strong> links in their headers open the matching help pages.</p>

<h2>1. Learned Local Corrections</h2>
<ul>
    <li><strong>Correct forecasts with what nearby stations measure</strong> turns the corrections on or off for every place. When off, the forecasts show the plain model blend; learning continues, so turning it back on needs no new learning.</li>
    <li>One row per place, with its status, for example <em>7 of 24 hours learned from 19 readings, last 12 min ago</em>, or <em>Nothing learned yet: this needs station readings within about 25 km that are less than 45 minutes old.</em> A place without updates for over 30 days adds <em>fading: no new readings for N days</em>.</li>
    <li><strong>Now</strong>: the correction applied at this moment (for example <code>−1.2 °F</code>: the forecast is lowered by 1.2 °F).</li>
    <li><strong>The bars</strong>: one per local hour of today. Up (orange) means the forecast is raised at that hour, down (blue) lowered. A small dot marks an hour with readings but not yet enough to correct it. The current hour is highlighted; hover over a bar for its value and number of readings.</li>
    <li><strong>Reset</strong> forgets one place's learning; <strong>Reset All…</strong> forgets every place's (after a confirmation).</li>
</ul>
<p>How the learning works: <a href="local-corrections.html">Learned Local Corrections</a>.</p>

<h2>2. Networks That Need Your Free Key</h2>
<p>Met Office (UK), KNMI (Netherlands), MET Norway Frost (Norway), Météo-France (France) and AEMET (Spain). For each one:</p>
<ul>
    <li>Paste your key into the field and click <strong>Save</strong> (or press Return). The key is stored in your login Keychain, not in a file. Once saved, the row shows <em>… saved in your Keychain</em> with <strong>Replace…</strong> and <strong>Remove</strong>. For AEMET and Météo-France keys, which carry an expiry date, the row shows it, and warns when it is near or past.</li>
    <li><strong>How to get a free …</strong> opens the steps for that service, with a button to its sign-up page. The full walk-through, with limits and troubleshooting, is in <a href="station-keys.html">Free Keys for More Stations</a>.</li>
    <li>The switch turns the network off without removing the key.</li>
    <li>The status line and dot tell you whether the key works (see below).</li>
</ul>

<h2>3. Networks Used Without a Key</h2>
<p>Airport reports (worldwide), NWS airport stations and the Iowa Environmental Mesonet (US), Environment Canada stations, Deutscher Wetterdienst, DMI, FMI, SMHI, GeoSphere Austria and MeteoSwiss. Each has a switch: a network turned off is neither fetched nor used. Each row links the network's credit.</p>

<h3>Status lines and dots</h3>
<table>
    <thead><tr><th>Dot</th><th>Status</th><th>Meaning</th></tr></thead>
    <tbody>
        <tr><td>green</td><td><em>Working: 12 reports within 95 km near Leeds (3 min ago)</em></td><td>The latest fetch worked (for the place named).</td></tr>
        <tr><td>red</td><td><em>The service refused the key (HTTP 401…)</em></td><td>The key is wrong, incomplete, expired, or not yet activated. Paste it again or create a new one.</td></tr>
        <tr><td>orange</td><td><em>The service's limit for this key was reached</em></td><td>Too many requests for the free plan; the app tries again at the next refresh.</td></tr>
        <tr><td>orange</td><td><em>Could not reach the service</em> / <em>answered with an error</em></td><td>A network or server problem. The network's readings of the last 90 minutes are used meanwhile.</td></tr>
        <tr><td>grey</td><td><em>Needs your free API key</em>, <em>Key saved. It is tried on the next refresh…</em>, <em>Turned off</em>, <em>not needed by your places yet</em></td><td>Nothing fetched yet (no place in its area, or no key).</td></tr>
    </tbody>
</table>

<h2>4. Stations Near the Selected Place</h2>
<p>The stations within 60 km of the place selected in the main window, nearest first (12 shown; <strong>Show All</strong> for the rest). Each row gives the station's name and code, network, distance, the age of its latest report, its <strong>weight</strong> (0–100%) and why:</p>
<table>
    <thead><tr><th>State</th><th>Meaning</th></tr></thead>
    <tbody>
        <tr><td><strong>Good</strong> (green)</td><td>Agrees with its neighbours within 1.5 °C (2.7 °F): full weight.</td></tr>
        <tr><td><strong>On probation (N of 6 tests)</strong> (blue)</td><td>New or returning: weight rises from 60% to 100% over its first 6 tests.</td></tr>
        <tr><td><strong>Reduced weight (off by X)</strong> (yellow)</td><td>Its typical error is above 1.5 °C; the larger the error, the lower the weight.</td></tr>
        <tr><td><strong>Not used: off by X</strong> (red)</td><td>Error of 8 °C (14 °F) or more. It keeps being tested and can recover.</td></tr>
        <tr><td><strong>Not used: reading stuck</strong> (red)</td><td>The reading has not changed for 8 hours (a failed sensor). Used again as soon as it changes.</td></tr>
    </tbody>
</table>
<p><strong>Forget All Stations…</strong> clears the station list and every track record (after a confirmation). The stations are found again at the next refresh and start over on probation; learned local corrections are kept.</p>
<p>How stations are tested and blended: <a href="live-stations.html">Live Station Observations</a>.</p>
""",
    "station-keys": """
<h1>Free Keys for More Stations</h1>
<p>Five national weather services publish their station readings only to registered users. Registration is free, and with your key the app reads their stations like any other network: tested against their neighbours and blended into "now" and into the <a href="local-corrections.html">learned local corrections</a>. A key only matters if you have places in (or near) that country.</p>
<table>
    <thead><tr><th>Network</th><th>Stations</th><th>Updates</th><th>What you need</th><th>Expires</th></tr></thead>
    <tbody>
        <tr><td><a href="#metoffice">Met Office</a> (UK)</td><td>About 150</td><td>Hourly</td><td>A Weather DataHub API key, subscribed to Land Observations</td><td>No (the free plan allows 360 calls a day)</td></tr>
        <tr><td><a href="#knmi">KNMI</a> (Netherlands)</td><td>About 50 with temperature</td><td>10 minutes</td><td>An <strong>EDR API</strong> key</td><td>No</td></tr>
        <tr><td><a href="#frost">MET Norway Frost</a> (Norway)</td><td>MET Norway's stations, plus partners such as the road authority</td><td>10 minutes to hourly</td><td>A Frost client ID</td><td>No</td></tr>
        <tr><td><a href="#meteofrance">Météo-France</a> (France)</td><td>About 2,000</td><td>6 minutes</td><td>An API key generated <strong>after</strong> subscribing to Package Observations v2</td><td>Up to 3 years (you choose); the subscription is renewed every 2 years</td></tr>
        <tr><td><a href="#aemet">AEMET</a> (Spain)</td><td>About 830</td><td>Hourly</td><td>An AEMET OpenData API key</td><td><strong>After 3 months</strong></td></tr>
    </tbody>
</table>

<h2>Adding a key</h2>
<ol>
    <li>Get the key with the steps for its service below (each service's steps are also in Settings, under <strong>How to get a free …</strong>).</li>
    <li>Open Settings › <strong>Stations</strong> (or Neginato Mezora › <strong>Stations &amp; Keys…</strong>) and find the network under <em>Networks That Need Your Free Key</em>.</li>
    <li>Paste the key into the field and click <strong>Save</strong>. Spaces and line breaks at the ends are removed.</li>
    <li>The next refresh uses it, and the status line shows the result: <em>Working: …</em> (green), or why not (see <a href="#trouble">When a key does not work</a>).</li>
</ol>
<p>Keys are stored in your <strong>login Keychain</strong> as "Neginato Mezora: <em>network</em> key", never in a file, and each is sent only to its own service, over HTTPS. <strong>Replace…</strong> enters a new key; <strong>Remove</strong> deletes it from the Keychain. The network's switch turns it off and keeps the key.</p>

<h2 id="metoffice">Met Office (United Kingdom)</h2>
<ol>
    <li>Open the <a href="https://datahub.metoffice.gov.uk/">Met Office Weather DataHub</a> and choose <strong>Login/Register</strong>. Register with your e-mail address and confirm it.</li>
    <li>In the profile menu, choose <strong>My subscriptions › Subscribe</strong>, pick the <strong>Land Observations</strong> product, select its free plan and click <strong>Subscribe</strong>.</li>
    <li>Copy the <strong>API key</strong> that is shown. It is shown only once; if you lose it, use <strong>Manage › Reset Credentials</strong> to get a new one.</li>
    <li>Paste the key in Settings › Stations › Met Office and click Save.</li>
</ol>
<ul>
    <li><strong>You get:</strong> hourly reports of about 150 UK land stations: temperature, humidity, wind (speed and direction) and gusts, and the Met Office weather type (which also gives the condition and cloud). The service names stations by area, so a station shows as, for example, "Leeds".</li>
    <li><strong>Limits:</strong> the free plan allows <strong>360 calls a day</strong> (reset at 00:00 UTC). The app reads at most the 3 nearest stations of a place, each at most once an hour, and looks up which stations are nearest once a week; places close together share stations. A handful of UK places far apart fit in the limit; with more, the limit can be reached late in the day (orange status), and the stations return after midnight UTC.</li>
    <li><strong>Credit:</strong> "Powered by Met Office data", as the DataHub licence requires.</li>
    <li>The old Met Office DataPoint service was retired on 1 December 2025. The Met Office also publishes keyless open data on AWS, but it arrives 1–2 hours late, has no gusts, and is licensed CC BY-SA, so the app uses the DataHub instead.</li>
</ul>

<h2 id="knmi">KNMI (Netherlands)</h2>
<ol>
    <li>Register at the <a href="https://developer.dataplatform.knmi.nl/register/">KNMI Developer Portal</a> with an e-mail address that will keep working, and confirm it.</li>
    <li>Log in, open the <strong>API Catalog</strong>, and on the <strong>EDR API</strong> card click <strong>Request an API key</strong>. A key for the Open Data API does not work here.</li>
    <li>Copy the key while it is displayed (it starts with <code>eyJ</code>). The catalog later shows only a short hash, which is not the key.</li>
    <li>Paste the key in Settings › Stations › KNMI and click Save.</li>
</ol>
<ul>
    <li><strong>You get:</strong> 10-minute reports of KNMI's automatic stations, about 50 of which measure temperature: temperature, humidity, dew point, wind (speed and direction) and gusts, rain, cloud cover and present weather.</li>
    <li><strong>Limits:</strong> free, also for commercial use, and the key does not expire. 1,000 requests an hour; the app makes about 7 an hour per area.</li>
    <li><strong>Credit:</strong> "Source: KNMI", linked to the dataset (CC BY 4.0). KNMI asks apps to make clear that they changed the data; the credits line says the station data are quality-checked and blended.</li>
</ul>

<h2 id="frost">MET Norway Frost (Norway)</h2>
<ol>
    <li>Open the <a href="https://frost.met.no/auth/requestCredentials.html">Frost "Request credentials" page</a> and enter your e-mail address.</li>
    <li>The next page shows a <strong>client ID</strong> and a <strong>client secret</strong>. Only the client ID is needed; keep both safe.</li>
    <li>Paste the client ID in Settings › Stations › MET Norway (Frost) and click Save. Do not paste the secret.</li>
</ol>
<ul>
    <li><strong>You get:</strong> the latest reports of MET Norway's stations and of partner stations (for example the Norwegian road authority): temperature, humidity, dew point, wind (speed and direction) and gusts, and rain. MET Norway's own stations count fully; partner stations count 70%, and their wind 40%, because their siting varies.</li>
    <li><strong>Limits:</strong> free, with no fixed quota; MET Norway asks for no more than about one request a second on average. The app makes at most 2 requests per place every 5 minutes, and keeps the station list for a day.</li>
    <li><strong>Credit:</strong> "Data from The Norwegian Meteorological Institute" (NLOD 2.0 and CC BY 4.0).</li>
</ul>

<h2 id="meteofrance">Météo-France (France)</h2>
<ol>
    <li>On the <a href="https://portail-api.meteofrance.fr/web/en/">Météo-France API portal</a>, choose <strong>Sign in › Create account</strong>. Pick a user name (not your e-mail address), confirm the e-mail you receive, then sign in with the user name.</li>
    <li>Open the <strong>Package Observations</strong> API (DonneesPubliquesPaquetObservation), <strong>version 2</strong>, and click <strong>Subscribe to the API for free</strong>.</li>
    <li><strong>Only after subscribing:</strong> <strong>My APIs › Generate Token</strong>, choose <strong>API Key</strong>, and enter a validity in seconds (up to 3 years: <code>94608000</code>). A key generated before subscribing does not work.</li>
    <li>Copy the key, paste it in Settings › Stations › Météo-France and click Save. The row shows the key's expiry date.</li>
</ol>
<ul>
    <li><strong>You get:</strong> 6-minute reports of about 2,000 stations across France: temperature, humidity, dew point, wind (speed and direction) and gusts, and rain. The main network counts fully; the extended network (partner and secondary stations) 85%, and its wind 60%. These reports have no cloud cover or present weather.</li>
    <li><strong>Limits:</strong> free; 100 requests a minute. The app reads at most one 6-minute package of all of France every 6 minutes (the newest one at least 10 minutes old, so that it is complete), plus the station list once a day.</li>
    <li><strong>Renewals:</strong> the key expires on the date you chose (the app shows it); the <strong>subscription</strong> must be renewed every 2 years under <strong>My APIs › Renew</strong>.</li>
    <li><strong>Credit:</strong> "Source: Météo-France" with the date of the data (Licence Ouverte / Etalab 2.0 asks for both), for example <em>Source: Météo-France, data of 25 Oct 14:06 UTC</em>.</li>
</ul>

<h2 id="aemet">AEMET (Spain)</h2>
<ol>
    <li>Open <a href="https://opendata.aemet.es/centrodedescargas/altaUsuario">AEMET OpenData's API key request page</a>, enter your e-mail address and tick <strong>No soy un robot</strong> (I am not a robot).</li>
    <li>Within 5 days, click the link in the e-mail <em>Petición generación API Key servicio Aemet OpenData</em>.</li>
    <li>A second e-mail, <em>Alta en el servicio Aemet OpenData</em>, contains the key. Copy all of it: it is long, and the first or last character is easily missed.</li>
    <li>Paste the key in Settings › Stations › AEMET and click Save. The row shows when it expires.</li>
</ol>
<ul>
    <li><strong>You get:</strong> hourly reports of about 830 automatic stations across Spain (including the Balearic and Canary Islands): temperature, humidity, dew point, wind (speed and direction) and gusts, and rain. AEMET publishes each hour's reports about half an hour after the hour.</li>
    <li><strong>Limits:</strong> free; 40 requests a minute. The app reads all of Spain with at most 2 requests every 15 minutes.</li>
    <li><strong>Every 3 months:</strong> AEMET keys expire 3 months after they are issued, and there is no limit on renewals. Request a new key the same way and use <strong>Replace…</strong>. Older keys issued without an expiry date are being phased out: since 15 October 2026 AEMET refuses them more and more often, until they stop working altogether.</li>
    <li><strong>Credit:</strong> "Source: AEMET" with the date of the data (AEMET's legal notice asks for both), for example <em>Source: AEMET, data of 25 Oct 14:00 UTC</em>.</li>
</ul>

<h2 id="trouble">When a key does not work</h2>
<table>
    <thead><tr><th>Status</th><th>Likely cause</th><th>What to do</th></tr></thead>
    <tbody>
        <tr><td><em>The service refused the key</em> (red)</td><td>A character is missing or extra; the key is for another product; it expired; or the service has not activated it yet.</td><td>Paste it again with Replace…. Then check the service's specific cause below.</td></tr>
        <tr><td>Met Office: refused</td><td>The account is not subscribed to <strong>Land Observations</strong>, or the credentials were reset.</td><td>Subscribe to Land Observations (free plan); after a reset, paste the new key.</td></tr>
        <tr><td>KNMI: refused</td><td>The key is for the Open Data API (or is the anonymous public key); only an EDR API key works.</td><td>Request a key on the EDR API card.</td></tr>
        <tr><td>Frost: refused</td><td>The client secret was pasted instead of the client ID.</td><td>Paste the client ID (it looks like <code>xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx</code>).</td></tr>
        <tr><td>Météo-France: refused</td><td>The key was generated before subscribing to Package Observations v2, it expired, or the subscription lapsed.</td><td>Subscribe (or renew), then generate a new key and Replace.</td></tr>
        <tr><td>AEMET: refused or expired</td><td>The key is older than 3 months, or was issued without an expiry date.</td><td>Request a new key and Replace.</td></tr>
        <tr><td><em>The service's limit for this key was reached</em> (orange)</td><td>The free plan's limit (usually the Met Office's 360 calls a day, with many UK places).</td><td>Nothing: the app tries again at the next refresh; the Met Office count resets at 00:00 UTC.</td></tr>
        <tr><td><em>Could not reach the service</em> / <em>answered with an error</em> (orange)</td><td>A network problem or a service outage.</td><td>Nothing: the app keeps the network's readings of the last 90 minutes and tries again.</td></tr>
        <tr><td><em>not needed by your places yet</em> (grey)</td><td>None of your places is in the network's area.</td><td>Nothing: the key is used as soon as a place there is refreshed.</td></tr>
    </tbody>
</table>
<p>The services' own terms apply to your key. The app sends each service only what it needs (your key and the area or stations around your places; see <a href="privacy.html">Privacy, Data &amp; Storage</a>).</p>
""",
    "local-corrections": """
<h1>Learned Local Corrections</h1>
<p>Forecast models describe the weather on a grid. They miss what makes your spot different: the valley that runs 3 °C colder than the models on clear nights, the city centre that stays warmer, the lake shore, the hillside. These errors are not random: they come back at the same time of day, day after day. Neginato Mezora learns them for each place from the nearby stations and corrects the forecast.</p>

<h2>What is learned</h2>
<ul>
    <li><strong>When:</strong> at each refresh, if the station readings around the place are close and fresh enough to trust (their weighted distance within about 25 km and age within 45 minutes; see <a href="live-stations.html">Live Station Observations</a>).</li>
    <li><strong>What:</strong> the difference between the measured temperature and what the models said for that moment, before any correction.</li>
    <li><strong>By hour of day:</strong> differences are kept separately for each of the 24 hours of the (solar) day, because a place that is too warm at noon may be too cold at dawn. At most one reading per hour of day is taken every 20 minutes.</li>
    <li><strong>Averaging:</strong> the first readings of an hour are averaged equally; later ones update a running average that remembers about the last two weeks, so the correction follows the seasons.</li>
    <li><strong>Plausibility:</strong> a difference above 10 °C (18 °F) is treated as a bad reading and not learned.</li>
</ul>

<h2>How it is applied</h2>
<ul>
    <li>Every forecast hour's temperature and feels-like are shifted by the correction of its hour of day; the daily highs and lows are recomputed from the shifted hours. So the correction reaches the whole forecast, not just "now".</li>
    <li>An hour of day is corrected once it has about <strong>3 readings</strong> (neighbouring hours count half), at half strength, and at <strong>full strength from 6</strong>. Because one hour of day can be learned only once per day for about 20 minutes, expect the first corrections after a few days of normal use.</li>
    <li>Corrections are smoothed with the neighbouring hours and capped at <strong>±4 °C (±7 °F)</strong>.</li>
    <li>If a place gets no new readings for more than <strong>30 days</strong> (for example you stopped using the app over the summer), its corrections fade out gradually (to about a third after another 30 days), because the season has changed. New readings bring them back to full strength.</li>
</ul>

<h2>Seeing and controlling it</h2>
<p>Settings › <a href="stations-settings.html">Stations</a> › Learned Local Corrections shows, for every place, how much has been learned, the correction now, and a bar for every hour of today. From there you can turn the corrections off for all places, or reset one place or all of them.</p>

<h2>Good to know</h2>
<ul>
    <li><strong>Per Mac:</strong> the learning is stored on this Mac (<code>local-bias.json</code>, see <a href="privacy.html">Privacy, Data &amp; Storage</a>) and survives restarts and updates. Time with the app closed pauses it; it does not erase it.</li>
    <li><strong>Places without close stations</strong> learn nothing and keep the plain blend. A free key for your country's network (<a href="station-keys.html">Free Keys for More Stations</a>) may add close stations.</li>
    <li><strong>Only temperatures</strong> (and feels-like) are corrected. Rain, wind and clouds are not, and the weather condition (for example rain or snow) is decided before the correction.</li>
    <li>Removing a place forgets its learning; adding it back starts from zero.</li>
</ul>
""",
    "live-stations": """
<h1>Live Station Observations</h1>
<p>To capture local microclimates (sea breezes, valley cold pools, urban heat islands, and local gust fronts), Neginato Mezora reads every station network that covers the place at each refresh, tests the stations against each other, and blends the trusted ones, with <strong>the same algorithm in every country</strong>. The result is mixed with a high-resolution model analysis for the exact spot (90 m terrain) to give the forecast page's "now".</p>

<h2>1. Station networks</h2>
<table>
    <thead>
        <tr><th>Network</th><th>Where</th><th>Updates</th><th>Key</th></tr>
    </thead>
    <tbody>
        <tr><td><strong>Airport METAR</strong> (NOAA Aviation Weather Center)</td><td>Worldwide</td><td>Hourly, plus specials when the weather changes</td><td>No</td></tr>
        <tr><td><strong>NWS ASOS</strong> (api.weather.gov)</td><td>US airports (the 3 nearest)</td><td>5 min</td><td>No</td></tr>
        <tr><td><strong>Iowa Environmental Mesonet</strong></td><td>US road-weather, river-gauge, soil-climate and research stations, per NWS forecast office</td><td>5–60 min</td><td>No</td></tr>
        <tr><td><strong>Environment Canada SWOB</strong></td><td>Canada, including partner networks</td><td>1–60 min</td><td>No</td></tr>
        <tr><td><strong>Deutscher Wetterdienst</strong> (via Bright Sky)</td><td>Germany</td><td>10 min</td><td>No</td></tr>
        <tr><td><strong>DMI</strong></td><td>Denmark, Faroe Islands, Greenland</td><td>10 min</td><td>No</td></tr>
        <tr><td><strong>FMI</strong>, <strong>SMHI</strong></td><td>Finland, Sweden</td><td>10 min, hourly</td><td>No</td></tr>
        <tr><td><strong>GeoSphere Austria</strong>, <strong>MeteoSwiss</strong></td><td>Austria, Switzerland</td><td>10 min</td><td>No</td></tr>
        <tr><td><strong>Met Office</strong></td><td>United Kingdom</td><td>Hourly</td><td><a href="station-keys.html#metoffice">Your free key</a></td></tr>
        <tr><td><strong>KNMI</strong></td><td>Netherlands</td><td>10 min</td><td><a href="station-keys.html#knmi">Your free key</a></td></tr>
        <tr><td><strong>MET Norway (Frost)</strong></td><td>Norway</td><td>10 min – hourly</td><td><a href="station-keys.html#frost">Your free key</a></td></tr>
        <tr><td><strong>Météo-France</strong></td><td>France</td><td>6 min</td><td><a href="station-keys.html#meteofrance">Your free key</a></td></tr>
        <tr><td><strong>AEMET</strong></td><td>Spain</td><td>Hourly</td><td><a href="station-keys.html#aemet">Your free key</a></td></tr>
    </tbody>
</table>
<p>National networks are searched a little beyond their borders, so places near a border also get the neighbouring country's stations. Every network can be turned off in <a href="stations-settings.html">Settings › Stations</a>.</p>
<p>Each network starts from a <strong>trust</strong> level for its class of station: national and WMO-standard stations count fully; partner, road-weather and hydrological stations less (for example MET Norway's partner stations 70% and Météo-France's extended network 85%), and their wind much less, because many measure it low or in sheltered spots.</p>

<h2>2. 3D anisotropic spatial kernel</h2>
<p>Each station at horizontal distance <code>d</code> (km) and elevation difference <code>Δz</code> (m) is weighted by:</p>
<pre><code>W_horiz(d) = exp(-d² / (2 * 22.0²)) / (1 + (d / 8.0)²)
W_vert(Δz) = exp(-Δz² / (2 * 350.0²))
W          = W_horiz(d) * W_vert(Δz) * trust * health</code></pre>
<p>The 12 stations of largest weight within 60 km are blended. Reports less than 1.5 km apart (an airport's METAR and its national twin) count as one station.</p>

<h2>3. Diurnal lapse-rate elevation reduction</h2>
<p>A station's temperature is moved to the place's elevation with a lapse rate that depends on the time of day:</p>
<ul>
    <li><strong>Daytime:</strong> <code>Γ_T = -0.0068 °C/m</code> (6.8 °C/km, a mixed boundary layer)</li>
    <li><strong>Night-time:</strong> <code>Γ_T = -0.0042 °C/m</code> (4.2 °C/km, damped by inversions)</li>
    <li><strong>Dew point:</strong> <code>Γ_Td = -0.0019 °C/m</code></li>
</ul>
<p>Station elevations come from the station lists or, for networks that give none, from the Open-Meteo elevation API.</p>

<h2>4. De-clustering, freshness and outlier control</h2>
<ul>
    <li><strong>Angular de-clustering (Shepard, 1968):</strong> stations clustered along the same compass bearing from the place share an angular shadow penalty <code>W_dir = 1 / (1 + shadow)</code>, so one dense cluster cannot outvote the other directions.</li>
    <li><strong>Freshness:</strong> weights decay with the age of the report, with time constants of 45 minutes for temperature, 20 minutes for wind and 15 minutes for the weather.</li>
    <li><strong>Wind direction:</strong> averaged as a vector, never as a number of degrees: each station adds its speed in the direction the wind comes from, calm stations count as zero, and stations that report no direction are left out. No direction is given when the result is under 1 km/h or under a quarter of the mean speed (winds too spread or opposed); the "now" card then uses Open-Meteo's current direction, or draws no arrow.</li>
    <li><strong>Outlier control (Rousseeuw &amp; Croux, 1993):</strong> when at least 3 stations report, a sensor more than <code>3σ</code> from the median (σ = 1.4826 × MAD, at least 1.5 °C) is down-weighted by <code>(3σ / r)²</code>, so real contrasts of up to 4.5 °C are never penalised.</li>
    <li><strong>Short-range bias decay (Glahn &amp; Lowry, 1972):</strong> the observed temperature difference from the forecast fades out over the first 6 forecast hours: <code>ΔT(t) = ΔT_0 * exp(-Δt / 3.5h)</code>.</li>
</ul>

<h2>5. Stations are tested continuously</h2>
<p>At every refresh each station is compared with what its neighbours predict for it. Its track record (bias by day and by night, and scatter) sets its <strong>health</strong>: full weight while its error stays within 1.5 °C, less beyond that, none from 8 °C; a sensor whose reading has not changed for 8 hours is set aside. New stations, and stations that come back, start on probation. A station that stops reporting for 3 days <em>of app use</em> is dropped. The catalog of stations is kept on disk, so restarts lose nothing; time with the app closed never counts. Settings › <a href="stations-settings.html">Stations</a> shows each nearby station's weight and why.</p>

<h2>6. The forecast learns from the stations</h2>
<p>When close, fresh stations are available (within about 25 km and 45 minutes), the app learns how far the models run from them for each place and hour of the day, and corrects the forecast temperatures by up to ±4 °C. See <a href="local-corrections.html">Learned Local Corrections</a>.</p>

<h2>7. Station credits</h2>
<p>The forecast page's credits line names every network whose readings are used, as their terms ask:</p>
<table>
    <thead><tr><th>Network</th><th>Credit shown</th><th>Terms</th></tr></thead>
    <tbody>
        <tr><td>Airport METAR, NWS</td><td>Source: NOAA Aviation Weather Center; National Weather Service</td><td>US public domain</td></tr>
        <tr><td>Iowa Environmental Mesonet</td><td>Source: Iowa Environmental Mesonet, Iowa State University</td><td>Public, credit requested</td></tr>
        <tr><td>Environment Canada</td><td>Contains information licenced under the Data Server End-use Licence of Environment and Climate Change Canada</td><td>Data Server End-use Licence</td></tr>
        <tr><td>DWD, DMI, FMI, SMHI, GeoSphere Austria, MeteoSwiss, KNMI, MET Norway</td><td>Each service's source line (for example "Source: MeteoSwiss", "Source: KNMI", "Data from The Norwegian Meteorological Institute"), then <em>Station data CC BY 4.0, quality-checked and blended</em></td><td>CC BY 4.0 (MET Norway also NLOD 2.0)</td></tr>
        <tr><td>Met Office</td><td>Powered by Met Office data</td><td>Weather DataHub licence</td></tr>
        <tr><td>Météo-France</td><td>Source: Météo-France, data of 25 Oct 14:06 UTC</td><td>Licence Ouverte / Etalab 2.0 (source and date)</td></tr>
        <tr><td>AEMET</td><td>Source: AEMET, data of 25 Oct 14:00 UTC</td><td>AEMET legal notice (source and date)</td></tr>
    </tbody>
</table>
<p>Station elevations come from the Open-Meteo elevation API (CC BY 4.0).</p>
""",
    "weather-alerts": """
<h1>Weather Alerts</h1>
<p>Neginato Mezora shows the official weather warnings in force for each saved place, as the issuer published them. The app does not make up, forecast or re-rate alerts, and it does not send notifications: alerts are shown only in the window, on the forecast page and in the sidebar. No alert source needs a key or an account, and there is no setting for them.</p>

<h2>Where alerts come from</h2>
<p>Each place is served by exactly one source, chosen by its country:</p>
<table>
    <thead><tr><th>Source</th><th>Places</th><th>How a place is matched</th></tr></thead>
    <tbody>
        <tr><td><strong>National Weather Service</strong></td><td>United States, Puerto Rico, US Virgin Islands, Guam, American Samoa, Northern Mariana Islands and the US Minor Outlying Islands; a place without a country inside the NWS area</td><td>The NWS answers for the place's point. A point it calls out of bounds (for example Wake Island) reads <em>Alerts not available</em>.</td></tr>
        <tr><td><strong>Deutscher Wetterdienst</strong> (via Bright Sky)</td><td>Germany</td><td>Bright Sky answers for the point; a point it does not cover reads <em>Alerts not available</em>.</td></tr>
        <tr><td><strong>MET Norway</strong> (MetAlerts)</td><td>Norway (not Svalbard and Jan Mayen)</td><td>MET Norway answers for the point.</td></tr>
        <tr><td><strong>Environment and Climate Change Canada</strong></td><td>Canada</td><td>The alert areas that contain the point.</td></tr>
        <tr><td><strong>MeteoAlarm</strong></td><td>35 more countries in Europe, and Israel: Austria, Belgium, Bosnia and Herzegovina, Bulgaria, Croatia, Cyprus, Czechia, Denmark, Estonia, Finland, France, Greece, Hungary, Iceland, Ireland, Israel, Italy, Latvia, Lithuania, Luxembourg, Malta, Moldova, Montenegro, the Netherlands, North Macedonia, Poland, Portugal, Romania, Serbia, Slovakia, Slovenia, Spain, Sweden, Switzerland, Ukraine and the United Kingdom</td><td>The country's whole warning feed is downloaded (nothing about the place is sent) and matched in the app against each warning's own outline or the issuer's region outlines bundled with the app. In a country whose warnings name regions, a place outside every region its feed uses reads <em>Alerts not available</em>.</td></tr>
    </tbody>
</table>
<p>Places in any other country read <em>Alerts not available</em>.</p>

<h2>The Alerts card</h2>
<p>On the forecast page, below <strong>Now</strong>, each alert in force gets a card, highest level first (then the earliest start):</p>
<ul>
    <li>The event name (for example <em>Tornado Warning</em>) and a badge with a warning triangle and its level: <strong>Red</strong>, <strong>Orange</strong>, <strong>Yellow</strong>, <strong>Minor</strong> or <strong>Unknown</strong>, drawn in the level's colour on a dark background. VoiceOver reads this line as the card's heading. The level is taken from the colour or severity the issuer gives.</li>
    <li>The issuer's headline, then <em>Effective Today 3:00 PM</em> and <em>Expires Friday 6:00 AM</em>, in the place's time zone, when the issuer gives them.</li>
    <li>The issuer's instructions, if any, and <strong>Details</strong>, which expands the full description.</li>
    <li><em>Source: National Weather Service</em> (or the other issuer), linked to the issuer's page for the alert when it gives one.</li>
</ul>
<p>In the sidebar, a warning triangle after the place's name, coloured by the highest level, with the number of alerts when there is more than one. Both disappear when the alert expires or ends, without a new download.</p>

<h2>What the card says when there is no alert to show</h2>
<table>
    <thead><tr><th>Text</th><th>Meaning</th></tr></thead>
    <tbody>
        <tr><td><em>Checking for alerts…</em> (with a spinner)</td><td>No answer has come yet for this place.</td></tr>
        <tr><td><em>No active alerts</em></td><td>The source answered recently and has no alert in force for the place.</td></tr>
        <tr><td><em>Alerts could not be checked right now.</em></td><td>The latest check failed (no network answer, a server error, an unreadable answer or one over the size limit) and there is no recent answer to show.</td></tr>
        <tr><td><em>Alerts could not be checked recently.</em> <em>Last checked: Today 3:00 PM.</em></td><td>The newest answer is older than its source's window (30 minutes for MeteoAlarm, 10 minutes for the others), for example while offline or while the window is hidden. Its alerts are not shown as cards and the sidebar shows no warning sign, because they may no longer be current.</td></tr>
        <tr><td><em>Alerts not available</em></td><td>No source covers the place.</td></tr>
    </tbody>
</table>
<p>A <em>Source: …</em> line under the text names the issuer the place is routed to. A failed check does not hide alerts from an answer still within its window.</p>

<h2>How often alerts are checked</h2>
<ul>
    <li>A place's alerts are checked only after one of its forecast refreshes completes (with a forecast or an error), never on their own timer and never while offline. They therefore follow the <a href="units-refresh.html">forecast refresh</a>: while the window is visible, about every 10 minutes, and with <kbd>⌘R</kbd>.</li>
    <li><strong>MeteoAlarm:</strong> a country's feed is downloaded at most once every 30 minutes, shared by every place in that country. A failed download is reused for 120 seconds, so the places of one country refreshed within that time cost one attempt; a later refresh tries again. The feed may be up to 16 MiB.</li>
    <li><strong>NWS, Bright Sky, MET Norway, Environment Canada:</strong> an answer for a point is reused for 5 minutes, also by another place at the same point; a failed one is not reused. As its terms require, a MET Norway answer is reused until the expiry time it sends, and then asked for again with <code>If-Modified-Since</code>.</li>
    <li>Shown alerts are checked against the clock: one that expires or ends disappears at that time (after the Mac wakes from sleep, within a minute), without a new download.</li>
</ul>

<h2>Limitations</h2>
<ul>
    <li><strong>Alert areas follow each issuer's published region shapes</strong>, which can differ from local boundaries near borders and coasts. In Ireland, MeteoAlarm's own county outlines put a few border towns in a neighbouring county: the centre of Waterford city lies in County Kilkenny's outline, and Youghal, Carrick-on-Shannon and Killaloe likewise lie in a neighbouring county's. A warning for their own county may not reach them, while a neighbour's does.</li>
    <li><strong>Coastal places and islands</strong> outside the land outlines (for example Howth, Bray, Greystones, Malahide, Tory Island and Cape Clear) are reached only by marine warnings, or read <em>Alerts not available</em>.</li>
    <li><strong>An old answer is hidden, not shown as current.</strong> When alerts could not be checked for longer than the source's window, you see <em>Alerts could not be checked recently</em> and no warning sign, although an alert may still be in force. Check the issuer's website in that case.</li>
    <li>If a MeteoAlarm download fails during a long refresh round (many places on a slow network), the feed can be downloaded once more for every further 120 seconds of that round.</li>
    <li>The app shows what the issuers publish. For your safety, follow the instructions of your local authorities.</li>
</ul>

<h2>Credits</h2>
<p>The same credits are listed under <strong>Weather alerts</strong> in About Neginato Mezora:</p>
<ul>
    <li>US alerts: NOAA/National Weather Service (<a href="https://www.weather.gov/documentation/services-web-api">api.weather.gov</a>), US government work, credited as a courtesy</li>
    <li>German alerts: Deutscher Wetterdienst (DWD) via Bright Sky, under the <a href="https://www.dwd.de/EN/service/copyright/copyright_node.html">DWD Terms of Use</a></li>
    <li>Norwegian alerts: MET Norway (MetAlerts), licensed <a href="https://api.met.no/doc/License">CC BY 4.0</a></li>
    <li>Canadian alerts: Contains information licenced under the <a href="https://eccc-msc.github.io/open-data/licence/readme_en/">Data Server End-use Licence</a> of Environment and Climate Change Canada.</li>
    <li>European alerts: MeteoAlarm. Data provided by EUMETNET members, licensed <a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a></li>
    <li>MeteoAlarm regions: © EuroGeographics for the administrative boundaries</li>
</ul>
""",
    "privacy": """
<h1>Privacy, Data &amp; Storage</h1>
<p>Neginato Mezora has no account, no analytics and no server of its own. It talks directly to public weather services. This page lists what it sends and what it stores.</p>

<h2>What is sent, and to whom</h2>
<table>
    <thead><tr><th>Service</th><th>What it receives</th><th>When</th></tr></thead>
    <tbody>
        <tr><td>Open-Meteo (forecasts, current conditions, 15-minute rain, CAMS air quality, elevations)</td><td>Place coordinates; station coordinates for elevations</td><td>Every place</td></tr>
        <tr><td>MET Norway (api.met.no)</td><td>Place coordinates</td><td>Every place, when the source is on</td></tr>
        <tr><td>US National Weather Service (api.weather.gov)</td><td>Place coordinates; nearby airport codes</td><td>US places</td></tr>
        <tr><td>Bright Sky (DWD data)</td><td>Place coordinates</td><td>Germany, Benelux, Central Europe</td></tr>
        <tr><td>Environment Canada (api.weather.gc.ca)</td><td>Place coordinates or an area around them</td><td>Canada and near it</td></tr>
        <tr><td>NOAA Aviation Weather Center</td><td>An area of about 95 km around the place</td><td>Every place</td></tr>
        <tr><td>Iowa Environmental Mesonet</td><td>The NWS forecast-office code of the area</td><td>US places</td></tr>
        <tr><td>US EPA AirNow (services.arcgis.com)</td><td>Place coordinates (monitors within 45 km)</td><td>Places outside Europe</td></tr>
        <tr><td>DMI, FMI</td><td>An area around the place</td><td>Denmark, Finland</td></tr>
        <tr><td>SMHI</td><td>Nothing about the place (all of Sweden is fetched)</td><td>Sweden</td></tr>
        <tr><td>GeoSphere Austria, MeteoSwiss</td><td>Codes of nearby stations</td><td>Austria, Switzerland</td></tr>
        <tr><td>Met Office, KNMI, MET Norway Frost</td><td>Your key for that service, and the place's coordinates or area</td><td>Only with your key, for places in their country</td></tr>
        <tr><td>Météo-France, AEMET</td><td>Your key for that service (all of France or Spain is fetched)</td><td>Only with your key, for places in their country</td></tr>
        <tr><td>Official alerts: National Weather Service (api.weather.gov), Bright Sky (DWD alerts), MET Norway MetAlerts (api.met.no), Environment Canada (api.weather.gc.ca)</td><td>Place coordinates</td><td>After a forecast refresh, for places in the US, Germany, Norway and Canada</td></tr>
        <tr><td>MeteoAlarm (feeds.meteoalarm.org)</td><td>Nothing about the place (the warnings of the whole country are fetched)</td><td>After a forecast refresh, for places in a MeteoAlarm country</td></tr>
        <tr><td>Place search: Open-Meteo geocoding, Apple Maps, OpenStreetMap Nominatim, Photon (komoot), US Census geocoder</td><td>The text you type in the Add a city window</td><td>While you search</td></tr>
    </tbody>
</table>
<p>Requests identify the app by name in their User-Agent; no personal identifier is sent. Turning a forecast source off in Settings › Sources stops its forecast requests; station networks have their own switches in Settings › Stations.</p>

<h2>What is stored on this Mac</h2>
<p>The app is sandboxed. Its files are in <code>~/Library/Containers/io.github.wtp128pro.Weather/Data/Library/</code>:</p>
<table>
    <thead><tr><th>File</th><th>Contents</th></tr></thead>
    <tbody>
        <tr><td><code>Application Support/weather/places.json</code></td><td>Your places, names, order and units</td></tr>
        <tr><td><code>Application Support/weather/settings.json</code></td><td>Default units for new places, sources turned off, the selected place</td></tr>
        <tr><td><code>Application Support/weather/weights.json</code></td><td>Your weight multipliers</td></tr>
        <tr><td><code>Application Support/weather/station-settings.json</code></td><td>Corrections on or off, station networks turned off</td></tr>
        <tr><td><code>Application Support/weather/local-bias.json</code></td><td>The learned local corrections</td></tr>
        <tr><td><code>Application Support/weather/stations.json</code></td><td>The stations seen, their latest readings and track records</td></tr>
        <tr><td><code>Caches/weather/forecasts.json</code></td><td>The last forecast of each place, shown at launch and offline</td></tr>
    </tbody>
</table>
<p><strong>API keys</strong> for the station networks are stored in your <strong>login Keychain</strong> (as "Neginato Mezora: … key"), never in these files, and are sent only to their own service over HTTPS. Remove one in Settings › Stations, or in the Keychain Access app.</p>
<p>To start completely fresh, quit the app and delete the folder above (and the keys in Keychain Access).</p>
""",
    "troubleshooting": """
<h1>Troubleshooting &amp; FAQ</h1>

<h2>The forecast says "Stale" or "Couldn't load the forecast"</h2>
<p>The last refresh failed; hover over the <strong>Stale</strong> badge for the reason. The app retries automatically (every 10 minutes, and when the window comes back to the front). If only some services failed, the page says <em>Not available right now: …</em> and the forecast is blended from the others. <kbd>⌘R</kbd> retries now (not more often than every 10 seconds).</p>

<h2>Refresh does nothing</h2>
<p>Refresh is ignored while the place is loading, within 10 seconds of its last refresh, for 60 seconds after a service asked for fewer requests, and while offline. Forecasts are also not fetched while the window is hidden or minimised.</p>

<h2>The footer shows no station, or only a distant one</h2>
<p>No station within 95 km reported in the last 3 hours, or the nearest ones are far. In the UK, the Netherlands, Norway, France and Spain, a free key adds the national network (<a href="station-keys.html">Free Keys for More Stations</a>). Settings › Stations › Stations Near… shows which stations are known for the selected place and their state.</p>

<h2>A station near me reads clearly wrong</h2>
<p>Each station is tested against its neighbours at every refresh; one that is off by more than 1.5 °C loses weight, from 8 °C it is not used, and a stuck reading is set aside after 8 hours. A brand-new station starts at 60% weight. If you have reason to distrust a whole network, turn it off in Settings › Stations.</p>

<h2>The key I entered "was refused"</h2>
<ul>
    <li>Paste it again: the whole key, without extra characters (spaces at the ends are removed automatically).</li>
    <li>Check that the key is for the right product of the service; some services only activate a key after you confirm your e-mail address or subscribe it to the observations product.</li>
    <li>Some keys expire (AEMET's after 3 months); create a new one on the service's site and use <strong>Replace…</strong>.</li>
</ul>
<p>Each service's specific causes are listed in <a href="station-keys.html#trouble">When a key does not work</a>.</p>

<h2>"The service's limit for this key was reached"</h2>
<p>The free plan's request limit was hit, usually the Met Office's 360 calls a day with many UK places. The app keeps the network's recent readings for up to 90 minutes and tries again at the next refresh; the Met Office count resets at 00:00 UTC.</p>

<h2>The forecast changed after I added stations or a key</h2>
<p>More or closer stations change the "now" values, and over a few days the learned local corrections. That is expected. To compare with the plain models, turn off <strong>Correct forecasts with what nearby stations measure</strong> in Settings › Stations.</p>

<h2>Learned corrections look wrong</h2>
<p>Corrections are capped at ±4 °C and need several readings per hour of day, but a place whose only close station is badly sited can teach the wrong lesson. Reset the place in Settings › Stations › Learned Local Corrections, and consider turning off that station's network.</p>

<h2>Why does the temperature differ from my phone's weather app?</h2>
<p>Most weather apps show a single model or a provider's own blend for a grid point. Neginato Mezora blends several models, grounds "now" in tested nearby stations, and corrects for the place's learned local bias, so it can differ by a few degrees, especially at night, in valleys and near water.</p>

<h2>The air quality number seems off, or shows a dash</h2>
<p>The small line on the card says where the number comes from. A <em>measured</em> value is the nearest AirNow monitor's latest hourly reading, as reported; the monitor can be up to 45 km away, in a different setting (for example next to a busy road), and AirNow's data are preliminary. A <em>CAMS model forecast</em> describes an area 11–45 km wide and can miss local sources such as traffic, wood smoke or nearby wildfire smoke. A dash means neither source has answered yet; offline the card needs the network. See <a href="forecast-page.html">Reading the Forecast</a>. For official alerts, follow your local air-quality agency.</p>

<h2>I want to start over</h2>
<p>Reset the learned corrections and forget the stations in Settings › Stations; reset weights in Settings › Weights. To erase everything, see <a href="privacy.html">Privacy, Data &amp; Storage</a>.</p>
""",
    "algorithms": """
<h1>Ensemble Blending &amp; Meteorological Citations</h1>
<p>Every forecast value in <strong>Neginato Mezora</strong> is computed by deterministic, unit-tested algorithms in <code>WeatherCore</code>.</p>

<h2>1. IEEE-754 <code>frexp</code>/<code>ldexp</code> Weighted Median (<code>WeightedMedian.swift</code>)</h2>
<p>Continuous variables (temperature, feels-like, wind speed, gusts, cloud cover, relative humidity, and precipitation amount) are blended using the <strong>weighted median</strong> (Edgeworth, 1888) rather than an arithmetic mean so a single outlier model cannot skew the forecast. To prevent IEEE-754 floating-point overflow or underflow without altering mantissa bits, weights are rescaled by an exact power of two via <code>frexp</code> and <code>ldexp</code> (Goldberg, 1991):</p>
<pre><code>w_tilde_i = ldexp(w_i, -max_exp)   // exact exponent shift, zero mantissa rounding</code></pre>
<p>When cumulative weight lands strictly on the 50% midpoint, the two adjacent values are averaged using an overflow-safe sign-aware formula (<code>meanOfPair</code>).</p>

<h2>2. Mass-Conserving 15-Minute Nowcast Rescaling (<code>Nowcast.swift</code>)</h2>
<p>Across the US, Canada, UK, Netherlands, Germany, and Europe, 15-minute sub-hourly precipitation quarters (from <code>NOAA HRRR</code>, <code>UKMO 2 km</code>, <code>KNMI HARMONIE 2 km</code>, or <code>DWD ICON-D2 2 km</code>) are summed into full UTC hours prior to blending. After multi-model blending produces the consensus hourly total <code>B_H</code>, the 3 smaller quarters scale by <code>B_H / raw_sum</code> and the first largest quarter absorbs the exact remainder <code>B_H - rest</code> so the 4 quarters sum identically to <code>B_H</code>.</p>

<h2>3. Multi-Model Precipitation Probability Consensus (<code>Blend.swift</code>)</h2>
<p>When explicit precipitation probability models represent a minority of the active precipitation ensemble (for example, when regional NWP models report hourly rain rate <code>precipMm</code> without an explicit probability field), <code>WxBlend</code> combines the reported probability mean with the weighted fraction of ensemble members predicting measurable precipitation (<code>precipMm &ge; 0.1 mm/h</code>).</p>

<h2>4. WMO Code 4677 &amp; Hydrometeor Classification (<code>ConditionRules.swift</code>)</h2>
<ul>
    <li><strong>Thunderstorm Majority:</strong> &ge; 50% of WMO-reporting members in <code>{95, 96, 97, 99}</code>.</li>
    <li><strong>Snow Majority:</strong> &ge; 50% in <code>{71, 73, 75, 77, 85, 86}</code> and blended temperature <code>T &le; 2.0 °C</code>.</li>
    <li><strong>Sleet / Freezing Rain:</strong> &ge; 50% in <code>{56, 57, 66, 67}</code>, or wet hour with <code>0.0 °C &le; T &lt; 1.5 °C</code>.</li>
    <li><strong>Wet Hour Criterion:</strong> <code>precipMm &ge; 0.1 mm/h</code> and <code>precipProb &ge; 30%</code> (classified as <code>.showers</code> when <code>cloudPct &lt; 87.5%</code> and <code>precipMm &lt; 7.6 mm/h</code>, else steady <code>.rain</code>).</li>
</ul>

<h2>5. Primary Academic &amp; Standard Citations</h2>
<ul>
    <li><strong>Alduchov &amp; Eskridge (1996):</strong> <em>Improved Magnus Form Approximation of Saturation Vapor Pressure</em>, J. Appl. Meteor., 35, 601–609.</li>
    <li><strong>Bengtsson et al. (2017):</strong> <em>The HARMONIE–AROME Model Configuration in the ALADIN–HIRLAM NWP System</em>, Mon. Wea. Rev., 145, 1919–1935.</li>
    <li><strong>Benjamin et al. (2016):</strong> <em>A North American Hourly Assimilation and Model Forecast Cycle: The Rapid Refresh (HRRR)</em>, Mon. Wea. Rev., 144, 1669–1694.</li>
    <li><strong>Edgeworth (1888):</strong> <em>On a New Method of Reducing Observations Relating to Several Quantities</em>, Phil. Mag., 25, 184–191.</li>
    <li><strong>Glahn &amp; Lowry (1972):</strong> <em>The Use of Model Output Statistics (MOS) in Objective Weather Forecasting</em>, J. Appl. Meteor., 11, 1203–1211.</li>
    <li><strong>Goldberg (1991):</strong> <em>What Every Computer Scientist Should Know About Floating-Point Arithmetic</em>, ACM Comput. Surv., 23, 5–48.</li>
    <li><strong>Hamill et al. (2017):</strong> <em>The U.S. National Blend of Models (NBM)</em>, BAMS, 98, 2599–2617.</li>
    <li><strong>Meeus (1998):</strong> <em>Astronomical Algorithms</em> (2nd ed.), Willmann-Bell (NOAA solar elevation &amp; equation of time).</li>
    <li><strong>Milbrandt et al. (2016):</strong> <em>The Pan-Canadian High Resolution (2.5 km) Deterministic Prediction System (HRDPS)</em>, Weather and Forecasting, 31, 1791–1816.</li>
    <li><strong>Osczevski &amp; Bluestein (2005):</strong> <em>The New Wind Chill Equivalent Temperature Chart</em>, BAMS, 86, 1453–1458.</li>
    <li><strong>Rothfusz (1990):</strong> <em>The Heat Index Equation</em>, NWS Technical Attachment SR/SSD 90-23.</li>
    <li><strong>Rousseeuw &amp; Croux (1993):</strong> <em>Alternatives to the Median Absolute Deviation (MAD)</em>, JASA, 88, 1273–1283.</li>
    <li><strong>Shepard (1968):</strong> <em>A Two-Dimensional Interpolation Function for Irregularly-Spaced Data</em>, Proc. 23rd ACM Nat. Conf., 517–524.</li>
    <li><strong>Stull (2011):</strong> <em>Wet-Bulb Temperature from Relative Humidity and Air Temperature</em>, JAMC, 50, 2267–2269.</li>
    <li><strong>Zängl et al. (2015):</strong> <em>The ICON Modelling Framework of DWD and MPI-M</em>, QJRMS, 141, 563–579.</li>
</ul>
""",
}
