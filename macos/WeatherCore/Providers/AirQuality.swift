// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AirQuality.swift - the forecast page's Air Quality card, from real readings
// only: the US AQI of the nearest AirNow monitor (US EPA, keyless ArcGIS
// layers) exactly as reported, else the CAMS forecast for the place (Open-Meteo
// air-quality API); each is compared with the same source 24 hours earlier.
// Without either the card shows the dash: nothing is estimated from the
// weather. Pure: request builders, parsers and the card; the app target
// (LiveStationFetcher) does the HTTP.
//
// AirNow Data Exchange Guidelines: observed values are shown as received (one
// monitor, never interpolated between monitors), marked preliminary, and
// credited to the reporting agency and the EPA AirNow program. Open-Meteo's
// air-quality terms: credit CAMS and Open-Meteo.

import Foundation

/// The Air Quality card's data (AirNow monitors, CAMS via Open-Meteo).
public enum WxAirQuality {
    /// One monitor's hourly reading (AirNow).
    public struct MonitorReading: Sendable, Equatable {
        /// The AirNow site (AQS) ID; the site name when missing.
        public let id: String
        public let name: String
        /// The reporting agency ("South Coast AQMD"); "" when missing.
        public let agency: String
        public let distKm: Double
        /// The US AQI (the higher of the ozone and particle indices), 0...500.
        public let aqi: Int
        /// The hour the reading is valid for, UTC unix seconds.
        public let tS: Int64

        public init(id: String, name: String, agency: String, distKm: Double, aqi: Int, tS: Int64) {
            self.id = id
            self.name = name
            self.agency = agency
            self.distKm = distKm
            self.aqi = aqi
            self.tS = tS
        }
    }

    /// The CAMS forecast at the place (Open-Meteo).
    public struct ModelReading: Sendable, Equatable {
        /// The US AQI, 0...500.
        public let aqi: Int
        /// The hour the values are valid for, UTC unix seconds.
        public let tS: Int64
        /// The forecast US AQI 24 hours before `tS`; nil when missing.
        public let dayAgoAQI: Int?
        public let europeanAQI: Int?
        /// µg/m³; nil when missing.
        public let pm25: Double?
        public let no2: Double?
    }

    /// Monitors farther than this are not used, km.
    public static let radiusKm = 45.0
    /// A reading older than this is not shown, s (AirNow reports hourly).
    public static let maxAgeS: Int64 = 3 * 3600
    static let dayS: Int64 = 86_400

    public static let airNowURL = "https://www.airnow.gov/"
    /// Open-Meteo's air-quality page, which carries the full CAMS citation.
    public static let camsCredit = WxStationNetworks.Credit(
        text: "Air quality: Copernicus Atmosphere Monitoring Service (CAMS) via Open-Meteo",
        url: "https://open-meteo.com/en/docs/air-quality-api")

    // MARK: - AirNow

    private static let airNowCurrentLayer = "https://services.arcgis.com/cJ9YHowT8TU7DUyn/arcgis/rest/services/"
        + "Air_Now_Current_Monitors_Ozone_and_PM/FeatureServer/0/query"
    private static let airNowHourlyLayer = "https://services.arcgis.com/cJ9YHowT8TU7DUyn/arcgis/rest/services/"
        + "Air_Now_Monitor_Data_Public/FeatureServer/0/query"

    private static func airNowQuery(lat: Double, lon: Double) -> String {
        String(format: "where=OZONEPM_AQI%%20IS%%20NOT%%20NULL&geometry=%.4f,%.4f&geometryType=esriGeometryPoint"
               + "&inSR=4326&spatialRel=esriSpatialRelIntersects&distance=%.0f&units=esriSRUnit_Meter",
               lon, lat, radiusKm * 1000)
    }

    /// Every monitor's latest reading within `radiusKm`.
    public static func airNowCurrentURL(lat: Double, lon: Double) -> String {
        airNowCurrentLayer + "?" + airNowQuery(lat: lat, lon: lon)
            + "&outFields=AQSID,SiteName,DataSource,OZONEPM_AQI,ValidTime&outSR=4326&f=json"
    }

