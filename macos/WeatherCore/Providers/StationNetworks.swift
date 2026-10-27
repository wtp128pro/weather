// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationNetworks.swift - request builders and parsers of the keyless surface-
// observation networks blended by WxStationFusion. Pure: every parser takes
// response bytes and returns observations in °C, km/h, mm/h and percent; the
// app target (LiveStationFetcher) does the HTTP.
//
//   network      coverage                  cadence   source
//   METAR        worldwide airports        hourly    aviationweather.gov (NOAA AWC)
//   NWS ASOS     US airports               5 min     api.weather.gov
//   ECCC SWOB    Canada                    1-60 min  api.weather.gc.ca (MSC GeoMet)
//   IEM          US non-airport networks   5-60 min  mesonet.agron.iastate.edu
//   DWD SYNOP    Germany                   10 min    api.brightsky.dev
//   DMI          Denmark, Greenland        10 min    opendataapi.dmi.dk
//   FMI          Finland                   10 min    opendata.fmi.fi
//   SMHI         Sweden                    hourly    opendata-download-metobs.smhi.se
//   GeoSphere    Austria                   10 min    dataset.api.hub.geosphere.at
//   MeteoSwiss   Switzerland               10 min    data.geo.admin.ch (open data, per station)
//
// Trust (a prior, 0...1, multiplied by each site's measured health): 1 for the
// national/WMO-standard networks; partner, road-weather and hydrological sites
// less (their siting and maintenance vary), and their wind much less (many
// measure below 10 m).

import Foundation

/// Static metadata of one station (from a network's station list).
public struct WxStationSite: Sendable, Equatable, Codable {
    public var id: String
    public var name: String?
    public var lat: Double
    public var lon: Double
    public var elevM: Double?
    /// The network's own class of the station (e.g. DMI "Synop", SMHI "CORE"), if any.
    public var kind: String?

    public init(id: String, name: String? = nil, lat: Double, lon: Double, elevM: Double? = nil, kind: String? = nil) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.elevM = elevM
        self.kind = kind
    }
}

/// Request builders and parsers of the surface-observation networks.
public enum WxStationNetworks {
    // MARK: - Coverage

    /// The boxes (lat/lon, with a ~50 km margin beyond the borders, so places near a border also
    /// get the neighbour's stations) where a national network is queried.
    public static func covers(
        _ network: WxStationNetwork, lat: Double, lon: Double, region: WxRegion? = nil
    ) -> Bool {
        func box(_ la0: Double, _ la1: Double, _ lo0: Double, _ lo1: Double) -> Bool {
            lat >= la0 && lat <= la1 && lon >= lo0 && lon <= lo1
        }
        switch network {
        case .metar:
            return true
        case .nwsASOS, .iemMesonet:
            return region.map { $0 == .us } ?? WxGeo.inUSNWS(lat: lat, lon: lon)
        case .ecccSWOB:
            // the place is Canadian, or Canada lies within the pool radius of it
            if region == .canada || WxGeo.inCanada(lat: lat, lon: lon) {
                return true
            }
            let dLat = WxStationFusion.poolRadiusKm / 111.0
            let dLon = dLat / max(0.05, cos(lat * .pi / 180.0))
            for (a, b) in [(dLat, 0.0), (-dLat, 0.0), (0.0, dLon), (0.0, -dLon)] {
                if WxGeo.inCanada(lat: lat + a, lon: lon + b) {
                    return true
                }
            }
            return false
        case .dwdSYNOP:
            return box(46.8, 55.5, 5.2, 15.7)
        case .dmi:
            return box(54.0, 58.3, 7.2, 15.9) || box(61.2, 62.5, -8.0, -6.0)  // Denmark, Faroes
                // Greenland along its coasts, not Iceland, Baffin Island or Nunavik (no DMI station)
                || box(59.0, 67.0, -61.0, -30.0) || box(67.0, 75.0, -61.0, -10.0) || box(75.0, 84.0, -74.0, -10.0)
        case .fmi:
            return box(59.2, 70.5, 18.8, 32.0)
        case .smhi:
            return box(54.9, 69.5, 10.3, 24.6)
        case .geosphere:
            return box(45.9, 49.5, 8.9, 17.8)
        case .meteoSwiss:
            return box(45.4, 48.2, 5.5, 11.0)
        case .metOffice:
            return box(49.4, 61.3, -9.0, 2.4) || box(48.7, 49.8, -3.0, -1.6)  // UK, Channel Islands
        case .knmi:
            return box(50.3, 54.0, 2.8, 7.8)
        case .frost:
            return box(57.5, 71.6, 4.0, 31.6) || box(74.0, 81.0, 10.0, 34.0)  // Norway, Svalbard
        case .meteoFrance:
            return box(41.0, 51.5, -5.6, 10.0)  // metropolitan France, Corsica
        case .aemet:
            return box(35.6, 44.2, -9.8, 4.7) || box(27.4, 29.7, -18.5, -13.2)  // Spain, Balearics, Canaries
        }
    }

    // MARK: - Attribution

    /// One credit of the attribution line: the text shown and its link.
    public struct Credit: Sendable, Equatable {
        public let text: String
        public let url: String

        public init(text: String, url: String) {
            self.text = text
            self.url = url
        }
    }

    /// The source credit each network's terms ask for. NOAA and IEM data are public domain
    /// (credit appreciated); ECCC's Data Server End-use Licence gives the statement to use when its
    /// partners' data are mixed in; DWD, DMI, FMI, SMHI, GeoSphere, MeteoSwiss, KNMI and MET Norway
    /// publish under CC BY 4.0 (DWD: "Quelle: Deutscher Wetterdienst"; MeteoSwiss: "Source:
    /// MeteoSwiss"; KNMI: "Source: KNMI" linked to the dataset; MET Norway: "Data from The
    /// Norwegian Meteorological Institute"); the Met Office DataHub licence requires "Powered by Met
    /// Office data"; AEMET (Spanish reuse law) and Météo-France (Licence Ouverte 2.0) require the
    /// source and the date of the data, which `credits(for:newestReportS:)` adds.
    public static func credit(_ network: WxStationNetwork) -> Credit {
        switch network {
        case .metar:
            Credit(text: "Source: NOAA Aviation Weather Center", url: "https://aviationweather.gov/")
        case .nwsASOS:
            Credit(text: NWSProvider.attributionText, url: NWSProvider.attributionLink)
        case .ecccSWOB:
            Credit(text: "Contains information licenced under the Data Server End-use Licence of "
                       + "Environment and Climate Change Canada",
                   url: "https://eccc-msc.github.io/open-data/licence/readme_en/")
        case .iemMesonet:
            Credit(text: "Source: Iowa Environmental Mesonet, Iowa State University",
                   url: "https://mesonet.agron.iastate.edu/")
        case .dwdSYNOP:
            Credit(text: BrightSkyProvider.attributionText, url: BrightSkyProvider.attributionLink)
        case .dmi:
            Credit(text: "Source: Danish Meteorological Institute (DMI)", url: "https://www.dmi.dk/frie-data")
        case .fmi:
            Credit(text: "Source: Finnish Meteorological Institute", url: "https://en.ilmatieteenlaitos.fi/open-data")
        case .smhi:
            Credit(text: "Source: SMHI", url: "https://www.smhi.se/data")
        case .geosphere:
            Credit(text: "Source: GeoSphere Austria", url: "https://data.hub.geosphere.at/")
        case .meteoSwiss:
            Credit(text: "Source: MeteoSwiss", url: "https://www.meteoswiss.admin.ch/")
        case .metOffice:
            Credit(text: "Powered by Met Office data", url: "https://www.metoffice.gov.uk/")
        case .knmi:
            Credit(text: "Source: KNMI",
                   url: "https://dataplatform.knmi.nl/dataset/10-minute-in-situ-meteorological-observations-1-0")
        case .frost:
            Credit(text: "Data from The Norwegian Meteorological Institute", url: "https://frost.met.no/")
        case .meteoFrance:
            Credit(text: "Source: Météo-France", url: "https://portail-api.meteofrance.fr/")
        case .aemet:
            Credit(text: "Source: AEMET", url: "https://www.aemet.es/en/nota_legal")
        }
    }

