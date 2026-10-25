// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ECCCProvider.swift - key-free HTTPS provider for Environment and Climate
// Change Canada (ECCC) MSC GeoMet OGC API (https://api.weather.gc.ca).
// Delivers official Canadian Citypage / HRDPS 2.5 km hourly forecasts under the
// Open Government Licence – Canada.

import Foundation

/// Environment and Climate Change Canada (MSC GeoMet) forecast provider.
public final class ECCCProvider: WxProvider {
    public static let providerID = "eccc"
    public static let modelID = "hrdps"
    public static let baseURL = "https://api.weather.gc.ca"
    public static let displayName = "Environment Canada"
    public static let attributionText = "Source: Environment and Climate Change Canada"
    public static let attributionLink = "https://weather.gc.ca/"
    public static let accept = "application/json"

    public var id: String { Self.providerID }
    public var name: String { Self.displayName }
    public var attribution: String { Self.attributionText }
    public var attributionURL: String { Self.attributionLink }

    let http: HTTPClient
    let clock: any WxClock

    public convenience init(clock: any WxClock = SystemClock()) throws(WxError) {
        let http = try HTTPClient(
            baseURL: Self.baseURL, userAgent: HTTPPolicy.userAgent,
            timeoutMs: HTTPPolicy.timeoutMs, backoffBaseMs: HTTPPolicy.backoffBaseMs,
            minGapMs: 0, clock: clock)
        self.init(http: http, clock: clock)
    }

    init(
        customBaseURL: String, timeoutMs: Int, backoffBaseMs: Int, clock: any WxClock = SystemClock()
    ) throws(WxError) {
        let http = try HTTPClient(
            baseURL: customBaseURL, userAgent: HTTPPolicy.userAgent,
            timeoutMs: timeoutMs, backoffBaseMs: backoffBaseMs,
            minGapMs: 0, clock: clock)
        self.http = http
        self.clock = clock
    }

    private init(http: HTTPClient, clock: any WxClock) {
        self.http = http
        self.clock = clock
    }

    /// Covers Canadian places (`WxRegion.canada`).
    public func covers(_ place: WxPlace) -> Bool {
        WxGeo.region(for: place) == .canada
            || WxGeo.inCanada(lat: place.lat, lon: place.lon, countryCode: place.countryCode)
    }

    public func fetch(_ place: WxPlace) async throws -> WxSourceResult {
        try Task.checkCancellation()
        guard covers(place) else {
            throw WxError(.unsupported, "place is outside Environment Canada coverage")
        }
        let outcome: Result<WxSourceResult, any Error>
        do {
            let path = Self.forecastPath(lat: place.lat, lon: place.lon, marginDeg: 0.75)
            let response = try await http.get(path, accept: Self.accept)
            let fetchedS = clock.wallSeconds
            if let primary = try? Self.parseForecast(response.body, placeLat: place.lat, placeLon: place.lon, fetchedS: fetchedS) {
                outcome = .success(primary)
            } else {
                // Retry with a wider bounding box for rural / northern Canadian locations
                let widePath = Self.forecastPath(lat: place.lat, lon: place.lon, marginDeg: 2.2)
                let response2 = try await http.get(widePath, accept: Self.accept)
                let fetchedS2 = clock.wallSeconds
                let fallback = try Self.parseForecast(
                    response2.body, placeLat: place.lat, placeLon: place.lon, fetchedS: fetchedS2)
                outcome = .success(fallback)
            }
        } catch {
            outcome = .failure(error)
        }
        try Task.checkCancellation()
        return try outcome.get()
    }

    // MARK: - Path & Parser

    public static func forecastPath(lat: Double, lon: Double, marginDeg: Double = 0.75) -> String {
        let minLon = OpenMeteoShared.coordText(max(-180.0, lon - marginDeg))
        let minLat = OpenMeteoShared.coordText(max(-90.0, lat - marginDeg))
        let maxLon = OpenMeteoShared.coordText(min(180.0, lon + marginDeg))
        let maxLat = OpenMeteoShared.coordText(min(90.0, lat + marginDeg))
        return "/collections/citypageweather-realtime/items?f=json&limit=4&bbox=\(minLon),\(minLat),\(maxLon),\(maxLat)"
    }

