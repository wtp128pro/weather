// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoParse.swift - the pure parsers of the Open-Meteo bodies: request A
// (hourly multi-model forecast), request B (15-minute nowcast), place-search
// hits and the {"error":true,"reason":...} error body. Port of
// src/providers/openmeteo/wx-openmeteo.c:262-827 (contract:
// src/providers/openmeteo/wx-openmeteo.h:149-164, :289-432).
//
// Semantics kept from C, on purpose:
//  - a forecast stamp T stores the instant variables in bucket T and
//    precipitation / probability in bucket T - 3600 (merged with the previous
//    stamp's instant bucket when that is the same hour); a nowcast stamp T is
//    stored at T - 900;
//  - stamps must be integer-valued numbers in [timeMinS, timeMaxS - 1],
//    multiples of the step and strictly increasing; anything else is skipped;
//  - out-of-range or non-numeric values are NaN (never clamped), -0 is +0,
//    a weather code is an integer-valued number in 0...99, else -1;
//  - a member keeps the first WxLimits.memberMaxHours buckets; a model
//    without any finite numeric value is dropped.
// Every body goes through WxJSON (the json-glib layer), never JSONSerialization.

import Foundation

/// The Open-Meteo body parsers. Pure: usable from any thread.
public enum OpenMeteoParse {
    // MARK: - Forecast (request A)

    /// wx_open_meteo_parse_forecast (wx-openmeteo.c:580-629).
    ///
    /// - Parameters:
    ///   - data: the body bytes.
    ///   - models: the requested models in request order, 1...OpenMeteoShared.maxModels
    ///     (10) of them, none repeated. With one model the body keys are plain
    ///     ("temperature_2m"), with several they carry "_<api name>".
    ///   - fetchedS: fetch time stored in every member, in [timeMinS, timeMaxS).
    /// - Returns: provider "open-meteo" with one member per model that has
    ///   data, in the order of `models`.
    /// - Throws: `.invalidArg` "invalid model list" for an empty, too long or
    ///   repeating list (C: a critical, NULL; checked first), `.invalidArg`
    ///   "invalid fetch time"; the WxJSON `.parse` errors; `.http`
    ///   "Open-Meteo reported an error: <reason>" for an error body; `.parse`
    ///   "response has no hourly time array" or "response has too many time
    ///   steps"; `.notFound` "no usable forecast data".
    public static func forecast<Bytes: Collection<UInt8>>(
        _ data: Bytes, models: [OpenMeteoModel], fetchedS: Int64
    ) throws(WxError) -> WxSourceResult {
        if models.isEmpty || models.count > OpenMeteoShared.maxModels || Set(models).count != models.count {
            throw WxError(.invalidArg, "invalid model list")
        }
        if fetchedS < WxLimits.timeMinS || fetchedS >= WxLimits.timeMaxS {
            throw WxError(.invalidArg, "invalid fetch time")
        }
        let root = try parseRoot(data)
        guard let hourly = root.object("hourly"), let times = hourly.array("time") else {
            throw WxError(.parse, "response has no hourly time array")
        }
        guard let used = readStamps(times, step: 3600, maxSteps: OpenMeteoShared.maxTimeSteps) else {
            throw WxError(.parse, "response has too many time steps")
        }
        var result = try WxSourceResult(providerID: OpenMeteoShared.providerID)
        let suffixed = models.count > 1
        for model in models {
            if let member = try buildMember(hourly, model, suffixed, used, fetchedS) {
                result.members.append(member)
            }
        }
        if result.members.isEmpty {
            throw WxError(.notFound, "no usable forecast data")
        }
        return result
    }

    // MARK: - Nowcast (request B)

    /// wx_open_meteo_parse_nowcast (wx-openmeteo.c:636-683).
    ///
    /// - Returns: member "open-meteo" / "hrrr15" with quarters only.
    /// - Throws: `.invalidArg` "invalid fetch time" (checked first); the WxJSON
    ///   `.parse` errors; `.http` for an error body; `.parse` "response has no
    ///   15-minute data" or "response has too many time steps" (more than
    ///   WxLimits.memberMaxQuarters entries); `.notFound` "no usable nowcast data".
    public static func nowcast<Bytes: Collection<UInt8>>(
        _ data: Bytes, fetchedS: Int64
    ) throws(WxError) -> WxMember {
        if fetchedS < WxLimits.timeMinS || fetchedS >= WxLimits.timeMaxS {
            throw WxError(.invalidArg, "invalid fetch time")
        }
        let root = try parseRoot(data)
        let quarters = root.object("minutely_15")
        guard let times = quarters?.array("time"), let amounts = quarters?.array("precipitation") else {
            throw WxError(.parse, "response has no 15-minute data")
        }
        if times.count > WxLimits.memberMaxQuarters {
            throw WxError(.parse, "response has too many time steps")
        }
        var member = try WxMember(
            sourceID: OpenMeteoShared.providerID, modelID: OpenMeteoShared.nowcastModelID, fetchedS: fetchedS)
        var last: Int64 = 0
        var haveLast = false
        for i in 0..<times.count {
            guard let t = stamp(times[i], step: 900) else {
                continue
            }
            if haveLast && t <= last {
                continue
            }
            last = t
            haveLast = true
            let amount = arrayNumber(amounts, i, 0.0, WxLimits.precipMaxMmH)
            if amount.isNaN {
                continue
            }
            member.addQuarter(WxQuarter(tS: t - 900, precipMm: amount))
        }
        if member.quarters.isEmpty {
            throw WxError(.notFound, "no usable nowcast data")
        }
        return member
    }