    /// The networks published under CC BY 4.0, whose licence also asks for its link and a note
    /// that the data were changed.
    public static func isCCBY(_ network: WxStationNetwork) -> Bool {
        switch network {
        case .dwdSYNOP, .dmi, .fmi, .smhi, .geosphere, .meteoSwiss, .knmi, .frost: true
        case .metar, .nwsASOS, .ecccSWOB, .iemMesonet, .metOffice, .meteoFrance, .aemet: false
        }
    }

    /// The licence link and change note shown after the CC BY 4.0 credits.
    public static let ccByNote = Credit(
        text: "Station data CC BY 4.0, quality-checked and blended",
        url: "https://creativecommons.org/licenses/by/4.0/")

    /// The credits of the networks whose reports went into a reading, in network order, then the
    /// CC BY 4.0 note when one of them needs it. A network whose licence asks for the date of the
    /// data gets the time of its newest report, when given ("Source: AEMET, data of 14:00 UTC").
    public static func credits(
        for networks: Set<WxStationNetwork>, newestReportS: [WxStationNetwork: Int64] = [:]
    ) -> [Credit] {
        var out = WxStationNetwork.allCases.filter(networks.contains).map { network -> Credit in
            let c = credit(network)
            guard network == .aemet || network == .meteoFrance, let t = newestReportS[network] else { return c }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "d MMM HH:mm"
            return Credit(text: c.text + ", data of " + f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
                + " UTC", url: c.url)
        }
        if networks.contains(where: isCCBY) {
            out.append(ccByNote)
        }
        return out
    }

    // MARK: - Request builders

    /// AWC METARs of every airport within the fusion's search radius (latitude-corrected box).
    public static func metarURL(lat: Double, lon: Double) -> String {
        let b = WxStationFusion.searchBox(lat: lat, lon: lon, radiusKm: WxStationFusion.searchRadiusKm)
        return String(
            format: "https://aviationweather.gov/api/data/metar?bbox=%.4f,%.4f,%.4f,%.4f&format=json",
            b.minLat, b.minLon, b.maxLat, b.maxLon)
    }

    /// The latest api.weather.gov report of one station.
    public static func nwsLatestURL(stationID: String) -> String {
        "https://api.weather.gov/stations/\(stationID)/observations/latest"
    }

    /// ECCC SWOB reports of the last 70 minutes within the pool radius (property-filtered).
    public static func swobURL(lat: Double, lon: Double, nowS: Int64) -> String {
        let b = WxStationFusion.searchBox(lat: lat, lon: lon, radiusKm: WxStationFusion.poolRadiusKm)
        let properties = "stn_nam-value,tc_id-value,msc_id-value,data_pvdr-value,date_tm-value,air_temp,"
            + "dwpt_temp,rel_hum,avg_wnd_spd_10m_pst2mts,avg_wnd_spd_10m_pst10mts,max_wnd_spd_10m_pst10mts,"
            + "pcpn_amt_pst10mts,pcpn_amt_pst1hr"
        return String(
            format: "https://api.weather.gc.ca/collections/swob-realtime/items?f=json&limit=1000"
                + "&sortby=-date_tm-value&bbox=%.4f,%.4f,%.4f,%.4f&datetime=%@/..&properties=%@",
            b.minLon, b.minLat, b.maxLon, b.maxLat, isoUTC(nowS - 70 * 60), properties)
    }

    /// IEM current reports of the last hour of every network in one NWS forecast office area.
    public static func iemURL(wfo: String) -> String {
        "https://mesonet.agron.iastate.edu/api/1/currents.json?wfo=\(wfo)&minutes=75"
    }

    /// Bright Sky (DWD) sources within 50 km.
    public static func brightSkySourcesURL(lat: Double, lon: Double) -> String {
        String(format: "https://api.brightsky.dev/sources?lat=%.4f&lon=%.4f&max_dist=50000", lat, lon)
    }

    /// The latest 10-minute report of one Bright Sky source.
    public static func brightSkyCurrentURL(sourceID: Int) -> String {
        "https://api.brightsky.dev/current_weather?source_id=\(sourceID)"
    }

    /// DMI observations of the last 30 minutes within the pool radius (one feature per value).
    public static func dmiObservationsURL(lat: Double, lon: Double, nowS: Int64) -> String {
        let b = WxStationFusion.searchBox(lat: lat, lon: lon, radiusKm: WxStationFusion.poolRadiusKm)
        return String(
            format: "https://opendataapi.dmi.dk/v2/metObs/collections/observation/items?"
                + "bbox=%.4f,%.4f,%.4f,%.4f&datetime=%@/..&limit=10000",
            b.minLon, b.minLat, b.maxLon, b.maxLat, isoUTC(nowS - 30 * 60))
    }

    /// DMI station metadata within the search radius (names, heights, types).
    public static func dmiStationsURL(lat: Double, lon: Double) -> String {
        let b = WxStationFusion.searchBox(lat: lat, lon: lon, radiusKm: WxStationFusion.searchRadiusKm)
        return String(
            format: "https://opendataapi.dmi.dk/v2/metObs/collections/station/items?"
                + "bbox=%.4f,%.4f,%.4f,%.4f&limit=1000",
            b.minLon, b.minLat, b.maxLon, b.maxLat)
    }

    /// The FMI parameters requested, in order.
    public static let fmiParameters = ["t2m", "td", "rh", "ws_10min", "wg_10min", "ri_10min", "r_1h", "n_man", "wawa", "wd_10min"]