    /// Every monitor's hourly readings valid from `startS` to `endS` (inclusive) within `radiusKm`;
    /// the layer keeps about the last 27 hours.
    public static func airNowHourlyURL(lat: Double, lon: Double, startS: Int64, endS: Int64) -> String {
        airNowHourlyLayer + "?" + airNowQuery(lat: lat, lon: lon) + "&time=\(startS * 1000),\(endS * 1000)"
            + "&outFields=AQSID,SiteName,DataSource,OZONEPM_AQI,ValidTime,Latitude,Longitude&outSR=4326&f=json"
    }

    /// The hours that hold the readings 24 hours before any reading `nearestMonitor` may pick at `nowS`.
    public static func dayAgoWindow(nowS: Int64) -> (startS: Int64, endS: Int64) {
        let hour = nowS - ((nowS % 3600) + 3600) % 3600
        return (hour - dayS - maxAgeS, hour - dayS + 3600)
    }

    /// The hours `nearestMonitor` may pick a reading from at `nowS` (the hourly layer, used when the
    /// current layer has nothing).
    public static func recentWindow(nowS: Int64) -> (startS: Int64, endS: Int64) {
        let hour = nowS - ((nowS % 3600) + 3600) % 3600
        return (hour - maxAgeS, hour + 3600)
    }

    private struct ArcGISResponse: Decodable {
        struct Feature: Decodable {
            struct Attributes: Decodable {
                let AQSID: String?
                let SiteName: String?
                let DataSource: String?
                let OZONEPM_AQI: Double?
                let ValidTime: Double?
                let Latitude: Double?
                let Longitude: Double?
            }
            struct Geometry: Decodable {
                let x: Double?
                let y: Double?
            }
            let attributes: Attributes
            let geometry: Geometry?
        }
        let features: [Feature]?
    }

