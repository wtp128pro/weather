// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// BrightSkyProvider.swift - key-free HTTPS provider for Deutscher Wetterdienst
// (DWD) OpenData via the Bright Sky JSON API (https://api.brightsky.dev).
// Delivers DWD MOSMIX statistically calibrated station guidance, ICON-D2 (2 km),
// and SYNOP surface observations for Germany, the Netherlands, Benelux, and
// Central Europe under CC BY 4.0 attribution.

import Foundation

/// Deutscher Wetterdienst (DWD) OpenData / Bright Sky forecast provider.
public final class BrightSkyProvider: WxProvider {
    public static let providerID = "dwd-brightsky"
    public static let modelID = "mosmix"
    public static let baseURL = "https://api.brightsky.dev"
    public static let displayName = "DWD Bright Sky"
    public static let attributionText = "Source: Deutscher Wetterdienst (DWD) via Bright Sky"
    public static let attributionLink = "https://brightsky.dev/"
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

    /// Covers Germany, the Netherlands, Benelux, Austria, Switzerland, and adjacent Central Europe.
    public func covers(_ place: WxPlace) -> Bool {
        let region = WxGeo.region(for: place)
        return region == .centralEurope || region == .beneluxNorthSea
            || WxGeo.inCentralEurope(lat: place.lat, lon: place.lon)
            || WxGeo.inBenelux(lat: place.lat, lon: place.lon)
    }

    public func fetch(_ place: WxPlace) async throws -> WxSourceResult {
        try Task.checkCancellation()
        guard covers(place) else {
            throw WxError(.unsupported, "place is outside DWD Bright Sky coverage")
        }
        let nowS = clock.wallSeconds
        let path = Self.forecastPath(lat: place.lat, lon: place.lon, nowS: nowS)
        let outcome: Result<WxSourceResult, any Error>
        do {
            let response = try await http.get(path, accept: Self.accept)
            let fetchedS = clock.wallSeconds
            let result = try Self.parseForecast(response.body, fetchedS: fetchedS)
            outcome = .success(result)
        } catch {
            outcome = .failure(error)
        }
        try Task.checkCancellation()
        return try outcome.get()
    }

    // MARK: - Path & Parser

    public static func forecastPath(lat: Double, lon: Double, nowS: Int64) -> String {
        let startS = max(WxLimits.timeMinS, nowS - 3600)
        let endS = min(WxLimits.timeMaxS - 1, nowS + 10 * 86_400)
        let startISO = isoDayOrHour(startS)
        let endISO = isoDayOrHour(endS)
        let latText = OpenMeteoShared.coordText(lat)
        let lonText = OpenMeteoShared.coordText(lon)
        return "/weather?lat=\(latText)&lon=\(lonText)&date=\(startISO)&last_date=\(endISO)&units=dwd"
    }