    /// FMI observations of the last 30 minutes within the pool radius (multipoint coverage).
    public static func fmiURL(lat: Double, lon: Double, nowS: Int64) -> String {
        let b = WxStationFusion.searchBox(lat: lat, lon: lon, radiusKm: WxStationFusion.poolRadiusKm)
        return String(
            format: "https://opendata.fmi.fi/wfs?service=WFS&version=2.0.0&request=getFeature"
                + "&storedquery_id=fmi::observations::weather::multipointcoverage"
                + "&bbox=%.4f,%.4f,%.4f,%.4f&starttime=%@&timestep=10&parameters=%@",
            b.minLon, b.minLat, b.maxLon, b.maxLat, isoUTC(nowS - 30 * 60), fmiParameters.joined(separator: ","))
    }

    /// SMHI parameters (all stations, latest hour): temperature, dewpoint, humidity, wind, gust,
    /// precipitation, total cloud, present weather.
    public static let smhiParameters = [1, 39, 6, 4, 21, 7, 16, 13, 3]

    public static func smhiURL(parameter: Int) -> String {
        "https://opendata-download-metobs.smhi.se/api/version/1.0/parameter/\(parameter)"
            + "/station-set/all/period/latest-hour/data.json"
    }

    /// GeoSphere Austria TAWES station list.
    public static let geosphereStationsURL =
        "https://dataset.api.hub.geosphere.at/v1/station/current/tawes-v1-10min/metadata"

    /// GeoSphere Austria TAWES current 10-minute values of the given (active) stations.
    public static func geosphereCurrentURL(stationIDs: [String]) -> String {
        "https://dataset.api.hub.geosphere.at/v1/station/current/tawes-v1-10min"
            + "?parameters=TL,TP,RF,FF,DD,FFX,RR&station_ids=" + stationIDs.joined(separator: ",")
    }

    /// MeteoSwiss open data (OGD SwissMetNet): the station list, and one station's 10-minute values
    /// of today and yesterday (the legacy all-station file VQHA80 is no longer filled).
    public static let meteoSwissStationsURL =
        "https://data.geo.admin.ch/ch.meteoschweiz.ogd-smn/ogd-smn_meta_stations.csv"

    public static func meteoSwissStationURL(abbr: String) -> String {
        let a = abbr.lowercased()
        return "https://data.geo.admin.ch/ch.meteoschweiz.ogd-smn/\(a)/ogd-smn_\(a)_t_now.csv"
    }

    /// Open-Meteo 90 m DEM elevations of up to 100 points (the same DEM as the place's elevation).
    public static func elevationURL(_ points: [(lat: Double, lon: Double)]) -> String {
        let lats = points.prefix(100).map { String(format: "%.4f", $0.lat) }.joined(separator: ",")
        let lons = points.prefix(100).map { String(format: "%.4f", $0.lon) }.joined(separator: ",")
        return "https://api.open-meteo.com/v1/elevation?latitude=\(lats)&longitude=\(lons)"
    }

    // MARK: - METAR

    /// AWC METAR JSON (an array of reports).
    public static func parseMETARs(_ data: Data) -> [WxStationObservation] {
        guard let array = json(data) as? [[String: Any]] else { return [] }
        return array.compactMap { r in
            guard let lat = num(r["lat"]), let lon = num(r["lon"]), let temp = num(r["temp"]) else {
                return nil
            }
            var cloudPct: Double? = nil
            if let layers = r["clouds"] as? [[String: Any]], !layers.isEmpty {
                cloudPct = randomOverlapCover(layers.compactMap { layer in
                    guard let cover = str(layer["cover"]) else { return nil }
                    return (cover, num(layer["base"]) ?? 5000)
                })
            } else if let cover = str(r["cover"]) {
                cloudPct = oktasCoverPercent(cover)
            }
            let wspd = num(r["wspd"])
            return WxStationObservation(
                network: .metar, id: str(r["icaoId"]) ?? "METAR", name: str(r["name"]),
                lat: lat, lon: lon, elevM: num(r["elev"]), obsTimeS: num(r["obsTime"]).map { Int64($0) },
                tempC: temp, dewpC: num(r["dewp"]),
                windKmh: wspd.flatMap { $0 >= 0 ? $0 * 1.852 : nil },
                gustKmh: num(r["wgst"]).flatMap { $0 >= 0 ? $0 * 1.852 : nil },
                windDirDeg: windFromDeg(r["wdir"], speed: wspd),  // "VRB" is not a number
                cloudPct: cloudPct,
                precipMmH: num(r["precip"]).flatMap { $0 >= 0 ? $0 * 25.4 : nil },
                wxString: str(r["wxString"]) ?? "")
        }
    }

    /// Effective visual sky cover (0...100%) of METAR-style cloud layers (cover code, base in
    /// feet) by radiative random overlap, `1 - ∏ (1 - α_k C_k)`, with high thin layers counted
    /// at reduced opacity (α = 0.72 from 12,000 ft, 0.30 from 18,000 ft).
    public static func randomOverlapCover(_ layers: [(cover: String, baseFt: Double)]) -> Double? {
        guard !layers.isEmpty else { return nil }
        var transmittance = 1.0
        for layer in layers {
            let rawPct = oktasCoverPercent(layer.cover)
            let alpha = layer.baseFt >= 18_000 ? 0.30 : (layer.baseFt >= 12_000 ? 0.72 : 1.0)
            transmittance *= 1.0 - max(0.0, min(1.0, rawPct * alpha / 100.0))
        }
        return max(0.0, min(100.0, 100.0 * (1.0 - transmittance)))
    }

    /// Cover percent of a METAR / NWS cover code (FEW 1-2 oktas, SCT 3-4, BKN 5-7, OVC 8).
    public static func oktasCoverPercent(_ code: String) -> Double {
        switch code.uppercased() {
        case "FEW": 18.0
        case "SCT": 44.0
        case "BKN": 75.0
        case "OVC", "OVX", "VV": 100.0
        default: 0.0  // CLR, SKC, CAVOK, NCD, NSC
        }
    }

    // MARK: - NWS ASOS latest