    public static func parseForecast<Bytes: Collection<UInt8>>(
        _ data: Bytes, placeLat: Double = .nan, placeLon: Double = .nan, fetchedS: Int64
    ) throws(WxError) -> WxSourceResult {
        if fetchedS < WxLimits.timeMinS || fetchedS >= WxLimits.timeMaxS {
            throw WxError(.invalidArg, "invalid fetch time")
        }
        let root = try WxJSON.parseObject(data, maxLength: HTTPPolicy.maxBodyBytes)
        guard let features = root.array("features"), !features.isEmpty else {
            throw WxError(.notFound, "no usable forecast data")
        }

        // Pick the closest feature when multiple Citypage stations fall inside the bbox
        var bestProps: WxJSON.Object?
        var bestDistKm = Double.greatestFiniteMagnitude
        for node in features {
            guard case .object(let feature) = node,
                  let props = feature.object("properties") else { continue }
            if placeLat.isFinite && placeLon.isFinite,
               let geom = feature.object("geometry"),
               let coords = geom.array("coordinates"),
               coords.count >= 2,
               let fLon = coords[0].numberInRange(-180.0, 180.0),
               let fLat = coords[1].numberInRange(-90.0, 90.0)
            {
                let d = WxGeo.distanceKm(aLat: placeLat, aLon: placeLon, bLat: fLat, bLon: fLon)
                if d.isFinite && d < bestDistKm {
                    bestDistKm = d
                    bestProps = props
                }
            } else if bestProps == nil {
                bestProps = props
            }
        }

        guard let props = bestProps,
              let group = props.object("hourlyForecastGroup"),
              let hourly = group.array("hourlyForecasts"),
              !hourly.isEmpty else {
            throw WxError(.notFound, "no usable forecast data")
        }

        var parsedHours: [WxHour] = []
        for node in hourly {
            guard case .object(let entry) = node,
                  let tS = WxTime.parseISO8601(entry.string("timestamp")),
                  tS >= WxLimits.timeMinS, tS < WxLimits.timeMaxS,
                  tS % 3600 == 0 else {
                continue
            }
            var h = WxHour(tS: tS)
            h.tempC = nestedValue(entry.object("temperature"), lo: WxLimits.tempMinC, hi: WxLimits.tempMaxC)
            h.humidityPct = nestedValue(entry.object("relativeHumidity"), lo: WxLimits.percentMin, hi: WxLimits.percentMax)
            h.precipProb = nestedValue(entry.object("lop"), lo: WxLimits.percentMin, hi: WxLimits.percentMax)
            if let wind = entry.object("wind") {
                h.windKmh = nestedValue(wind.object("speed"), lo: 0.0, hi: WxLimits.windMaxKmh)
                h.gustKmh = nestedValue(wind.object("gust"), lo: 0.0, hi: WxLimits.windMaxKmh)
            }
            let windChill = nestedValue(entry.object("windChill"), lo: WxLimits.tempMinC, hi: WxLimits.tempMaxC)
            let humidex = nestedValue(entry.object("humidex"), lo: WxLimits.tempMinC, hi: WxLimits.tempMaxC)
            if windChill.isFinite {
                h.feelsC = windChill
            } else if humidex.isFinite {
                h.feelsC = humidex
            } else if h.tempC.isFinite {
                h.feelsC = BrightSkyProvider.deriveApparentTempC(
                    tempC: h.tempC, humidityPct: h.humidityPct, windKmh: h.windKmh)
            }

            let condText = entry.object("condition")?.string("en") ?? ""
            let rawIcon = nestedValue(entry.object("iconCode"), lo: 0, hi: 99)
            let iconCode = rawIcon.isFinite ? Int(rawIcon) : nil
            let mapped = mapECCCCondition(condText: condText, iconCode: iconCode, lopPct: h.precipProb)
            h.wmo = mapped.wmo
            if mapped.cloudPct.isFinite {
                h.cloudPct = mapped.cloudPct
            }
            if mapped.precipMm.isFinite {
                h.precipMm = mapped.precipMm
            }

            let hasNumeric =
                h.tempC.isFinite || h.feelsC.isFinite || h.humidityPct.isFinite
                || h.precipMm.isFinite || h.precipProb.isFinite || h.cloudPct.isFinite
                || h.windKmh.isFinite || h.gustKmh.isFinite
            if hasNumeric {
                parsedHours.append(h)
            }
        }

        parsedHours.sort { $0.tS < $1.tS }
        var member = try WxMember(sourceID: providerID, modelID: modelID, fetchedS: fetchedS)
        var lastTS: Int64 = -1
        for h in parsedHours where h.tS > lastTS {
            if member.addHour(h) {
                lastTS = h.tS
            }
        }
        if member.hours.isEmpty {
            throw WxError(.notFound, "no usable forecast data")
        }
        var result = try WxSourceResult(providerID: providerID)
        result.members = [member]
        return result
    }