    private static func isoDayOrHour(_ epochS: Int64) -> String {
        let hourAligned = epochS - (epochS % 3600)
        let date = Date(timeIntervalSince1970: TimeInterval(hourAligned))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:00:00Z",
            c.year ?? 2026, c.month ?? 1, c.day ?? 1, c.hour ?? 0
        )
    }

    public static func parseForecast<Bytes: Collection<UInt8>>(
        _ data: Bytes, fetchedS: Int64
    ) throws(WxError) -> WxSourceResult {
        if fetchedS < WxLimits.timeMinS || fetchedS >= WxLimits.timeMaxS {
            throw WxError(.invalidArg, "invalid fetch time")
        }
        let root = try WxJSON.parseObject(data, maxLength: HTTPPolicy.maxBodyBytes)
        guard let weather = root.array("weather") else {
            throw WxError(.parse, "response has no weather array")
        }
        var member = try WxMember(sourceID: providerID, modelID: modelID, fetchedS: fetchedS)
        var lastTS: Int64 = -1
        // A record's precipitation and its probability cover the hour BEFORE its timestamp
        // (Bright Sky WeatherRecord: "during previous 60 minutes"), so they go in bucket
        // T - 3600, merged into the previous record's bucket when that is T - 3600, as
        // OpenMeteoParse.buildMember does; every other field stays in bucket T.
        var open = WxHour()
        var haveOpen = false

        for node in weather {
            guard case .object(let entry) = node else { continue }
            guard let tS = WxTime.parseISO8601(entry.string("timestamp")),
                  tS >= WxLimits.timeMinS, tS < WxLimits.timeMaxS,
                  tS % 3600 == 0, tS > lastTS else {
                continue
            }
            var precip = WxHour(tS: tS - 3600)
            precip.precipMm = numberInRange(entry, "precipitation", 0.0, WxLimits.precipMaxMmH)
            precip.precipProb = numberInRange(entry, "precipitation_probability", WxLimits.percentMin, WxLimits.percentMax)
            var hour = WxHour(tS: tS)
            hour.tempC = numberInRange(entry, "temperature", WxLimits.tempMinC, WxLimits.tempMaxC)
            hour.humidityPct = numberInRange(entry, "relative_humidity", WxLimits.percentMin, WxLimits.percentMax)
            hour.cloudPct = numberInRange(entry, "cloud_cover", WxLimits.percentMin, WxLimits.percentMax)
            hour.windKmh = numberInRange(entry, "wind_speed", 0.0, WxLimits.windMaxKmh)
            hour.gustKmh = numberInRange(entry, "wind_gust_speed", 0.0, WxLimits.windMaxKmh)
            let explicitFeels = numberInRange(entry, "apparent_temperature", WxLimits.tempMinC, WxLimits.tempMaxC)
            if explicitFeels.isFinite {
                hour.feelsC = explicitFeels
            } else if hour.tempC.isFinite {
                hour.feelsC = deriveApparentTempC(
                    tempC: hour.tempC, humidityPct: hour.humidityPct, windKmh: hour.windKmh)
            }
            hour.wmo = mapConditionToWMO(
                condition: entry.string("condition"),
                icon: entry.string("icon"),
                precipMm: precip.precipMm,
                cloudPct: hour.cloudPct
            )
            let hasNumeric =
                hour.tempC.isFinite || hour.feelsC.isFinite || hour.humidityPct.isFinite
                || precip.precipMm.isFinite || precip.precipProb.isFinite || hour.cloudPct.isFinite
                || hour.windKmh.isFinite || hour.gustKmh.isFinite
            guard hasNumeric else { continue }
            if haveOpen && open.tS == precip.tS {
                open.precipMm = precip.precipMm
                open.precipProb = precip.precipProb
                member.addHour(open)
            } else {
                if haveOpen {
                    member.addHour(open)
                }
                if precip.precipMm.isFinite || precip.precipProb.isFinite {
                    member.addHour(precip)
                }
            }
            open = hour
            haveOpen = true
            lastTS = tS
        }
        if haveOpen {
            member.addHour(open)
        }

        if member.hours.isEmpty {
            throw WxError(.notFound, "no usable forecast data")
        }
        var result = try WxSourceResult(providerID: providerID)
        result.members = [member]
        return result
    }

    private static func numberInRange(
        _ obj: WxJSON.Object, _ key: String, _ lo: Double, _ hi: Double
    ) -> Double {
        guard let v = obj.member(key)?.numberInRange(lo, hi) else { return .nan }
        return v == 0.0 ? 0.0 : v
    }

    /// Standard Australian BOM / Steadman apparent temperature approximation from T, RH, and 10m wind.
    static func deriveApparentTempC(tempC: Double, humidityPct: Double, windKmh: Double) -> Double {
        let rh = humidityPct.isFinite ? humidityPct : 65.0
        let windMs = windKmh.isFinite ? (windKmh / 3.6) : 2.0
        let e = (rh / 100.0) * 6.105 * exp((17.27 * tempC) / (237.7 + tempC))
        let at = tempC + 0.33 * e - 0.70 * windMs - 4.00
        return WxLimits.valueInRange(at, WxLimits.tempMinC, WxLimits.tempMaxC) ? at : tempC
    }

    private static func mapConditionToWMO(
        condition: String?, icon: String?, precipMm: Double, cloudPct: Double
    ) -> Int {
        switch condition {
        case "thunderstorm": return 95
        case "hail": return 96
        case "sleet": return 68
        case "snow": return 71
        case "fog": return 45
        case "rain":
            if precipMm.isFinite {
                if precipMm >= 4.0 { return 65 }
                if precipMm >= 0.5 { return 61 }
                return 51
            }
            return 61
        case "dry":
            break
        default:
            break
        }
        if let icon {
            switch icon {
            case "thunderstorm": return 95
            case "hail": return 96
            case "sleet": return 68
            case "snow": return 71
            case "fog": return 45
            case "rain": return 61
            case "cloudy": return 3
            case "partly-cloudy-day", "partly-cloudy-night": return 2
            case "clear-day", "clear-night": return 0
            default: break
            }
        }
        if cloudPct.isFinite {
            if cloudPct >= 85 { return 3 }
            if cloudPct >= 35 { return 2 }
            if cloudPct >= 12 { return 1 }
            return 0
        }
        return -1
    }
}