    /// One api.weather.gov latest report, positioned at its airport's METAR site. Values that
    /// MADIS quality control rejected or questioned (qualityControl X, Q, B) are dropped.
    public static func parseNWSLatest(_ data: Data, site: WxStationObservation) -> WxStationObservation? {
        guard let root = json(data) as? [String: Any], let p = root["properties"] as? [String: Any],
              let ts = parseISO8601(str(p["timestamp"]))
        else {
            return nil
        }
        func value(_ key: String) -> (v: Double, unit: String)? {
            guard let q = p[key] as? [String: Any], let v = num(q["value"]) else { return nil }
            if let qc = str(q["qualityControl"]), ["X", "Q", "B"].contains(qc) { return nil }
            return (v, str(q["unitCode"]) ?? "")
        }
        func kmh(_ key: String) -> Double? {
            guard let q = value(key), q.v >= 0 else { return nil }
            return q.unit.contains("m_s") ? q.v * 3.6 : q.v
        }
        guard let temp = value("temperature")?.v else { return nil }

        var cloudPct: Double? = nil
        if let layers = p["cloudLayers"] as? [[String: Any]], !layers.isEmpty {
            cloudPct = randomOverlapCover(layers.compactMap { layer in
                guard let amount = str(layer["amount"]) else { return nil }
                let baseM = num((layer["base"] as? [String: Any])?["value"]) ?? 1500
                return (amount, baseM * 3.28084)
            })
        }
        let rh = value("relativeHumidity")?.v
        let text = str(p["textDescription"])
        let condition = WxPresentWeather.condition(
            text: text, tempC: temp, wetBulbC: WxStationFusion.wetBulbC(tempC: temp, humidityPct: rh ?? 55),
            cloudPct: &cloudPct)
        let precip: Double? = value("precipitationLastHour").flatMap { q in
            guard q.v >= 0 else { return nil }
            return q.unit.hasSuffix(":m") ? q.v * 1000.0 : q.v
        }
        return WxStationObservation(
            network: .nwsASOS, id: site.id, name: site.name, lat: site.lat, lon: site.lon,
            elevM: value("elevation")?.v ?? site.elevM, obsTimeS: ts, tempC: temp,
            dewpC: value("dewpoint")?.v, humidityPct: rh, windKmh: kmh("windSpeed"), gustKmh: kmh("windGust"),
            windDirDeg: windFromDeg(value("windDirection")?.v, speed: kmh("windSpeed")),
            cloudPct: cloudPct, precipMmH: precip, condition: condition,
            reportsPresentWeather: condition != nil)
    }

    // MARK: - ECCC SWOB

    /// SWOB providers whose stations are WMO-standard (ECCC's own MSC network, NAV CANADA airports,
    /// National Defence); other providers (provincial road weather, ports, air-quality networks)
    /// are partner sites.
    static let swobFirstClassProviders: Set<String> = ["MSC", "NAV CANADA", "DND"]

    /// The newest report of every SWOB station in the response.
    public static func parseSWOB(_ data: Data) -> [WxStationObservation] {
        guard let root = json(data) as? [String: Any], let features = root["features"] as? [[String: Any]] else {
            return []
        }
        var latest: [String: WxStationObservation] = [:]
        for f in features {
            guard let p = f["properties"] as? [String: Any],
                  let coords = (f["geometry"] as? [String: Any])?["coordinates"] as? [Any], coords.count >= 2,
                  let lon = num(coords[0]), let lat = num(coords[1]),
                  let ts = parseISO8601(str(p["date_tm-value"])),
                  let temp = num(p["air_temp"]), temp >= -60, temp <= 50
            else {
                continue
            }
            let name = str(p["stn_nam-value"])
            let key = str(p["msc_id-value"]) ?? str(p["tc_id-value"]) ?? name ?? String(format: "%.4f,%.4f", lat, lon)
            if let known = latest[key], (known.obsTimeS ?? 0) >= ts {
                continue
            }
            let provider = (str(p["data_pvdr-value"]) ?? "MSC").uppercased()
            let firstClass = swobFirstClassProviders.contains(provider)
            let precip: Double? = num(p["pcpn_amt_pst10mts"]).map { max(0.0, $0) * 6.0 }
                ?? num(p["pcpn_amt_pst1hr"]).map { max(0.0, $0) }
            // speed and direction from the same averaging window: 2 minutes, else 10 minutes
            let wind: (kmh: Double, dir: Any?)? =
                num(p["avg_wnd_spd_10m_pst2mts"]).map { ($0, p["avg_wnd_dir_10m_pst2mts"]) }
                ?? num(p["avg_wnd_spd_10m_pst10mts"]).map { ($0, p["avg_wnd_dir_10m_pst10mts"]) }
            latest[key] = WxStationObservation(
                network: .ecccSWOB, id: str(p["tc_id-value"]) ?? key, name: name, lat: lat, lon: lon,
                elevM: coords.count >= 3 ? num(coords[2]) : nil, obsTimeS: ts, tempC: temp,
                dewpC: num(p["dwpt_temp"]).flatMap { $0 <= temp + 0.5 ? $0 : nil },
                humidityPct: num(p["rel_hum"]).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
                windKmh: wind.flatMap { $0.kmh >= 0 ? $0.kmh : nil },
                gustKmh: num(p["max_wnd_spd_10m_pst10mts"]).flatMap { $0 >= 0 ? $0 : nil },
                windDirDeg: windFromDeg(wind?.dir, speed: wind?.kmh),
                precipMmH: precip,
                trust: firstClass ? 1.0 : 0.6, windTrust: firstClass ? 1.0 : 0.35)
        }
        return Array(latest.values)
    }

    // MARK: - Iowa Environmental Mesonet

    /// Prior trust (temperature, wind) of an IEM network, nil for networks that are skipped:
    /// airports (the METAR feed has them) and daily cooperative reports.
    public static func iemTrust(network: String) -> (temp: Double, wind: Double)? {
        let n = network.uppercased()
        if n.hasSuffix("ASOS") || n.hasSuffix("AWOS") || n.hasSuffix("_COOP") || n.hasSuffix("COCORAHS") {
            return nil
        }
        if n == "USCRN" { return (1.0, 0.8) }  // NOAA Climate Reference Network
        if n == "SCAN" || n == "ISUSM" { return (0.85, 0.6) }  // research-grade soil-climate sites
        if n.hasSuffix("_RWIS") { return (0.6, 0.35) }  // state DOT road weather
        if n.hasSuffix("_DCP") { return (0.5, 0.3) }  // NWS HADS hydro-met gauges
        return (0.5, 0.3)
    }

    /// IEM `currents.json` of the non-airport networks.
    public static func parseIEM(_ data: Data) -> [WxStationObservation] {
        guard let root = json(data) as? [String: Any], let rows = root["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let network = str(r["network"]), let trust = iemTrust(network: network),
                  let id = str(r["station"]), let lat = num(r["lat"]), let lon = num(r["lon"]),
                  let tmpf = num(r["tmpf"]), tmpf > -80, tmpf < 140,
                  let ts = parseISO8601(str(r["utc_valid"]))
            else {
                return nil
            }
            let f2c = { (f: Double) in (f - 32.0) * 5.0 / 9.0 }
            return WxStationObservation(
                network: .iemMesonet, id: id, name: str(r["name"]), lat: lat, lon: lon, obsTimeS: ts,
                tempC: f2c(tmpf), dewpC: num(r["dwpf"]).map(f2c),
                humidityPct: num(r["relh"]).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
                windKmh: num(r["sknt"]).flatMap { $0 >= 0 ? $0 * 1.852 : nil },
                gustKmh: num(r["gust"]).flatMap { $0 >= 0 ? $0 * 1.852 : nil },
                windDirDeg: windFromDeg(r["drct"], speed: num(r["sknt"])),
                precipMmH: num(r["phour"]).flatMap { $0 >= 0 ? $0 * 25.4 : nil },
                trust: trust.temp, windTrust: trust.wind)
        }
    }

    // MARK: - DWD SYNOP (Bright Sky)

    /// One live Bright Sky SYNOP source.
    public struct BrightSkySource: Sendable, Equatable {
        public var id: Int
        public var site: WxStationSite
        public var distanceKm: Double
    }

