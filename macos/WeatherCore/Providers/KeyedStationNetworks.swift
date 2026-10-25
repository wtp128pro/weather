// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// KeyedStationNetworks.swift - request builders and parsers of the national
// networks that need the user's own (free) key, entered in Settings > Stations:
//
//   network        coverage         cadence   source, auth
//   AEMET          Spain            hourly    opendata.aemet.es; header "api_key"; two steps
//                                             (the first answer names a data URL valid ~5 min)
//   MET Norway     Norway           10 min    frost.met.no; HTTP Basic, client ID, no password
//   (Frost)
//   KNMI           Netherlands      10 min    api.dataplatform.knmi.nl EDR API (CoverageJSON);
//                                             header "Authorization: <EDR key>"
//   Météo-France   France           6 min     public-api.meteofrance.fr "Package Observations" v2:
//                                             every station of one 6-minute slot; header "apikey"
//   Met Office     United Kingdom   hourly    Weather DataHub Land Observations; header "apikey";
//                                             the nearest stations (by geohash), then each station
//
// Pure, like StationNetworks.swift: the app target does the HTTP and keeps the
// keys in the Keychain.

import Foundation

extension WxStationNetworks {
    // MARK: - AEMET

    /// The latest hourly reports (about the last 12 hours) of every AEMET automatic station.
    public static let aemetObservationsURL = "https://opendata.aemet.es/opendata/api/observacion/convencional/todas"
    /// The host of AEMET's data URLs; a data URL elsewhere is not followed.
    static let aemetDataPrefix = "https://opendata.aemet.es/"

    /// AEMET's first answer.
    public enum AEMETEnvelope: Sendable, Equatable {
        /// The data is at this URL (valid for about 5 minutes; it needs no key).
        case data(url: String)
        /// No data matches (estado 404).
        case noData
        /// Refused: 401 (key missing, invalid or expired), 403, 429 (too many requests), other.
        case refused(status: Int, message: String?)
    }

    /// The first answer's envelope {descripcion, estado, datos, metadatos}. AEMET answers a request
    /// without a key with HTTP 200 and an empty body.
    public static func parseAEMETEnvelope(_ data: Data) -> AEMETEnvelope {
        guard !data.isEmpty else { return .refused(status: 401, message: nil) }
        guard let root = json(latin9Tolerant(data)) as? [String: Any], let estado = num(root["estado"]).map({ Int($0) })
        else {
            return .refused(status: 0, message: nil)
        }
        let message = str(root["descripcion"])
        switch estado {
        case 200:
            guard let url = str(root["datos"]), url.hasPrefix(aemetDataPrefix) else {
                return .refused(status: 0, message: message)
            }
            return .data(url: url)
        case 404:
            return .noData
        default:
            return .refused(status: estado, message: message)
        }
    }

    /// The data URL's answer once it has expired: HTTP 200 with {"estado": 404, "descripcion":
    /// "datos expirados"} (the first request is then made again).
    public static func aemetDataExpired(_ data: Data) -> Bool {
        guard let root = json(latin9Tolerant(data)) as? [String: Any] else { return false }
        return num(root["estado"]) == 404
    }

    /// AEMET's hourly records (one per station and hour, about the last 12 hours) folded to the
    /// newest report of each station. `fint` is the end of the hour, UTC; `ta`, `hr`, `tpr` are at
    /// `fint`; `vv` is the 10-minute mean wind before `fint`, `vmax` the hour's gust (m/s); `prec`
    /// the hour's precipitation (mm). A missing value is an absent key.
    public static func parseAEMET(_ data: Data) -> [WxStationObservation] {
        guard let list = json(latin9Tolerant(data)) as? [[String: Any]] else { return [] }
        var newest: [String: (t: Int64, r: [String: Any])] = [:]
        for r in list {
            guard let id = str(r["idema"]), let t = parseISO8601(str(r["fint"])) else { continue }
            if let known = newest[id], known.t >= t { continue }
            newest[id] = (t, r)
        }
        return newest.compactMap { id, entry -> WxStationObservation? in
            let r = entry.r
            guard let lat = num(r["lat"]), let lon = num(r["lon"]), WxGeo.isValid(lat: lat, lon: lon),
                  let temp = num(r["ta"]), temp >= -60, temp <= 60
            else {
                return nil
            }
            let kmh = { (k: String) in num(r[k]).flatMap { $0 >= 0 ? $0 * 3.6 : nil } }
            return WxStationObservation(
                network: .aemet, id: id, name: str(r["ubi"]).map(collapseSpaces), lat: lat, lon: lon,
                elevM: num(r["alt"]), obsTimeS: entry.t, tempC: temp, dewpC: num(r["tpr"]),
                humidityPct: num(r["hr"]).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
                windKmh: kmh("vv") ?? kmh("vvu"), gustKmh: kmh("vmax") ?? kmh("vmaxu"),
                precipMmH: num(r["prec"]).map { max(0.0, $0) })
        }
    }

