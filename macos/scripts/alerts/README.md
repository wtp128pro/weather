# MeteoAlarm region table

`build_meteoalarm_regions.py` bakes the geometry MeteoAlarm warnings refer to
into `WeatherCore/Resources/MeteoAlarmRegions.json`. Most MeteoAlarm country
feeds (`https://feeds.meteoalarm.org/api/v1/warnings/feeds-{slug}`) name a
warning's area only by geocode (`EMMA_ID`, `NUTS3`, `NUTS2`); the app looks the
code up in this table and runs point-in-polygon on the region it names. There
is no nearest-region, country-wide or `areaDesc` name fallback: a code the
table does not carry leaves that warning unmatched. The one exception is a
fixed, cited code-to-code alias for Ireland's FIPS 10-4 county codes
([below](#irish-fips-10-4-county-codes)).

Python 3 standard library only. The inputs are downloaded into a cache outside
the repository (`$METEOALARM_GEO_CACHE`, else `<tempdir>/meteoalarm-geo-inputs`;
on macOS `$TMPDIR/meteoalarm-geo-inputs`) and checked against the sha256 pins in
the script; a different upstream file stops the build.

```sh
cd macos
python3 scripts/alerts/build_meteoalarm_regions.py               # fetch + build + write build_manifest.json
python3 scripts/alerts/build_meteoalarm_regions.py --verify      # rebuild from cache, byte-compare, size, coverage
python3 scripts/alerts/build_meteoalarm_regions.py --self-check  # coastal/border towns inside a region of their country
python3 scripts/alerts/build_meteoalarm_regions.py --check-feeds DIR  # codes in saved api/v1 feeds the table cannot place
```

`--verify` exits 1 if the committed resource is not byte-identical to a
rebuild from the pinned inputs, is not under 3,000,000 bytes, lacks any
EMMA_ID of the geocodes file or any NUTS region of the carried
countries/editions, or cannot place a NUTS code the feeds filed on 2026-10-26.
It downloads a missing input (pass `--no-download` to fail instead).
`--self-check` exits 1 if any of its 27 towns (Venice, Lisbon, Valletta,
Dubrovnik, Nice, Varna, Constanța, Ohrid, Ostend, Siófok, and 17 more) falls
outside every region of its own country.

## Sources, editions and inputs

| Input (cached file) | Edition | sha256 | bytes |
|---|---|---|---|
| [MeteoAlarm_Geocodes_2026_07_31.json](https://gitlab.com/meteoalarm-pm-group/documents/-/raw/master/MeteoAlarm_Geocodes_2026_07_31.json) (MeteoAlarm PM group GitLab) | 2026-07-31; 2006 EMMA_ID regions, 30 countries | `41ff77fc08cff6b0c8b3f8d56c66f02796b762c3415432a3704b6ca77a8c1ad6` | 33252745 |
| [NUTS_RG_03M_2013_4326_LEVL_3.geojson](https://gisco-services.ec.europa.eu/distribution/v2/nuts/geojson/NUTS_RG_03M_2013_4326_LEVL_3.geojson) (Eurostat GISCO) | NUTS 2013, 1:3 million, EPSG:4326 | `a860545eb4e3afcd22b6f921bdede3e16a7e20778435ff1c9eceae4e05678120` | 9917062 |
| [NUTS_RG_03M_2013_4326_LEVL_2.geojson](https://gisco-services.ec.europa.eu/distribution/v2/nuts/geojson/NUTS_RG_03M_2013_4326_LEVL_2.geojson) (Eurostat GISCO) | NUTS 2013, 1:3 million, EPSG:4326 | `77fa4c28b970a0e5afeba9a44ee23cc872627441e039668cf498a4412c87444f` | 5909750 |
| [NUTS_RG_03M_2021_4326_LEVL_3.geojson](https://gisco-services.ec.europa.eu/distribution/v2/nuts/geojson/NUTS_RG_03M_2021_4326_LEVL_3.geojson) (Eurostat GISCO) | NUTS 2021, 1:3 million, EPSG:4326 | `5a5a6cc672c3bc50b51a8d6b9605760dd26322f894624042872fdb9702a50ea4` | 7100768 |

Built 2026-10-26 with **Python 3.15.1** (also recorded, with the output's
sha256, in `build_manifest.json`, which every build rewrites). Output:
2,723,008 bytes, sha256
`1ff49059a29e40f1a041657ba7d5d562b347f8b0355042ef8ddd634e1a0db6ef`.

Which NUTS edition per country follows what the feeds file (all 38 api/v1
feeds read 2026-10-26):

| Type | Countries | Edition | Why |
|---|---|---|---|
| NUTS3 | FR, BG, RO | 2013 | France files 2013 codes (`FR211`, not 2016's `FRF21`); BG/RO codes are the same in 2013 and 2021 |
| NUTS3 | HR | 2021, plus 2013 codes 2021 lacks | Croatia files 2021 codes (`HR027` Karlovačka was `HR04D` in 2013); no code names one county in 2013 and another in 2021 |
| NUTS3 | MK | 2021 | North Macedonia files its 8 statistical regions as `NUTS3` `MK001`–`MK008` |
| NUTS2 | HU, BE | 2013 | Hungary files `HU10` (split into `HU11`/`HU12` in 2016) |

Carried: 2006 `EMMA_ID` (AT 116, BA 10, BE 10, BG 28, CY 1, CZ 206, DE 410,
DK 28, ES 233, FI 53, FR 97, GR 16, HR 14, HU 7, IE 51, IS 11, IT 20, LT 71,
LV 4, MD 42, ME 3, MK 8, MT 1, NL 25, PL 385, PT 25, RO 42, RS 11, SI 6,
SK 72), 214 `NUTS3` (FR 101, BG 28, RO 42, HR 35, MK 8), 18 `NUTS2` (BE 11, HU 7).

## Resource format (for the region lookup)

One UTF-8 JSON object, compact separators, trailing newline:

```json
{
  "format": 1,
  "geometry": {"crs": "EPSG:4326", "order": "lon,lat",
               "simplification": "Douglas-Peucker 0.004 deg, rings split in halves", "decimals": 4},
  "sources": [{"name": "...", "edition": "...", "url": "...", "sha256": "...",
               "licence": "...", "attribution": "..."}],
  "regions": [{"type": "EMMA_ID", "code": "BE001", "country": "BE", "name": "Luxembourg",
               "polygons": [[[[6.0219, 50.1824], [5.7689, 49.8452], ..., [6.0219, 50.1824]]]]}]
}
```

(`BE001`'s real first points; it has one polygon of 25 points. 2238 regions in all.)

- `regions` is sorted by (`type`, `code`); (`type`, `code`) is unique. `type`
  is exactly the CAP `geocode.valueName` the feeds use: `EMMA_ID`, `NUTS3` or
  `NUTS2`. Match a warning's geocode on **both** fields: `NUTS3/HR031` and
  `EMMA_ID/HR031` are different regions.
- `country` is the two-letter country code (EMMA `country`; GISCO `CNTR_CODE`,
  which for the seven NUTS countries carried equals ISO 3166-1); `name` is the
  source's name (EMMA `name`, GISCO `NAME_LATN`), for diagnostics only.
- `polygons` is a GeoJSON MultiPolygon coordinate array: polygons → rings →
  points; point = `[lon, lat]` (longitude first, as GeoJSON), 4 decimals;
  ring 0 is the outer ring, any further rings are holes; every ring is closed
  (first point repeated last) and has ≥ 3 distinct points. Use even-odd
  ray casting over all rings of a polygon; a point is in the region if it is
  in any polygon. Regions may overlap (MeteoAlarm's coastal/marine EMMA
  regions overlap land regions; HR carries both editions' codes).

## Attribution and licences

**MeteoAlarm (EMMA_ID geometry and the warnings themselves).** The footer of
<https://feeds.meteoalarm.org/> (read 2026-10-26) reads "© 2026 MeteoAlarm.
Data provided by EUMETNET members." and links "MeteoAlarm License (CC BY 4.0)"
to <https://creativecommons.org/licenses/by/4.0/>. Credit required:
**Data provided by EUMETNET members** (MeteoAlarm, CC BY 4.0). The geocodes
file itself carries no licence text (its features hold only `code`,
`country`, `name`, `type`); it is published by the MeteoAlarm PM group and
treated as MeteoAlarm data under CC BY 4.0.

**Eurostat GISCO (NUTS2/NUTS3 geometry).** Copyright notice to show:
**© EuroGeographics for the administrative boundaries**. The NUTS download
page <https://ec.europa.eu/eurostat/web/gisco/geodata/statistical-units/territorial-units-statistics>
carries no terms in its served HTML (read 2026-10-26); the terms are on the
parent page <https://ec.europa.eu/eurostat/web/gisco/geodata/statistical-units>,
which names "territorial units for statistics (NUTS)" among the pages they
cover. Verbatim (read 2026-10-26):

> In addition to the general copyright and licence policy that applies to the
> Eurostat website, the following specific rules apply to the datasets you are
> downloading. The download and use of these data are subject to you accepting
> the following clauses:
>
> The Commission agrees to grant the non-exclusive and non-transferable right
> to use and process the Eurostat/GISCO geographical data downloaded from this
> page (the ‘data’).
>
> The permission to use the data is granted on condition that:
> - the data will not be used for commercial purposes
> - the source will be acknowledged. A copyright notice, as specified below,
>   must be visible on any printed or electronic publication using the data
>   downloaded from this page.
>
> Copyright notice
>
> When you use data downloaded from our webpages on: census, coastal, local
> administrative units (LAU), territorial units for statistics (NUTS), cities
> and functional urban areas
>
> In any printed or electronic publication, in addition to any other rules that
> apply to the Eurostat website, the data source must be acknowledged in the
> legend of the map and in the introductory page of the publication with the
> following copyright notice:
>
> EN: © EuroGeographics for the administrative boundaries
> FR: © EuroGeographics pour les limites administratives
> DE: © EuroGeographics bezüglich der Verwaltungsgrenzen
>
> For publications in languages other than English, French or German, the
> translation of the copyright notice in the language of the publication must
> be used.
>
> If you intend to use the data commercially, please contact EuroGeographics
> for information about their licence agreements.

The same clauses appear on the administrative-units page
(<https://ec.europa.eu/eurostat/web/gisco/geodata/administrative-units>) for
communes, countries and postal codes. The non-commercial, non-transferable
condition is a known risk the project accepted (DECISIONS #9); the
EuroGeographics notice must also ship in the app's Sources/About surface and
the Help Book.

## Irish FIPS 10-4 county codes

Met Éireann files every Irish land warning under `FIPS` geocodes only: the
FIPS 10-4 codes of the 26 traditional counties, **26 FIPS-only land codes
`EI01`–`EI31` with gaps** (`EI05`, `EI08`, `EI09`, `EI17`, `EI28` unused). The
geocodes file carries the same counties only as `EMMA_ID` `IE006`–`IE031`
("County Carlow" …), and the table does not carry `FIPS`. So
`WxAlertRegions.fipsAliases` (`WeatherCore/Alerts/AlertRegions.swift`) maps
each FIPS county code to the `EMMA_ID` region of the same county, and a `FIPS`
geocode is looked up under its alias. It is code to code: a FIPS code not in
the table (a gap, the later GEC codes `EI32`–`EI44` for cities and post-1994
administrative counties, another country's code, any other spelling) never
matches, and `areaDesc` is never read for placement.

| FIPS | County | EMMA_ID | | FIPS | County | EMMA_ID |
|---|---|---|---|---|---|---|
| `EI01` | Carlow | `IE020` | | `EI16` | Limerick | `IE013` |
| `EI02` | Cavan | `IE027` | | `EI18` | Longford | `IE025` |
| `EI03` | Clare | `IE014` | | `EI19` | Louth | `IE019` |
| `EI04` | Cork | `IE007` | | `EI20` | Mayo | `IE016` |
| `EI06` | Donegal | `IE018` | | `EI21` | Meath | `IE023` |
| `EI07` | Dublin | `IE012` | | `EI22` | Monaghan | `IE031` |
| `EI10` | Galway | `IE015` | | `EI23` | Offaly | `IE028` |
| `EI11` | Kerry | `IE008` | | `EI24` | Roscommon | `IE026` |
| `EI12` | Kildare | `IE030` | | `EI25` | Sligo | `IE017` |
| `EI13` | Kilkenny | `IE021` | | `EI26` | Tipperary | `IE006` |
| `EI14` | Leitrim | `IE029` | | `EI27` | Waterford | `IE009` |
| `EI15` | Laois | `IE022` | | `EI29` | Westmeath | `IE024` |
| | | | | `EI30` | Wexford | `IE010` |
| | | | | `EI31` | Wicklow | `IE011` |

Sources, each read 2026-10-26 (all 26 pairs agree in every one):

- **FIPS PUB 10-4** (NIST, April 1995), "Geopolitical Entities and Their
  Codes", `EI IRELAND`, county, printed pages 23–24 (PDF pages 29–30):
  <https://nvlpubs.nist.gov/nistpubs/Legacy/FIPS/fipspub10-4.pdf> (3,645,966
  bytes, sha256 `9f468da5e1e7a4bfb9b51bde708978ca5face354ec5aaaba3ac9c692b5f2366d`;
  a scan, read from the rendered pages).
- **Statoids**, "Counties of Ireland", <https://www.statoids.com/uie.html>:
  its table's "Traditional" and "FIPS" (FIPS PUB 10-4) columns. It notes that
  Change Notice 8 (2002) changed only the counties' Gaelic names, and lists
  the GEC codes (which superseded FIPS 10-4 in 2010) for the cities and
  administrative counties (`EI32`–`EI44`).
- **Wikipedia**, "List of FIPS region codes (D–F)", section *EI: Ireland*,
  <https://en.wikipedia.org/wiki/List_of_FIPS_region_codes_(D%E2%80%93F)>.
- **MeteoAlarm geocodes file** (the pinned input above): the `EMMA_ID` region
  named "County *X*" for each FIPS county *X*; `IE006`–`IE031` are exactly the
  26 counties.
- **The Irish feed itself** (`feeds-ireland`, recorded 2026-10-26 and read live
  2026-10-26T20:26Z): in each of its FIPS-only areas (12 recorded, 13 live) the
  counties `areaDesc` names (provinces expanded) are exactly the counties its
  codes alias to, and
  the 26 codes filed are exactly the 26 above. The feed alone pins 13 of the
  pairs (e.g. "Orange Wind | Donegal" = `EI06`); the other 13 are consistent
  with it.

To re-check after a new geocodes edition or a feed change: list the codes of
every Irish area whose geocodes are all `FIPS`; each must be in the table, and
the counties its `areaDesc` names must be the alias targets' names. A new code
is added only with a FIPS/GEC source and that cross-check, never by name.
`--check-feeds` still lists the Irish FIPS codes, as the table does not carry
`FIPS`; the app resolves those 26 through the alias.

## Which regions count as coverage (`filedRegions`)

A place reads "no alerts" from MeteoAlarm only where a warning its country's
feed files could be placed; elsewhere it reads "not available".
`WxAlertRegions.filedRegions` lists, per country with bundled regions, the
geocode types, code series or codes its feed files; only those regions (and,
for Ireland, the county regions its filed FIPS codes alias to) count. It was
derived from the 38 api/v1 feeds saved on 2026-10-26 (their history reaches
back to 2026-10-21; the window is the full UTC days 2026-10-22 to 2026-10-25),
by these rules, where a *series* is a code less its last two characters
(`EI805` → `EI8`):

1. A feed with no warning recorded (CY, IS, MT, SK) is taken to file
   `EMMA_ID`, the only type carried for it.
2. A feed that files every area with its own polygon (SI) counts its regions
   as its footprint.
3. Otherwise a type counts when the feed filed one of its codes, limited to
   the series filed when a series of 4 or more carried codes is filed in full
   beside one never filed (IE `EMMA_ID`: `EI8` 21 of 21 filed, `IE0` and `IE8`
   none → `EI8` only; FR `NUTS3`: `FR1`–`FR8`, not the overseas `FRA`).
4. A feed that files the same codes on every full day, Green included, counts
   exactly those codes (it fires for BE, BG, DK and HU and restricts only
   Belgium, to `EMMA_ID` `BE004`, `BE801` and eight provincial `NUTS2`).
5. The codes of a superseded NUTS edition the feed never files, beside a
   current edition it files in full, do not count: Croatia files all 21 NUTS
   2021 county codes (`HR021`–`HR028`, `HR031`–`HR037`, `HR050`,
   `HR061`–`HR065`) and none of the 14 NUTS 2013 ones (`HR041`–`HR04E`), so
   only the 21 count (Stara Gradiška, inside only `HR04A`, is not covered).

Ireland also counts `FIPS` (all 26 county codes filed), i.e. its 26 county
regions through the alias table; its `IE80x` offshore regions do not count.

To re-derive: save every feed in `WxAlertRegions.feedSlugs` with the project
User-Agent (`weather-app/0.1 (github.com/wtp128pro/weather)`); for each
country tabulate, per geocode type, the codes its warnings' areas file over
the whole window and on each full UTC day (Green included), and which areas
carry their own polygon. Apply rules 1–5 to the codes the table carries for
that country, compare the result with the Swift literal, and update it
together with the pins in `filedRegionsTableIsConsistent`
(`WeatherCoreTests/Alerts/AlertRegionsTests.swift`). A sparse snapshot (few
warnings) is not evidence that a code is never filed; widen the window before
removing one.

## Known limits

- **Not carried:** polygon-only feeds (EE, LU, NO, SE, CH, UA, GB, IL: the
  warning carries its own polygon); `WARNCELLID` (DE, which the app takes from
  Bright Sky instead), `CISORP` (CZ also files every area as an `EMMA_ID` the
  geocodes file carries), `FIPS` (IE). On 2026-10-26 every Irish land area
  carried only `FIPS` codes, 26 in all (`EI01`–`EI31` with gaps); the app
  places them through the [FIPS alias table](#irish-fips-10-4-county-codes).
- **Irish coast:** a coastal place that the simplified county polygon misses
  but an `EI8xx` sea area contains (e.g. Howth harbour, Tory, Cape Clear) is
  covered by marine warnings only; a county land warning does not reach it
  (no nearest-region fallback). Killybegs, inside both `EI820` and County
  Donegal, gets both.
- **Croatia's EMMA_IDs** `HR011`–`HR031` are in no geocodes edition; each is
  filed beside a 2021 `NUTS3` code, which is what places it.
- **Simplification error:** a boundary moves by up to 0.004° (~450 m N–S,
  ~300 m E–W at 45° N). Dubrovnik's old town lies inside raw `EMMA_ID/HR007`
  but outside its simplified ring (it stays inside `NUTS3/HR037`). Points that
  close to a coast or border can miss or land in the neighbour; no buffering.
- **Source gaps:** Arlon (BE) lies in no raw MeteoAlarm `EMMA_ID` polygon; it is
  placed only by `NUTS2/BE34`.
- **Editions drift:** a new geocodes edition can drop codes as well as add
  them, and a feed can switch NUTS edition. Re-run `--check-feeds` on fresh
  feeds before updating the pins.