    /// The live SYNOP sources (newest record within 3 h), one per DWD station, nearest first.
    public static func parseBrightSkySources(_ data: Data, nowS: Int64) -> [BrightSkySource] {
        guard let root = json(data) as? [String: Any], let sources = root["sources"] as? [[String: Any]] else {
            return []
        }
        var best: [String: (source: BrightSkySource, last: Int64)] = [:]
        for s in sources {
            guard str(s["observation_type"]) == "synop", let id = num(s["id"]).map({ Int($0) }),
                  let lat = num(s["lat"]), let lon = num(s["lon"]),
                  let last = parseISO8601(str(s["last_record"])), nowS - last <= 3 * 3600
            else {
                continue
            }
            let station = str(s["dwd_station_id"]) ?? str(s["wmo_station_id"]) ?? String(id)
            let site = WxStationSite(
                id: str(s["wmo_station_id"]) ?? station, name: str(s["station_name"]), lat: lat, lon: lon,
                elevM: num(s["height"]))
            let source = BrightSkySource(id: id, site: site, distanceKm: (num(s["distance"]) ?? 0) / 1000.0)
            if let known = best[station], known.last >= last {
                continue
            }
            best[station] = (source, last)
        }
        return best.values.map(\.source).sorted { $0.distanceKm < $1.distanceKm }
    }

    /// One Bright Sky `current_weather` record. Values Bright Sky filled in from another station
    /// (`fallback_source_ids`) are dropped: they do not belong to this site.
    public static func parseBrightSkyCurrent(_ data: Data, source: BrightSkySource) -> WxStationObservation? {
        guard let root = json(data) as? [String: Any], var w = root["weather"] as? [String: Any] else { return nil }
        if let fallback = w["fallback_source_ids"] as? [String: Any] {
            for key in fallback.keys {
                w[key] = nil
            }
        }
        guard let temp = num(w["temperature"]) else { return nil }
        let rh = num(w["relative_humidity"])
        var cloudPct = num(w["cloud_cover"]).map { max(0.0, min(100.0, $0)) }
        let conditionText = str(w["condition"])
        // "dry" carries no sky state; the icon (cloudy, partly-cloudy-day, ...) does
        let text = (conditionText == nil || conditionText == "dry") ? str(w["icon"]) : conditionText
        let condition = WxPresentWeather.condition(
            text: text?.replacingOccurrences(of: "-", with: " "), tempC: temp,
            wetBulbC: WxStationFusion.wetBulbC(tempC: temp, humidityPct: rh ?? 55), cloudPct: &cloudPct)
        // speed and direction from the same averaging window: 10 minutes, else 30 minutes
        let wind: (kmh: Double, dir: Any?)? =
            num(w["wind_speed_10"]).map { ($0, w["wind_direction_10"]) }
            ?? num(w["wind_speed_30"]).map { ($0, w["wind_direction_30"]) }
        return WxStationObservation(
            network: .dwdSYNOP, id: source.site.id, name: source.site.name, lat: source.site.lat,
            lon: source.site.lon, elevM: source.site.elevM, obsTimeS: parseISO8601(str(w["timestamp"])),
            tempC: temp, dewpC: num(w["dew_point"]), humidityPct: rh,
            windKmh: wind.flatMap { $0.kmh >= 0 ? $0.kmh : nil },
            gustKmh: (num(w["wind_gust_speed_10"]) ?? num(w["wind_gust_speed_30"])).flatMap { $0 >= 0 ? $0 : nil },
            windDirDeg: windFromDeg(wind?.dir, speed: wind?.kmh),
            cloudPct: cloudPct,
            precipMmH: num(w["precipitation_10"]).map { max(0.0, $0) * 6.0 } ?? num(w["precipitation_60"]),
            condition: condition, reportsPresentWeather: conditionText != nil)
    }

    // MARK: - DMI

    /// DMI station metadata by station id (active stations only).
    public static func parseDMIStations(_ data: Data) -> [String: WxStationSite] {
        guard let root = json(data) as? [String: Any], let features = root["features"] as? [[String: Any]] else {
            return [:]
        }
        var out: [String: WxStationSite] = [:]
        for f in features {
            guard let p = f["properties"] as? [String: Any], let id = str(p["stationId"]),
                  str(p["status"]) != "Inactive",
                  let coords = (f["geometry"] as? [String: Any])?["coordinates"] as? [Any], coords.count >= 2,
                  let lon = num(coords[0]), let lat = num(coords[1])
            else {
                continue
            }
            out[id] = WxStationSite(
                id: id, name: str(p["name"]), lat: lat, lon: lon, elevM: num(p["stationHeight"]), kind: str(p["type"]))
        }
        return out
    }

    /// DMI metObs features (one per station, parameter and time) folded into one report per
    /// station: the newest value of every parameter.
    public static func parseDMIObservations(_ data: Data, stations: [String: WxStationSite]) -> [WxStationObservation] {
        guard let root = json(data) as? [String: Any], let features = root["features"] as? [[String: Any]] else {
            return []
        }
        struct Fold {
            var lat = Double.nan, lon = Double.nan
            var values: [String: (t: Int64, v: Double)] = [:]
        }
        var folds: [String: Fold] = [:]
        for f in features {
            guard let p = f["properties"] as? [String: Any], let id = str(p["stationId"]),
                  let param = str(p["parameterId"]), let v = num(p["value"]),
                  let t = parseISO8601(str(p["observed"]))
            else {
                continue
            }
            var fold = folds[id] ?? Fold()
            if let coords = (f["geometry"] as? [String: Any])?["coordinates"] as? [Any], coords.count >= 2,
               let lon = num(coords[0]), let lat = num(coords[1])
            {
                fold.lat = lat
                fold.lon = lon
            }
            if let known = fold.values[param], known.t >= t {
                folds[id] = fold
                continue
            }
            fold.values[param] = (t, v)
            folds[id] = fold
        }
        return folds.compactMap { id, fold in
            guard let temp = fold.values["temp_dry"] else { return nil }
            let site = stations[id]
            let lat = site?.lat ?? fold.lat
            let lon = site?.lon ?? fold.lon
            guard lat.isFinite, lon.isFinite else { return nil }
            let v = { (k: String) in fold.values[k]?.v }
            let speed = fold.values["wind_speed"]
            let dir = fold.values["wind_dir"].flatMap { $0.t == speed?.t ? $0.v : nil }  // same report only
            let rh = v("humidity")
            let weather = v("weather").map { Int($0) }
            let condition = weather.flatMap {
                WxPresentWeather.condition(
                    nationalCode: $0, wetBulbC: WxStationFusion.wetBulbC(tempC: temp.v, humidityPct: rh ?? 55))
            }
            let cloud = v("cloud_cover").flatMap { $0 >= 0 && $0 <= 100 ? $0 : nil }
            let synop = site?.kind?.lowercased() == "synop"
            return WxStationObservation(
                network: .dmi, id: id, name: site?.name, lat: lat, lon: lon, elevM: site?.elevM,
                obsTimeS: temp.t, tempC: temp.v, dewpC: v("temp_dew"), humidityPct: rh,
                windKmh: v("wind_speed").flatMap { $0 >= 0 ? $0 * 3.6 : nil },
                gustKmh: v("wind_max").flatMap { $0 >= 0 ? $0 * 3.6 : nil },
                windDirDeg: windFromDeg(dir, speed: speed?.v), cloudPct: cloud,
                precipMmH: v("precip_past10min").map { max(0.0, $0) * 6.0 } ?? v("precip_past1h"),
                condition: condition, reportsPresentWeather: weather != nil,
                trust: synop ? 1.0 : 0.9)
        }
    }