    // MARK: - Place search

    /// wx_open_meteo_parse_geocode (wx-openmeteo.c:801-827).
    ///
    /// - Returns: 0...OpenMeteoShared.geocoderMaxHits places, in body order.
    /// - Throws: the WxJSON `.parse` errors; `.http` for an error body;
    ///   `.parse` "unexpected search response shape" when "results" is
    ///   neither missing, null nor an array.
    public static func geocode<Bytes: Collection<UInt8>>(_ data: Bytes) throws(WxError) -> [WxPlace] {
        let root = try parseRoot(data)
        let results = root.member("results")
        var hits: [WxJSON.Node] = []
        switch results {
        case .none, .some(.null):
            break
        case .some(.array(let array)):
            hits = array
        default:
            throw WxError(.parse, "unexpected search response shape")
        }
        var places: [WxPlace] = []
        var i = 0
        while i < hits.count && places.count < OpenMeteoShared.geocoderMaxHits {
            if case .object(let hit) = hits[i], let place = placeFromHit(hit) {
                places.append(place)
            }
            i += 1
        }
        return places
    }

    // MARK: - JSON helpers (wx-openmeteo.c:262-435)

    /// parse_root + api_error: one JSON object (at most HTTPPolicy.maxBodyBytes)
    /// that is not an error body.
    private static func parseRoot<Bytes: Collection<UInt8>>(_ data: Bytes) throws(WxError) -> WxJSON.Object {
        let root = try WxJSON.parseObject(data, maxLength: HTTPPolicy.maxBodyBytes)
        if let reason = root.errorReason(maxChars: OpenMeteoShared.reasonMaxChars) {
            throw WxError(.http, "Open-Meteo reported an error: " + reason)
        }
        return root
    }

    /// array_number: element `i` of `array` as a number in [lo, hi]; NaN when
    /// the array is missing, too short, or the element is not such a number;
    /// -0 becomes +0.
    private static func arrayNumber(_ array: [WxJSON.Node]?, _ i: Int, _ lo: Double, _ hi: Double) -> Double {
        guard let array, i < array.count, let v = array[i].numberInRange(lo, hi) else {
            return .nan
        }
        return v == 0.0 ? 0.0 : v
    }

    /// array_wmo: an integer-valued number in 0...99, else -1.
    private static func arrayWMO(_ array: [WxJSON.Node]?, _ i: Int) -> Int {
        let v = arrayNumber(array, i, 0.0, 99.0)
        return (v.isNaN || v != v.rounded(.down)) ? -1 : Int(v)
    }

    /// stamp_from_node: an integer-valued number in [timeMinS, timeMaxS - 1]
    /// that is a multiple of `step`.
    private static func stamp(_ node: WxJSON.Node, step: Int64) -> Int64? {
        guard let v = node.numberInRange(Double(WxLimits.timeMinS), Double(WxLimits.timeMaxS - 1)) else {
            return nil
        }
        if v != v.rounded(.down) {
            return nil
        }
        let s = Int64(v)
        if s % step != 0 {
            return nil
        }
        return s
    }

    /// The used entries of a "time" array: stamp and index in the array.
    private struct UsedStamp {
        let t: Int64
        let index: Int
    }

    /// read_stamps: nil when `times` has more than `maxSteps` entries, else
    /// the usable, strictly increasing stamps.
    private static func readStamps(_ times: [WxJSON.Node], step: Int64, maxSteps: Int) -> [UsedStamp]? {
        if times.count > maxSteps {
            return nil
        }
        var used: [UsedStamp] = []
        for i in 0..<times.count {
            guard let t = stamp(times[i], step: step) else {
                continue
            }
            if let previous = used.last, t <= previous.t {
                continue
            }
            used.append(UsedStamp(t: t, index: i))
        }
        return used
    }

    // MARK: - Forecast members (wx-openmeteo.c:440-577)

    /// The variables of a forecast body (var_table, wx-openmeteo.c:70-80).
    private enum Variable: Int, CaseIterable {
        case temp, feels, humidity, precip, prob, cloud, wind, gust, wmo

        var key: String {
            switch self {
            case .temp: return "temperature_2m"
            case .feels: return "apparent_temperature"
            case .humidity: return "relative_humidity_2m"
            case .precip: return "precipitation"
            case .prob: return "precipitation_probability"
            case .cloud: return "cloud_cover"
            case .wind: return "wind_speed_10m"
            case .gust: return "wind_gusts_10m"
            case .wmo: return "weather_code"
            }
        }