    /// AEMET labels its data ISO-8859-15 but sometimes sends UTF-8: UTF-8 when valid, else Latin-9.
    static func latin9Tolerant(_ data: Data) -> Data {
        if String(data: data, encoding: .utf8) != nil {
            return data
        }
        let latin9 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.isoLatin9.rawValue)))
        guard let text = String(data: data, encoding: latin9) else { return data }
        return Data(text.utf8)
    }

    static func collapseSpaces(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: - MET Norway Frost

    /// The Frost stations nearest a point that measure air temperature (WKT is longitude first).
    public static func frostSourcesURL(lat: Double, lon: Double, count: Int = 40) -> String {
        String(
            format: "https://frost.met.no/sources/v0.jsonld?types=SensorSystem&geometry=nearest(POINT(%.4f%%20%.4f))"
                + "&nearestmaxcount=%d&elements=air_temperature&fields=id,name,shortName,geometry,masl,stationHolders",
            lon, lat, count)
    }

    /// The elements asked of Frost: the 10-minute and the hourly forms of the gust and the precipitation
    /// (a station has one or both), every level (the 2 m temperature and the 10 m wind are chosen).
    static let frostElements = [
        "air_temperature", "relative_humidity", "dew_point_temperature", "wind_speed",
        "max(wind_speed_of_gust PT10M)", "max(wind_speed_of_gust PT1H)",
        "sum(precipitation_amount PT10M)", "sum(precipitation_amount PT1H)",
    ]

    /// The latest value (at most 3 hours old) of every element of the given stations.
    public static func frostObservationsURL(stationIDs: [String]) -> String {
        let elements = frostElements.joined(separator: ",").replacingOccurrences(of: " ", with: "%20")
        return "https://frost.met.no/observations/v0.jsonld?sources=\(stationIDs.joined(separator: ","))"
            + "&referencetime=latest&maxage=PT3H&elements=\(elements)"
    }

    /// The HTTP Basic authorization of a Frost client ID (the password is empty).
    public static func frostAuthorization(clientID: String) -> String {
        "Basic " + Data("\(clientID):".utf8).base64EncodedString()
    }

    /// Frost sources: id ("SN18700"), name, position (GeoJSON [lon, lat]), elevation; `kind` lists the
    /// station holders ("MET.NO", "STATENS VEGVESEN", ...).
    public static func parseFrostSources(_ data: Data) -> [WxStationSite] {
        guard let root = json(data) as? [String: Any], let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let id = str(s["id"]),
                  let coords = (s["geometry"] as? [String: Any])?["coordinates"] as? [Any], coords.count >= 2,
                  let lon = num(coords[0]), let lat = num(coords[1]), WxGeo.isValid(lat: lat, lon: lon)
            else {
                return nil
            }
            let holders = (s["stationHolders"] as? [Any])?.compactMap { str($0) } ?? []
            return WxStationSite(
                id: id, name: str(s["shortName"]) ?? str(s["name"]), lat: lat, lon: lon, elevM: num(s["masl"]),
                kind: holders.isEmpty ? nil : holders.joined(separator: ","))
        }
    }

    /// Frost observations folded to one report per station: for every element the newest value of
    /// the main sensor (":0"), official series (timeSeriesId 0) and a usable quality (codes 5-7, very
    /// uncertain or erroneous, are dropped), at the standard level (2 m for temperature and
    /// humidity, 10 m for wind) when several are reported. MET.NO stations are first-class; others
    /// (road authority, partners) get less trust, and their wind much less.
    public static func parseFrostObservations(_ data: Data, sites: [String: WxStationSite]) -> [WxStationObservation] {
        guard let root = json(data) as? [String: Any], let items = root["data"] as? [[String: Any]] else { return [] }
        struct Pick {
            var t: Int64
            var v: Double
            var levelMiss: Double
        }
        var folds: [String: [String: Pick]] = [:]
        for item in items {
            guard let source = str(item["sourceId"]), let t = parseISO8601(str(item["referenceTime"])),
                  let observations = item["observations"] as? [[String: Any]]
            else {
                continue
            }
            let parts = source.split(separator: ":")
            guard let station = parts.first.map(String.init), parts.count == 1 || parts[1] == "0" else { continue }
            for o in observations {
                guard let element = str(o["elementId"]), let v = num(o["value"]),
                      (num(o["timeSeriesId"]) ?? 0) == 0, (num(o["qualityCode"]) ?? 0) < 5
                else {
                    continue
                }
                let standard: Double = element.hasPrefix("wind") || element.contains("wind_speed") ? 10 : 2
                let level = num((o["level"] as? [String: Any])?["value"])
                let pick = Pick(t: t, v: v, levelMiss: level.map { abs($0 - standard) } ?? 0)
                if let known = folds[station]?[element],
                   known.t > pick.t || (known.t == pick.t && known.levelMiss <= pick.levelMiss)
                {
                    continue
                }
                folds[station, default: [:]][element] = pick
            }
        }
        return folds.compactMap { id, values -> WxStationObservation? in
            guard let site = sites[id], let temp = values["air_temperature"], temp.v >= -60, temp.v <= 50 else {
                return nil
            }
            let v = { (k: String) in values[k]?.v }
            let firstClass = site.kind?.uppercased().contains("MET.NO") ?? false
            // a 10-minute value is used when it is not older than the hourly one
            func newer(_ a: String, _ b: String) -> (key: String, pick: Pick)? {
                switch (values[a], values[b]) {
                case let (x?, y?): x.t >= y.t ? (a, x) : (b, y)
                case let (x?, nil): (a, x)
                case let (nil, y?): (b, y)
                default: nil
                }
            }
            let gust = newer("max(wind_speed_of_gust PT10M)", "max(wind_speed_of_gust PT1H)")
            let precip = newer("sum(precipitation_amount PT10M)", "sum(precipitation_amount PT1H)")
            return WxStationObservation(
                network: .frost, id: id, name: site.name, lat: site.lat, lon: site.lon, elevM: site.elevM,
                obsTimeS: temp.t, tempC: temp.v, dewpC: v("dew_point_temperature"),
                humidityPct: v("relative_humidity").flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
                windKmh: v("wind_speed").flatMap { $0 >= 0 ? $0 * 3.6 : nil },
                gustKmh: gust.flatMap { $0.pick.v >= 0 ? $0.pick.v * 3.6 : nil },
                precipMmH: precip.map { max(0.0, $0.pick.v) * ($0.key.hasSuffix("PT10M)") ? 6.0 : 1.0) },
                trust: firstClass ? 1.0 : 0.7, windTrust: firstClass ? 1.0 : 0.4)
        }
    }

    // MARK: - KNMI (EDR API)

    static let knmiCollection = "https://api.dataplatform.knmi.nl/edr/v1/collections/10-minute-in-situ-meteorological-observations"

    /// The parameters asked of KNMI: 1-minute temperature, humidity and dew point at 1.5 m (some
    /// platforms report only the 10-minute means), 10-minute mean wind and gust at 10 m, the rain
    /// gauge's intensity, total cloud cover (okta) and the automatic present weather (WMO 4680).
    static let knmiParameters = ["ta", "t10", "rh", "rh10", "td", "td10", "ff", "gff", "fx", "rg", "n", "nc", "ww"]

    /// The 10-minute observations of the stations in a box, over the last hour (a bounded interval:
    /// without one the EDR API returns everything since 2012).
    public static func knmiCubeURL(
        box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double), nowS: Int64
    ) -> String {
        let end = nowS - nowS % 600
        let interval = "\(isoUTC(end - 3600))/\(isoUTC(end + 600))"
        return knmiCollection + String(
            format: "/cube?bbox=%.3f,%.3f,%.3f,%.3f", box.minLon, box.minLat, box.maxLon, box.maxLat)
            + "&datetime=\(interval)&parameter-name=\(knmiParameters.joined(separator: ","))"
    }

    /// Every KNMI station: names and heights (GeoJSON).
    public static let knmiLocationsURL = knmiCollection + "/locations"

    /// KNMI stations by WIGOS id (`id`), from the `/locations` GeoJSON.
    public static func parseKNMILocations(_ data: Data) -> [String: WxStationSite] {
        guard let root = json(data) as? [String: Any], let features = root["features"] as? [[String: Any]] else {
            return [:]
        }
        var out: [String: WxStationSite] = [:]
        for f in features {
            guard let id = str(f["id"]),
                  let coords = (f["geometry"] as? [String: Any])?["coordinates"] as? [Any], coords.count >= 2,
                  let lon = num(coords[0]), let lat = num(coords[1])
            else {
                continue
            }
            let p = f["properties"] as? [String: Any]
            out[id] = WxStationSite(
                id: id, name: str(p?["name"]), lat: lat, lon: lon, elevM: num(p?["height_above_mean_sea_level"]))
        }
        return out
    }

    /// A KNMI CoverageJSON CoverageCollection (one PointSeries coverage per station, values `null`
    /// when missing) folded to one report per station: for every parameter its newest non-null
    /// value; the report's time is that of the newest temperature. Stations without temperature
    /// (wind masts, visibility sites) are skipped.
    public static func parseKNMICoverage(_ data: Data, stations: [String: WxStationSite]) -> [WxStationObservation] {
        guard let root = json(data) as? [String: Any], let coverages = root["coverages"] as? [[String: Any]] else {
            return []
        }
        return coverages.compactMap { c -> WxStationObservation? in
            guard let axes = (c["domain"] as? [String: Any])?["axes"] as? [String: Any],
                  let times = ((axes["t"] as? [String: Any])?["values"] as? [Any])?.map({ parseISO8601(str($0)) }),
                  let ranges = c["ranges"] as? [String: Any]
            else {
                return nil
            }
            let id = str(c["eumetnet:locationId"])
            let site = id.flatMap { stations[$0] }
            guard let lon = site?.lon ?? ((axes["x"] as? [String: Any])?["values"] as? [Any])?.first.flatMap(num),
                  let lat = site?.lat ?? ((axes["y"] as? [String: Any])?["values"] as? [Any])?.first.flatMap(num),
                  WxGeo.isValid(lat: lat, lon: lon)
            else {
                return nil
            }
            func newest(_ p: String) -> (t: Int64, v: Double)? {
                guard let values = (ranges[p] as? [String: Any])?["values"] as? [Any] else { return nil }
                for i in stride(from: min(values.count, times.count) - 1, through: 0, by: -1) {
                    if let v = num(values[i]), let t = times[i] {
                        return (t, v)
                    }
                }
                return nil
            }
            guard let temp = newest("ta") ?? newest("t10"), temp.v >= -50, temp.v <= 50 else { return nil }
            let rh = (newest("rh") ?? newest("rh10"))?.v
            let td = (newest("td") ?? newest("td10"))?.v
            let ww = newest("ww").map { Int($0.v) }
            let cloud = (newest("n") ?? newest("nc")).flatMap { $0.v >= 0 && $0.v <= 8 ? $0.v / 8.0 * 100.0 : nil }
            return WxStationObservation(
                network: .knmi, id: id ?? String(format: "%.4f,%.4f", lat, lon), name: site?.name, lat: lat, lon: lon,
                elevM: site?.elevM, obsTimeS: temp.t, tempC: temp.v, dewpC: td,
                humidityPct: rh.flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
                windKmh: newest("ff").flatMap { $0.v >= 0 ? $0.v * 3.6 : nil },
                gustKmh: (newest("gff") ?? newest("fx")).flatMap { $0.v >= 0 ? $0.v * 3.6 : nil },
                cloudPct: cloud, precipMmH: newest("rg").map { max(0.0, $0.v) },
                condition: ww.flatMap {
                    WxPresentWeather.condition(
                        wawa: $0, wetBulbC: WxStationFusion.wetBulbC(tempC: temp.v, humidityPct: rh ?? 80))
                },
                reportsPresentWeather: ww != nil, cloudIsCeilometerLimited: cloud != nil)
        }
    }

    // MARK: - Météo-France (Package Observations v2)

    static let meteoFranceBase = "https://public-api.meteofrance.fr/public/DPPaquetObs/v2"

    /// The station list (CSV: Id_station;Id_omm;Nom_usuel;Latitude;Longitude;Altitude;Date_ouverture;Pack).
    public static let meteoFranceStationsURL = meteoFranceBase + "/liste-stations"

    /// A slot is published 3 to 9 minutes after its time and fills up as stations report: the
    /// newest slot (minutes a multiple of 6) at least 10 minutes old.
    public static func meteoFranceSlotS(nowS: Int64) -> Int64 {
        let t = nowS - 600
        return t - ((t % 360) + 360) % 360
    }

    /// Every French station's report of one 6-minute slot (JSON).
    public static func meteoFranceSlotURL(slotS: Int64) -> String {
        meteoFranceBase + "/paquet/stations/infrahoraire-6m?date=\(isoUTC(slotS))&format=json"
    }

    /// The station list: name, elevation, and the network ("RADOME": Météo-France's core automatic
    /// stations; "ETENDU": the extended network, often partner stations measuring only temperature
    /// and rain).
    public static func parseMeteoFranceStations(_ data: Data) -> [String: WxStationSite] {
        let rows = csvRows(data)
        guard let header = rows.first.map({ $0.map { $0.lowercased() } }),
              let iID = header.firstIndex(of: "id_station"), let iName = header.firstIndex(of: "nom_usuel"),
              let iLat = header.firstIndex(of: "latitude"), let iLon = header.firstIndex(of: "longitude")
        else {
            return [:]
        }
        let iAlt = header.firstIndex(of: "altitude")
        let iPack = header.firstIndex(of: "pack")
        var out: [String: WxStationSite] = [:]
        for row in rows.dropFirst() where row.count > max(iID, iName, iLat, iLon) {
            let id = row[iID]
            guard id.count == 8, let lat = Double(row[iLat]), let lon = Double(row[iLon]),
                  WxGeo.isValid(lat: lat, lon: lon)
            else {
                continue
            }
            let name = row[iName].replacingOccurrences(of: "_", with: " ")
            out[id] = WxStationSite(
                id: id, name: name.isEmpty ? nil : name, lat: lat, lon: lon,
                elevM: iAlt.flatMap { $0 < row.count ? Double(row[$0]) : nil },
                kind: iPack.flatMap { $0 < row.count && !row[$0].isEmpty ? row[$0] : nil })
        }
        return out
    }

    /// One 6-minute slot of Météo-France reports (a JSON array of flat objects, values `null` when
    /// missing): temperature and dew point in kelvin, humidity %, the 10-minute mean wind and the
    /// 10-minute gust in m/s at 10 m, the slot's precipitation in mm.
    public static func parseMeteoFrance(_ data: Data, stations: [String: WxStationSite]) -> [WxStationObservation] {
        guard let list = json(data) as? [[String: Any]] else { return [] }
        return list.compactMap { r -> WxStationObservation? in
            guard let id = str(r["geo_id_insee"]), let kelvin = num(r["t"]), kelvin > 200, kelvin < 340 else {
                return nil
            }
            let site = stations[id]
            guard let lat = site?.lat ?? num(r["lat"]), let lon = site?.lon ?? num(r["lon"]),
                  WxGeo.isValid(lat: lat, lon: lon)
            else {
                return nil
            }
            let celsius = { (k: Double) in ((k - 273.15) * 100).rounded() / 100 }
            let core = site?.kind?.uppercased() != "ETENDU"
            let kmh = { (k: String) in num(r[k]).flatMap { $0 >= 0 ? $0 * 3.6 : nil } }
            return WxStationObservation(
                network: .meteoFrance, id: id, name: site?.name, lat: lat, lon: lon, elevM: site?.elevM,
                obsTimeS: parseISO8601(str(r["validity_time"])), tempC: celsius(kelvin),
                dewpC: num(r["td"]).flatMap { $0 > 180 && $0 < 330 ? celsius($0) : nil },
                humidityPct: num(r["u"]).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
                windKmh: kmh("ff"), gustKmh: kmh("raf10") ?? kmh("fxi10"),
                precipMmH: num(r["rr_per"]).map { max(0.0, $0) * 10.0 },
                trust: core ? 1.0 : 0.85, windTrust: core ? 1.0 : 0.6)
        }
    }

    // MARK: - Met Office (Weather DataHub Land Observations)

    static let metOfficeBase = "https://data.hub.api.metoffice.gov.uk/observation-land/1"

    /// The (up to 5) stations nearest a point; the API takes coordinates with 2 decimals.
    public static func metOfficeNearestURL(lat: Double, lon: Double, count: Int = 5) -> String {
        String(format: "%@/nearest?lat=%.2f&lon=%.2f&max=%d", metOfficeBase, lat, lon, min(5, max(1, count)))
    }

    /// The last 48 hours of one station's hourly reports.
    public static func metOfficeStationURL(geohash: String) -> String {
        "\(metOfficeBase)/\(geohash)"
    }

    /// The stations of a `/nearest` answer: geohash (the station's id and its position) and area.
    public static func parseMetOfficeNearest(_ data: Data) -> [(geohash: String, area: String?)] {
        guard let list = json(data) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let hash = str(item["geohash"]), hash.count >= 5, decodeGeohash(hash) != nil else { return nil }
            return (hash, str(item["area"]))
        }
    }

    /// The centre of a geohash cell (6 characters: about ±300 m in the UK); nil for an invalid one.
    public static func decodeGeohash(_ hash: String) -> (lat: Double, lon: Double)? {
        let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        var lat = (-90.0, 90.0), lon = (-180.0, 180.0)
        var even = true
        for ch in hash.lowercased() {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            for bit in stride(from: 4, through: 0, by: -1) {
                let on = (v >> bit) & 1 == 1
                if even {
                    let mid = (lon.0 + lon.1) / 2
                    lon = on ? (mid, lon.1) : (lon.0, mid)
                } else {
                    let mid = (lat.0 + lat.1) / 2
                    lat = on ? (mid, lat.1) : (lat.0, mid)
                }
                even.toggle()
            }
        }
        return ((lat.0 + lat.1) / 2, (lon.0 + lon.1) / 2)
    }

    /// The Met Office significant-weather code (0-30) as a condition and, for the sky codes, a cloud
    /// cover: (nil, cloud) for a dry sky, (nil, nil) for mist and "not available".
    public static func metOfficeWeather(_ code: Int) -> (condition: WxCondition?, cloudPct: Double?) {
        switch code {
        case 0, 1: (nil, 5)
        case 2, 3: (nil, 45)
        case 7: (nil, 80)
        case 8: (nil, 100)
        case 6: (.fog, nil)
        case 9, 10: (.showers, nil)
        case 11: (.drizzle, nil)
        case 12: (.lightRain, nil)
        case 13, 14: (.showers, nil)
        case 15: (.heavyRain, nil)
        case 16...21: (.sleet, nil)  // sleet and hail
        case 22...27: (.snow, nil)
        case 28...30: (.thunderstorm, nil)
        default: (nil, nil)  // 4 not used, 5 mist, NA
        }
    }

    /// The newest hourly report of a Met Office station (°C, %, m/s at 10 m; no dew point).
    public static func parseMetOfficeStation(_ data: Data, geohash: String, area: String?) -> WxStationObservation? {
        guard let list = json(data) as? [[String: Any]], let position = decodeGeohash(geohash) else { return nil }
        var newest: (t: Int64, r: [String: Any])?
        for r in list {
            guard let t = parseISO8601(str(r["datetime"])), num(r["temperature"]) != nil else { continue }
            if let known = newest, known.t >= t { continue }
            newest = (t, r)
        }
        guard let (t, r) = newest, let temp = num(r["temperature"]), temp >= -40, temp <= 45 else { return nil }
        let weather = num(r["weather_code"]).map { metOfficeWeather(Int($0)) }
        let kmh = { (k: String) in num(r[k]).flatMap { $0 >= 0 ? $0 * 3.6 : nil } }
        return WxStationObservation(
            network: .metOffice, id: geohash, name: area, lat: position.lat, lon: position.lon, obsTimeS: t,
            tempC: temp, humidityPct: num(r["humidity"]).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil },
            windKmh: kmh("wind_speed"), gustKmh: kmh("wind_gust"), cloudPct: weather?.cloudPct,
            condition: weather?.condition, reportsPresentWeather: weather != nil)
    }
}