    /// The readings of an AirNow layer response; nil when it is not one (an ArcGIS error object or
    /// any other body).
    public static func parseAirNow(_ data: Data, lat: Double, lon: Double) -> [MonitorReading]? {
        guard let decoded = try? JSONDecoder().decode(ArcGISResponse.self, from: data),
              let features = decoded.features
        else {
            return nil
        }
        return features.compactMap { f -> MonitorReading? in
            let a = f.attributes
            guard let raw = a.OZONEPM_AQI, raw.isFinite, raw >= 0, raw <= 500,
                  let validMs = a.ValidTime, validMs.isFinite,
                  let sLat = f.geometry?.y ?? a.Latitude, let sLon = f.geometry?.x ?? a.Longitude
            else {
                return nil
            }
            let name = clean(a.SiteName)
            let id = clean(a.AQSID)
            guard !(id.isEmpty && name.isEmpty) else { return nil }
            let dist = WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: sLat, bLon: sLon)
            guard dist.isFinite else { return nil }
            return MonitorReading(
                id: id.isEmpty ? name : id, name: name.isEmpty ? id : name, agency: clean(a.DataSource),
                distKm: dist, aqi: Int(raw.rounded()), tS: Int64((validMs / 1000).rounded()))
        }
    }

    /// The reading to show: the nearest monitor within `radiusKm` whose newest reading is at most
    /// `maxAgeS` old, as reported.
    public static func nearestMonitor(_ readings: [MonitorReading], nowS: Int64) -> MonitorReading? {
        var newest: [String: MonitorReading] = [:]
        for r in readings where r.distKm <= radiusKm && (0...500).contains(r.aqi)
            && r.tS <= nowS + 600 && nowS - r.tS <= maxAgeS
        {
            if let have = newest[r.id], have.tS >= r.tS { continue }
            newest[r.id] = r
        }
        return newest.values.min { ($0.distKm, -$0.tS, $0.id) < ($1.distKm, -$1.tS, $1.id) }
    }

    /// The same monitor's AQI 24 hours before `reading` (within half an hour); nil when it did not
    /// report then.
    public static func dayAgoAQI(of reading: MonitorReading, in history: [MonitorReading]) -> Int? {
        let target = reading.tS - dayS
        return history
            .filter { $0.id == reading.id && abs($0.tS - target) <= 1800 && (0...500).contains($0.aqi) }
            .min { abs($0.tS - target) < abs($1.tS - target) }?.aqi
    }

    // MARK: - Open-Meteo (CAMS)

    /// The current CAMS values and the hourly US AQI of yesterday and today (UTC).
    public static func openMeteoURL(lat: Double, lon: Double) -> String {
        String(format: "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.4f&longitude=%.4f"
               + "&current=us_aqi,european_aqi,pm2_5,nitrogen_dioxide&hourly=us_aqi"
               + "&past_days=1&forecast_days=1&timeformat=unixtime", lat, lon)
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let time: Int64?
            let us_aqi: Double?
            let european_aqi: Double?
            let pm2_5: Double?
            let nitrogen_dioxide: Double?
        }
        struct Hourly: Decodable {
            let time: [Int64]?
            let us_aqi: [Double?]?
        }
        let current: Current?
        let hourly: Hourly?
    }

    private static func index(_ v: Double?) -> Int? {
        guard let v, v.isFinite, v >= 0, v <= 500 else { return nil }
        return Int(v.rounded())
    }

    /// The CAMS reading of an Open-Meteo air-quality response (requested with `openMeteoURL`); nil
    /// without a current US AQI. The day-ago value is the hourly value at the same hour yesterday,
    /// found by its time.
    public static func parseOpenMeteo(_ data: Data) -> ModelReading? {
        guard let decoded = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data),
              let current = decoded.current, let tS = current.time, let aqi = index(current.us_aqi)
        else {
            return nil
        }
        var dayAgo: Int?
        if let times = decoded.hourly?.time, let values = decoded.hourly?.us_aqi, times.count == values.count {
            let hour = tS - ((tS % 3600) + 3600) % 3600
            if let i = times.firstIndex(of: hour - dayS) {
                dayAgo = index(values[i])
            }
        }
        let pm25 = current.pm2_5.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let no2 = current.nitrogen_dioxide.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return ModelReading(aqi: aqi, tS: tS, dayAgoAQI: dayAgo, europeanAQI: index(current.european_aqi),
                            pm25: pm25, no2: no2)
    }

    // MARK: - The card

    /// The card of a monitor's reading.
    public static func card(monitor r: MonitorReading, dayAgoAQI: Int?, units: WxUnits,
                            zone: WxFormat.Zone) -> DetailViewModel.AirQualityCard {
        typealias Card = DetailViewModel.AirQualityCard
        let at = WxFormat.hourLabel(r.tS, zone: zone)
        let distance = WxFormat.distance(r.distKm, units: units)
        let agency = r.agency.isEmpty ? "" : "\(r.agency) via "
        return Card(
            index: r.aqi,
            valueText: "\(r.aqi)",
            category: Card.categoryLabel(for: r.aqi),
            summary: Card.summarySentence(aqi: r.aqi, dayAgoAQI: dayAgoAQI),
            source: "Measured at \(r.name), \(distance) away, at \(at). Preliminary data.",
            validS: r.tS,
            credit: WxStationNetworks.Credit(
                text: "Air quality: \(agency)U.S. EPA AirNow (preliminary data)", url: airNowURL))
    }

    /// The card of the CAMS forecast; the European AQI is added in Europe.
    public static func card(model m: ModelReading, inEurope: Bool,
                            zone: WxFormat.Zone) -> DetailViewModel.AirQualityCard {
        typealias Card = DetailViewModel.AirQualityCard
        var details: [String] = []
        if let pm25 = m.pm25 {
            details.append("PM2.5 \(Int(pm25.rounded())) \u{00B5}g/m\u{00B3}")
        }
        if let no2 = m.no2 {
            details.append("NO\u{2082} \(Int(no2.rounded())) \u{00B5}g/m\u{00B3}")
        }
        if inEurope, let eu = m.europeanAQI {
            details.append("European AQI \(eu)")
        }
        let at = WxFormat.hourLabel(m.tS, zone: zone)
        let extra = details.isEmpty ? "" : " " + details.joined(separator: ", ") + "."
        return Card(
            index: m.aqi,
            valueText: "\(m.aqi)",
            category: Card.categoryLabel(for: m.aqi),
            summary: Card.summarySentence(aqi: m.aqi, dayAgoAQI: m.dayAgoAQI),
            source: "CAMS model forecast for \(at), not a local measurement.\(extra)",
            validS: m.tS,
            credit: camsCredit)
    }

    /// Server text made safe to show: whitespace collapsed, at most 80 characters.
    private static func clean(_ s: String?) -> String {
        let words = (s ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(80))
    }
}