    // MARK: - FMI

    /// FMI `fmi::observations::weather::multipointcoverage` XML: the newest row with a temperature
    /// of every station. Columns follow `swe:field` order; rows follow `gmlcov:positions`
    /// ("lat lon unixtime" per row).
    public static func parseFMI(_ data: Data) -> [WxStationObservation] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let fields = matches(#"<swe:field name="([^"]+)""#, in: text).map { $0[0] }
        guard !fields.isEmpty,
              let positionsText = matches(#"<gmlcov:positions>([^<]*)</gmlcov:positions>"#, in: text).first?[0],
              let valuesText = matches(
                #"<gml:doubleOrNilReasonTupleList>([^<]*)</gml:doubleOrNilReasonTupleList>"#, in: text).first?[0]
        else {
            return []
        }
        // station points: id, name, position
        var sites: [String: WxStationSite] = [:]
        for m in matches(
            #"<gml:Point gml:id="point-([^"]+)"[^>]*>\s*<gml:name>([^<]*)</gml:name>\s*<gml:pos>\s*([-0-9.]+)\s+([-0-9.]+)\s*</gml:pos>"#,
            in: text)
        {
            guard let lat = Double(m[2]), let lon = Double(m[3]) else { continue }
            sites[String(format: "%.5f %.5f", lat, lon)] = WxStationSite(
                id: m[0], name: decodeXMLEntities(m[1]), lat: lat, lon: lon)
        }
        let positions = positionsText.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        let values = valuesText.split(whereSeparator: \.isWhitespace).map { Double($0) ?? .nan }
        let rows = min(positions.count / 3, values.count / fields.count)
        func column(_ name: String) -> Int? { fields.firstIndex(of: name) }
        var newest: [String: (t: Int64, row: Int)] = [:]
        for row in 0..<rows {
            guard let tCol = column("t2m"), values[row * fields.count + tCol].isFinite else { continue }
            let key = String(format: "%.5f %.5f", positions[row * 3], positions[row * 3 + 1])
            let t = Int64(positions[row * 3 + 2])
            if let known = newest[key], known.t >= t { continue }
            newest[key] = (t, row)
        }
        return newest.compactMap { key, best in
            let lat = positions[best.row * 3], lon = positions[best.row * 3 + 1]
            let site = sites[key] ?? WxStationSite(id: key, lat: lat, lon: lon)
            func v(_ name: String) -> Double? {
                guard let c = column(name) else { return nil }
                let x = values[best.row * fields.count + c]
                return x.isFinite ? x : nil
            }
            guard let temp = v("t2m") else { return nil }
            let rh = v("rh")
            let wawa = v("wawa").map { Int($0) }
            let condition = wawa.flatMap {
                WxPresentWeather.condition(wawa: $0, wetBulbC: WxStationFusion.wetBulbC(tempC: temp, humidityPct: rh ?? 55))
            }
            return WxStationObservation(
                network: .fmi, id: site.id, name: site.name, lat: lat, lon: lon, obsTimeS: best.t, tempC: temp,
                dewpC: v("td"), humidityPct: rh,
                windKmh: v("ws_10min").flatMap { $0 >= 0 ? $0 * 3.6 : nil },
                gustKmh: v("wg_10min").flatMap { $0 >= 0 ? $0 * 3.6 : nil },
                windDirDeg: windFromDeg(v("wd_10min"), speed: v("ws_10min")),
                cloudPct: v("n_man").flatMap { $0 >= 0 && $0 <= 8 ? $0 / 8.0 * 100.0 : nil },
                precipMmH: v("ri_10min").flatMap { $0 >= 0 ? $0 : nil } ?? v("r_1h").flatMap { $0 >= 0 ? $0 : nil },
                condition: condition, reportsPresentWeather: wawa != nil)
        }
    }

    // MARK: - SMHI

    /// SMHI latest-hour responses (one per parameter of `smhiParameters`) folded into one report
    /// per station. Each response holds every station of Sweden.
    public static func parseSMHI(_ responses: [Int: Data]) -> [WxStationObservation] {
        struct Fold {
            var site: WxStationSite
            var values: [Int: (t: Int64, v: Double)] = [:]
        }
        var folds: [String: Fold] = [:]
        for (parameter, data) in responses {
            guard let root = json(data) as? [String: Any], let stations = root["station"] as? [[String: Any]] else {
                continue
            }
            for s in stations {
                guard let key = str(s["key"]), let lat = num(s["latitude"]), let lon = num(s["longitude"]),
                      let values = s["value"] as? [[String: Any]],
                      let newest = values.compactMap({ e -> (Int64, Double)? in
                          guard let ms = num(e["date"]), let v = num(e["value"]) else { return nil }
                          return (Int64(ms / 1000.0), v)
                      }).max(by: { $0.0 < $1.0 })
                else {
                    continue
                }
                var fold = folds[key] ?? Fold(site: WxStationSite(
                    id: key, name: str(s["name"]), lat: lat, lon: lon, elevM: num(s["height"]),
                    kind: str(s["measuringStations"])))
                fold.values[parameter] = newest
                folds[key] = fold
            }
        }
        return folds.values.compactMap { fold in
            guard let temp = fold.values[1] else { return nil }
            let v = { (p: Int) in fold.values[p]?.v }
            let dir = fold.values[3].flatMap { $0.t == fold.values[4]?.t ? $0.v : nil }  // same report as speed (4)
            let rh = v(6)
            let weather = v(13).map { Int($0) }
            let condition = weather.flatMap {
                WxPresentWeather.condition(
                    nationalCode: $0, wetBulbC: WxStationFusion.wetBulbC(tempC: temp.v, humidityPct: rh ?? 55))
            }
            return WxStationObservation(
                network: .smhi, id: fold.site.id, name: fold.site.name, lat: fold.site.lat, lon: fold.site.lon,
                elevM: fold.site.elevM, obsTimeS: temp.t, tempC: temp.v, dewpC: v(39), humidityPct: rh,
                windKmh: v(4).flatMap { $0 >= 0 ? $0 * 3.6 : nil }, gustKmh: v(21).flatMap { $0 >= 0 ? $0 * 3.6 : nil },
                windDirDeg: windFromDeg(dir, speed: v(4)),
                cloudPct: v(16).flatMap { $0 >= 0 && $0 <= 100 ? $0 : nil },
                precipMmH: v(7).flatMap { $0 >= 0 ? $0 : nil },
                condition: condition, reportsPresentWeather: weather != nil,
                trust: fold.site.kind?.uppercased() == "CORE" ? 1.0 : 0.9)
        }
    }

    // MARK: - GeoSphere Austria

    /// The active TAWES stations.
    public static func parseGeoSphereStations(_ data: Data) -> [WxStationSite] {
        guard let root = json(data) as? [String: Any], let stations = root["stations"] as? [[String: Any]] else {
            return []
        }
        return stations.compactMap { s in
            guard (s["is_active"] as? Bool) != false, let id = str(s["id"]),
                  let lat = num(s["lat"]), let lon = num(s["lon"])
            else {
                return nil
            }
            return WxStationSite(id: id, name: str(s["name"]), lat: lat, lon: lon, elevM: num(s["altitude"]))
        }
    }

    /// TAWES current values (TL, TP, RF, FF, DD, FFX, RR) of the requested stations.
    public static func parseGeoSphereCurrent(_ data: Data, stations: [String: WxStationSite]) -> [WxStationObservation] {
        guard let root = json(data) as? [String: Any], let features = root["features"] as? [[String: Any]],
              let time = parseISO8601((root["timestamps"] as? [Any])?.last.flatMap { str($0) })
        else {
            return []
        }
        return features.compactMap { f in
            guard let p = f["properties"] as? [String: Any], let id = str(p["station"]),
                  let params = p["parameters"] as? [String: Any]
            else {
                return nil
            }
            func v(_ key: String) -> Double? {
                ((params[key] as? [String: Any])?["data"] as? [Any])?.last.flatMap { num($0) }
            }
            let coords = (f["geometry"] as? [String: Any])?["coordinates"] as? [Any]
            guard let temp = v("TL"),
                  let lat = stations[id]?.lat ?? coords.flatMap({ $0.count >= 2 ? num($0[1]) : nil }),
                  let lon = stations[id]?.lon ?? coords.flatMap({ $0.count >= 2 ? num($0[0]) : nil })
            else {
                return nil
            }
            return WxStationObservation(
                network: .geosphere, id: id, name: stations[id]?.name, lat: lat, lon: lon,
                elevM: stations[id]?.elevM, obsTimeS: time, tempC: temp, dewpC: v("TP"),
                humidityPct: v("RF").flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
                windKmh: v("FF").flatMap { $0 >= 0 ? $0 * 3.6 : nil },
                gustKmh: v("FFX").flatMap { $0 >= 0 ? $0 * 3.6 : nil },
                windDirDeg: windFromDeg(v("DD"), speed: v("FF")),
                precipMmH: v("RR").map { max(0.0, $0) * 6.0 })
        }
    }

    // MARK: - MeteoSwiss

    /// The SwissMetNet station list by abbreviation (semicolon CSV, Latin-1 or UTF-8).
    public static func parseMeteoSwissStations(_ data: Data) -> [String: WxStationSite] {
        let rows = csvRows(data)
        guard let header = rows.first else { return [:] }
        func col(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let abbr = col("station_abbr"), let latC = col("station_coordinates_wgs84_lat"),
              let lonC = col("station_coordinates_wgs84_lon")
        else {
            return [:]
        }
        let nameC = col("station_name"), elevC = col("station_height_masl"), ownerC = col("station_dataowner")
        var out: [String: WxStationSite] = [:]
        for row in rows.dropFirst() where row.count > max(abbr, latC, lonC) {
            guard let lat = Double(row[latC]), let lon = Double(row[lonC]), !row[abbr].isEmpty else { continue }
            out[row[abbr]] = WxStationSite(
                id: row[abbr], name: nameC.flatMap { $0 < row.count ? row[$0] : nil }, lat: lat, lon: lon,
                elevM: elevC.flatMap { $0 < row.count ? Double(row[$0]) : nil },
                kind: ownerC.flatMap { $0 < row.count ? row[$0] : nil })
        }
        return out
    }

    /// The newest row with a temperature of one station's 10-minute file (UTC "dd.MM.yyyy HH:mm";
    /// the newest row is often still empty).
    public static func parseMeteoSwissStation(_ data: Data, site: WxStationSite) -> WxStationObservation? {
        let rows = csvRows(data)
        guard let header = rows.first, let timeC = header.firstIndex(of: "reference_timestamp"),
              let tempC = header.firstIndex(of: "tre200s0")
        else {
            return nil
        }
        func col(_ name: String) -> Int? { header.firstIndex(of: name) }
        for row in rows.dropFirst().reversed() {
            guard row.count == header.count, let temp = Double(row[tempC]), let t = parseSwissUTC(row[timeC]) else {
                continue
            }
            func v(_ name: String) -> Double? { col(name).flatMap { Double(row[$0]) } }
            // Every SwissMetNet station is MeteoSwiss-operated ("MeteoSchweiz", some with SLF).
            return WxStationObservation(
                network: .meteoSwiss, id: site.id, name: site.name, lat: site.lat, lon: site.lon,
                elevM: site.elevM, obsTimeS: t, tempC: temp, dewpC: v("tde200s0"),
                humidityPct: v("ure200s0").flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
                windKmh: v("fu3010z0").flatMap { $0 >= 0 ? $0 : nil },
                gustKmh: v("fu3010z1").flatMap { $0 >= 0 ? $0 : nil },
                windDirDeg: windFromDeg(v("dkl010z0"), speed: v("fu3010z0")),
                precipMmH: v("rre150z0").map { max(0.0, $0) * 6.0 })
        }
        return nil
    }

    /// "dd.MM.yyyy HH:mm" UTC (MeteoSwiss open data).
    static func parseSwissUTC(_ text: String) -> Int64? {
        let parts = text.split(whereSeparator: { $0 == "." || $0 == " " || $0 == ":" }).map(String.init)
        guard parts.count == 5, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return WxTime.parseISO8601("\(parts[2])-\(parts[1])-\(parts[0])T\(parts[3]):\(parts[4]):00Z")
    }

    // MARK: - Open-Meteo elevation

    /// The `elevation` array of an Open-Meteo elevation response.
    public static func parseElevations(_ data: Data) -> [Double] {
        guard let root = json(data) as? [String: Any], let list = root["elevation"] as? [Any] else { return [] }
        return list.map { num($0) ?? .nan }
    }

    // MARK: - Helpers

    static func json(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// A finite number from a JSON number or numeric string (not a boolean).
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite {
            return d
        }
        return nil
    }

    /// The mean direction the wind blows FROM, degrees true in 0..<360 (360 is north, stored as 0).
    /// Nil when the paired speed is calm (0) or unknown, the value is not a number (METAR "VRB"),
    /// or it lies outside 0...360.
    static func windFromDeg(_ v: Any?, speed: Double?) -> Double? {
        guard let speed, speed > 0, let deg = num(v), deg >= 0, deg <= 360 else { return nil }
        return deg == 360 ? 0 : deg
    }

    /// A non-empty string from a JSON string or number.
    static func str(_ v: Any?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return n.stringValue
        }
        return nil
    }

    /// ISO 8601 UTC, also without seconds ("2026-10-25T19:40+00:00", GeoSphere) or with an offset
    /// without a colon ("2025-05-13T10:00:00+0000", AEMET).
    public static func parseISO8601(_ text: String?) -> Int64? {
        guard var t = text else { return nil }
        if let s = WxTime.parseISO8601(t) {
            return s
        }
        if t.count >= 5, let sign = t.dropLast(4).last, sign == "+" || sign == "-",
           t.suffix(4).allSatisfy(\.isNumber)
        {
            t.insert(":", at: t.index(t.endIndex, offsetBy: -2))
            if let s = WxTime.parseISO8601(t) {
                return s
            }
        }
        let chars = Array(t)
        if chars.count >= 16, chars[13] == ":", chars.count == 16 || chars[16] != ":" {
            t.insert(contentsOf: ":00", at: t.index(t.startIndex, offsetBy: 16))
            return WxTime.parseISO8601(t)
        }
        return nil
    }

    static func isoUTC(_ s: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(s)))
    }