    private static func nestedValue(_ container: WxJSON.Object?, lo: Double, hi: Double) -> Double {
        guard let container else { return .nan }
        if let valObj = container.object("value") {
            if let v = valObj.member("en")?.numberInRange(lo, hi) {
                return v == 0.0 ? 0.0 : v
            }
        }
        if let v = container.member("value")?.numberInRange(lo, hi) {
            return v == 0.0 ? 0.0 : v
        }
        return .nan
    }

    private static func mapECCCCondition(
        condText: String, iconCode: Int?, lopPct: Double
    ) -> (wmo: Int, cloudPct: Double, precipMm: Double) {
        let lower = condText.lowercased()
        var wmo = -1
        var cloud = Double.nan
        var precip = Double.nan

        if lower.contains("thunder") {
            wmo = 95
            cloud = 90.0
            precip = 2.5
        } else if lower.contains("freezing rain") || lower.contains("ice pellets") {
            wmo = 66
            cloud = 95.0
            precip = 1.2
        } else if lower.contains("snow") || lower.contains("flurries") || lower.contains("blizzard") {
            wmo = lower.contains("heavy") ? 75 : 71
            cloud = 90.0
            precip = lower.contains("heavy") ? 2.0 : (lower.contains("flurries") ? 0.3 : 0.8)
        } else if lower.contains("rain") || lower.contains("showers") || lower.contains("drizzle") {
            if lower.contains("drizzle") {
                wmo = 51
                precip = 0.2
            } else if lower.contains("heavy") {
                wmo = 65
                precip = 4.5
            } else if lower.contains("showers") || lower.contains("chance") {
                wmo = 80
                precip = lopPct.isFinite && lopPct >= 60 ? 1.0 : 0.3
            } else {
                wmo = 61
                precip = 1.2
            }
            cloud = 88.0
        } else if lower.contains("fog") || lower.contains("mist") {
            wmo = 45
            cloud = 95.0
            precip = 0.0
        } else if lower.contains("overcast") || lower == "cloudy" {
            wmo = 3
            cloud = 92.0
            precip = 0.0
        } else if lower.contains("mostly cloudy") || lower.contains("mainly cloudy") {
            wmo = 3
            cloud = 75.0
            precip = 0.0
        } else if lower.contains("partly cloudy") || lower.contains("mix of sun and cloud") {
            wmo = 2
            cloud = 45.0
            precip = 0.0
        } else if lower.contains("mainly sunny") || lower.contains("mainly clear") || lower.contains("a few clouds") {
            wmo = 1
            cloud = 20.0
            precip = 0.0
        } else if lower.contains("sunny") || lower.contains("clear") {
            wmo = 0
            cloud = 5.0
            precip = 0.0
        } else if let iconCode {
            switch iconCode {
            case 0, 30: wmo = 0; cloud = 5.0; precip = 0.0
            case 1, 31: wmo = 1; cloud = 20.0; precip = 0.0
            case 2, 32: wmo = 2; cloud = 45.0; precip = 0.0
            case 3, 33: wmo = 3; cloud = 75.0; precip = 0.0
            case 10: wmo = 3; cloud = 92.0; precip = 0.0
            case 6, 12, 13, 36: wmo = 61; cloud = 88.0; precip = 0.8
            case 7, 8, 16, 17, 18, 37, 38: wmo = 71; cloud = 90.0; precip = 0.6
            case 9, 19, 39: wmo = 95; cloud = 92.0; precip = 2.0
            case 24: wmo = 45; cloud = 95.0; precip = 0.0
            default: break
            }
        }
        return (wmo, cloud, precip)
    }
}