        var range: (lo: Double, hi: Double) {
            switch self {
            case .temp, .feels: return (WxLimits.tempMinC, WxLimits.tempMaxC)
            case .humidity, .prob, .cloud: return (WxLimits.percentMin, WxLimits.percentMax)
            case .precip: return (0.0, WxLimits.precipMaxMmH)
            case .wind, .gust: return (0.0, WxLimits.windMaxKmh)
            case .wmo: return (0.0, 99.0)
            }
        }
    }

    /// hour_finite_count: finite numbers among the eight numeric fields.
    private static func finiteCount(_ h: WxHour) -> Int {
        let values = [h.tempC, h.feelsC, h.precipMm, h.precipProb, h.cloudPct, h.windKmh, h.gustKmh, h.humidityPct]
        return values.reduce(0) { $0 + ($1.isFinite ? 1 : 0) }
    }

    /// flush_hour: adds a bucket that has a finite value or a weather code;
    /// counts its finite values when the member accepted it.
    private static func flush(_ member: inout WxMember, _ hour: WxHour, _ nValues: inout Int) {
        let finite = finiteCount(hour)
        if finite == 0 && hour.wmo < 0 {
            return
        }
        if member.addHour(hour) {
            nValues += finite
        }
    }

    /// build_member: the member of one model, nil when it has no finite value.
    private static func buildMember(
        _ hourly: WxJSON.Object, _ model: OpenMeteoModel, _ suffixed: Bool, _ used: [UsedStamp], _ fetchedS: Int64
    ) throws(WxError) -> WxMember? {
        var arrays: [Variable: [WxJSON.Node]] = [:]
        for v in Variable.allCases {
            let key = suffixed ? v.key + "_" + model.apiName : v.key
            arrays[v] = hourly.array(key)
        }
        func value(_ v: Variable, _ i: Int) -> Double {
            arrayNumber(arrays[v], i, v.range.lo, v.range.hi)
        }
        var member = try WxMember(sourceID: OpenMeteoShared.providerID, modelID: model.memberID, fetchedS: fetchedS)
        var nValues = 0
        var open = WxHour()
        var haveOpen = false
        for stamp in used {
            let i = stamp.index
            var precip = WxHour()
            precip.tS = stamp.t - 3600
            precip.precipMm = value(.precip, i)
            precip.precipProb = value(.prob, i)
            if haveOpen && open.tS == precip.tS {
                open.precipMm = precip.precipMm
                open.precipProb = precip.precipProb
            } else {
                if haveOpen {
                    flush(&member, open, &nValues)
                }
                open = precip
            }
            flush(&member, open, &nValues)

            open = WxHour()
            open.tS = stamp.t
            haveOpen = true
            open.tempC = value(.temp, i)
            open.feelsC = value(.feels, i)
            open.humidityPct = value(.humidity, i)
            open.cloudPct = value(.cloud, i)
            open.windKmh = value(.wind, i)
            open.gustKmh = value(.gust, i)
            open.wmo = arrayWMO(arrays[.wmo], i)
        }
        if haveOpen {
            flush(&member, open, &nValues)
        }
        return nValues == 0 ? nil : member
    }

    // MARK: - Geocode hits (wx-openmeteo.c:700-798)

    /// hit_optional_string: the sanitised text, "" when it is not a usable name.
    private static func optionalText(_ hit: WxJSON.Object, _ name: String) -> String {
        let text = WxText.sanitize(hit.string(name), maxBytes: WxLimits.placeNameMax)
        if !text.isEmpty && !WxText.isUsableName(text, maxBytes: WxLimits.placeNameMax) {
            return ""
        }
        return text
    }

    /// country_code_or_empty: exactly two ASCII capitals, else "".
    private static func countryCode(_ hit: WxJSON.Object) -> String {
        guard let code = hit.string("country_code") else {
            return ""
        }
        let b = Array(code.utf8)
        let ok = b.count == 2 && b[0] >= 0x41 && b[0] <= 0x5A && b[1] >= 0x41 && b[1] <= 0x5A
        return ok ? code : ""
    }

    /// place_from_hit: a place, or nil when the hit is unusable. A timezone
    /// that WxPlace refuses is replaced by "" (one retry).
    private static func placeFromHit(_ hit: WxJSON.Object) -> WxPlace? {
        guard hit.string("name") != nil, let lat = hit.number("latitude"), let lon = hit.number("longitude") else {
            return nil
        }
        let name = WxText.sanitize(hit.string("name"), maxBytes: WxLimits.placeNameMax)
        let admin1 = optionalText(hit, "admin1")
        let country = optionalText(hit, "country")
        let code = countryCode(hit)
        let timezone = hit.string("timezone")
        if let place = try? WxPlace(
            name: name, admin1: admin1, country: country, countryCode: code, lat: lat, lon: lon, timezone: timezone)
        {
            return place
        }
        if let timezone, !timezone.isEmpty {
            return try? WxPlace(
                name: name, admin1: admin1, country: country, countryCode: code, lat: lat, lon: lon, timezone: "")
        }
        return nil
    }
}