    /// Capture groups of every match of `pattern`.
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    static func decodeXMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Semicolon-separated rows (double-quoted fields may hold semicolons); UTF-8, else Latin-1.
    static func csvRows(_ data: Data) -> [[String]] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        var rows: [[String]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var fields: [String] = []
            var field = ""
            var quoted = false
            for ch in line {
                if ch == "\"" {
                    quoted.toggle()
                } else if ch == ";" && !quoted {
                    fields.append(field.trimmingCharacters(in: .whitespaces))
                    field = ""
                } else {
                    field.append(ch)
                }
            }
            fields.append(field.trimmingCharacters(in: .whitespaces))
            rows.append(fields)
        }
        return rows
    }
}

/// Present-weather decoding: WMO code tables 4677 (manned ww) and 4680 (automatic wawa), the
/// 100+wawa convention of DMI and SMHI, and plain-text descriptions (NWS, DWD). nil means "no
/// precipitation, fog or thunder now" (a reporting site's "no weather").
public enum WxPresentWeather {
    /// WMO 4677 (ww, manned observations).
    public static func condition(ww: Int) -> WxCondition? {
        switch ww {
        case 11, 12: .fog  // shallow fog
        case 17, 19: .thunderstorm  // thunder without precipitation, funnel cloud
        case 41...49: .fog
        case 50...55: .drizzle
        case 56, 57: .sleet  // freezing drizzle
        case 58: .lightRain  // drizzle and rain, slight
        case 59: .rain
        case 60, 61: .lightRain
        case 62, 63: .rain
        case 64, 65: .heavyRain
        case 66...69: .sleet  // freezing rain, rain and snow
        case 70...75, 77, 78: .snow
        case 79: .sleet  // ice pellets
        case 80, 81: .showers
        case 82: .heavyRain
        case 83, 84: .sleet  // rain and snow showers
        case 85, 86: .snow
        case 87...90: .sleet  // snow pellets, hail
        case 91: .lightRain  // rain after a thunderstorm
        case 92: .rain
        case 93, 94: .snow
        case 95...99: .thunderstorm
        default: nil
        }
    }

    /// WMO 4680 (wawa, automatic stations). Precipitation of unknown type (40-42, 80) takes its
    /// phase from the wet-bulb temperature.
    public static func condition(wawa: Int, wetBulbC: Double?) -> WxCondition? {
        let frozen = (wetBulbC ?? 5.0) <= 0.8
        switch wawa {
        case 30...35: return .fog
        case 40: return frozen ? .snow : .rain
        case 41: return frozen ? .snow : .rain
        case 42: return frozen ? .snow : .heavyRain
        case 50...53: return .drizzle
        case 54...56: return .sleet  // freezing drizzle
        case 57: return .lightRain  // drizzle and rain, slight
        case 58: return .rain
        case 60, 62: return .rain
        case 61: return .lightRain
        case 63: return .heavyRain
        case 64...68: return .sleet  // freezing rain, rain and snow
        case 70...73, 77, 78: return .snow
        case 74...76: return .sleet  // ice pellets
        case 80: return frozen ? .snow : .showers
        case 81, 82: return .showers
        case 83, 84: return .heavyRain
        case 85...87: return .snow
        case 89: return .sleet  // hail
        case 90...96, 99: return .thunderstorm
        default: return nil
        }
    }

    /// The DMI / SMHI convention: 100...199 are 4680 + 100, 0...99 are 4677.
    public static func condition(nationalCode code: Int, wetBulbC: Double?) -> WxCondition? {
        if code >= 100 && code <= 199 {
            return condition(wawa: code - 100, wetBulbC: wetBulbC)
        }
        return code >= 0 && code <= 99 ? condition(ww: code) : nil
    }

    /// A plain-text description ("Light Rain and Fog", "partly cloudy day"); a sky description
    /// also fills `cloudPct` when it is nil. nil for an empty or unknown text.
    public static func condition(
        text: String?, tempC: Double, wetBulbC: Double, cloudPct: inout Double?
    ) -> WxCondition? {
        guard let text = text?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.contains("thunder") || text.contains("t-storm") {
            return .thunderstorm
        }
        // "freezing fog" is fog (below), not freezing precipitation
        if text.contains("freezing rain") || text.contains("freezing drizzle") || text.contains("sleet")
            || text.contains("ice pellets") || text.contains("hail")
        {
            return .sleet
        }
        if text.contains("snow") || text.contains("flurries") || text.contains("blizzard") {
            return wetBulbC <= 0.8 ? .snow : (wetBulbC <= 2.0 ? .sleet : .rain)
        }
        if text.contains("heavy rain") {
            return .heavyRain
        }
        if text.contains("shower") {
            return .showers
        }
        if text.contains("light rain") {
            return .lightRain
        }
        if text.contains("rain") {
            return tempC <= -0.5 ? .sleet : .rain
        }
        if text.contains("drizzle") {
            return .drizzle
        }
        if text.contains("fog") {
            return .fog
        }
        if text.contains("mostly clear") || text.contains("mostly sunny") || text.contains("few clouds") {
            if cloudPct == nil { cloudPct = 22.0 }
            return .mostlyClear
        }
        // before "sunny": the NWS hourly forecast's "Partly Sunny" is partly cloudy, not clear
        if text.contains("partly cloudy") || text.contains("partly sunny") {
            if cloudPct == nil { cloudPct = 48.0 }
            return .partlyCloudy
        }
        if text.contains("clear") || text.contains("sunny") || text.contains("fair") {
            if cloudPct == nil { cloudPct = 5.0 }
            return .clear
        }
        if text.contains("mostly cloudy") {
            if cloudPct == nil { cloudPct = 76.0 }
            return .mostlyCloudy
        }
        if text.contains("overcast") || text.contains("cloudy") {
            if cloudPct == nil { cloudPct = 95.0 }
            return .overcast
        }
        return nil
    }
}
