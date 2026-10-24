// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// METNorwayParse.swift - the pure half of the MET Norway locationforecast 2.0
// "complete" provider: identity constants, the request target and cache key
// (coordinates printed "%.4f", which ROUNDS them), the cache freshness, Expires
// cap, request floor and 429 throttle rules, and the response parser. Port of
// src/providers/metno/wx-metno.{h,c} (format_coord, format_coords,
// wx_metno_forecast_path, units_are_expected, details_value, entry_to_hour,
// wx_metno_parse_forecast, entry_is_fresh, the expiry of cache_store,
// request_floor_applies, the throttle test of metno_fetch_async and the clamp
// of clock_now_s). Everything here is pure: no I/O, no clock, no locale.
//
// The stateful provider (cache, request records, shared requests, throttle
// state, HTTP) is not here; it composes these rules.

import Foundation

/// MET Norway constants, pure rules and parser (src/providers/metno/wx-metno.h).
public enum METNorwayParse {
    // MARK: Constants (wx-metno.h:144-156, wx-metno.c:18-24)

    /// Production origin (WX_METNO_BASE_URL).
    public static let baseURL = "https://api.met.no"
    /// User-Agent of every request (WX_METNO_USER_AGENT); the service requires an identifying one.
    public static let userAgent = "weather-app/0.1 (github.com/wtp128pro/weather)"
    /// Provider id and WxMember source id (WX_METNO_PROVIDER_ID).
    public static let providerID = "met-no"
    /// WxMember model id (WX_METNO_MODEL_ID), the model label fixed by the design.
    public static let modelID = "ecmwf"
    /// Most places in the cache, and most places with a request record (WX_METNO_CACHE_MAX).
    public static let cacheMax = 32
    /// Floor between two requests for one place, and the minimum freshness of an
    /// answer, seconds (WX_METNO_MIN_REFRESH_S).
    public static let minRefreshS: Int64 = 600
    /// Time without new requests after an HTTP 429, seconds (WX_METNO_THROTTLE_S).
    public static let throttleS: Int64 = 60
    /// Accept header of every request (METNO_ACCEPT).
    public static let accept = "application/json"
    /// Request target up to the first coordinate (METNO_PATH_PREFIX).
    public static let pathPrefix = "/weatherapi/locationforecast/2.0/complete?lat="
    /// An Expires time is never honoured for longer than this after the answer
    /// that carried it, seconds (METNO_EXPIRES_MAX_S).
    public static let expiresMaxS: Int64 = 86_400
    /// m/s -> km/h (METNO_MS_TO_KMH).
    public static let msToKmh = 3.6
    /// Upper clamp of a clock reading (G_MAXINT64 / 4 in clock_now_s).
    public static let clockMaxS: Int64 = Int64.max / 4

    /// Error messages of the provider and parser (constant text, never body text).
    public enum Message {
        /// wx-metno.c:274 (WX_ERROR_INVALID_ARG).
        public static let fetchTimeOutOfRange = "fetch time out of range"
        /// wx-metno.c:285 (WX_ERROR_PARSE).
        public static let notLocationforecast = "not a locationforecast document"
        /// wx-metno.c:289 (WX_ERROR_PARSE).
        public static let unexpectedUnits = "unexpected units"
        /// wx-metno.c:300 (WX_ERROR_PARSE).
        public static let noUsableData = "no usable forecast data"
        /// wx-metno.c:1173 (WX_ERROR_RATE_LIMITED), the floor without a cache entry.
        public static let floorRefused = "a request for this place was sent less than 10 minutes ago"
        /// wx-metno.c:1179 (WX_ERROR_RATE_LIMITED), the 429 throttle.
        public static let throttled = "requests are paused after HTTP 429"
    }

    // MARK: Request target and cache key (wx-metno.c:89-136, :1150-1152)

    /// format_coord: `v` printed "%.4f" (printf rounding of the binary value)
    /// with '.' as decimal point whatever the locale; "-0.0000" becomes "0.0000".
    /// `v` must be finite (callers check `WxGeo.isValid` first).
    static func coordinateText(_ v: Double) -> String {
        // String(format:) without a locale formats with the C/POSIX conventions
        // ('.' decimal point, no grouping), like g_ascii_formatd.
        let text = String(format: "%.4f", v)
        return text == "-0.0000" ? "0.0000" : text
    }

    /// format_coords: the two coordinate texts of a place, or nil unless
    /// `WxGeo.isValid(lat:lon:)`.
    public static func coordinateTexts(lat: Double, lon: Double) -> (lat: String, lon: String)? {
        guard WxGeo.isValid(lat: lat, lon: lon) else {
            return nil
        }
        return (coordinateText(lat), coordinateText(lon))
    }

    /// wx_metno_forecast_path: "/weatherapi/locationforecast/2.0/complete?lat=<lat>&lon=<lon>"
    /// with both coordinates printed as `coordinateTexts` does (at most 68
    /// bytes), or nil unless `WxGeo.isValid(lat:lon:)`.
    public static func forecastPath(lat: Double, lon: Double) -> String? {
        guard let texts = coordinateTexts(lat: lat, lon: lon) else {
            return nil
        }
        return pathPrefix + texts.lat + "&lon=" + texts.lon
    }

    /// The cache / request-record / shared-request key of a place
    /// (metno_fetch_async, wx-metno.c:1152): "<lat text>,<lon text>". Places
    /// whose texts are identical are the same place. nil unless
    /// `WxGeo.isValid(lat:lon:)`.
    public static func cacheKey(lat: Double, lon: Double) -> String? {
        guard let texts = coordinateTexts(lat: lat, lon: lon) else {
            return nil
        }
        return texts.lat + "," + texts.lon
    }

    // MARK: Cache, floor and throttle rules (wx-metno.c:60-69, :359-365, :509, :534-541, :1177)

    /// clock_now_s's clamp: a clock reading limited to [0, `clockMaxS`], so
    /// sums and differences made with it cannot overflow.
    public static func clampedClockS(_ t: Int64) -> Int64 {
        min(max(t, 0), clockMaxS)
    }

    /// The Expires time a cache entry keeps (cache_store, wx-metno.c:509):
    /// 0 when `expiresS` is 0 or less (none), else `min(expiresS, answerS + expiresMaxS)`.
    /// `expiresS` is the HTTP layer's validated value
    /// (`HTTPPolicy.parseExpires(bytes:nowS:)`, 0 = absent or implausible).
    /// - Precondition: `answerS` is a clamped clock reading (`clampedClockS`).
    public static func storedExpiresS(_ expiresS: Int64, answerS: Int64) -> Int64 {
        expiresS > 0 ? min(expiresS, answerS + expiresMaxS) : 0
    }

    /// entry_is_fresh (wx-metno.c:359-365): an entry answered at `checkedS`
    /// with the stored Expires `expiresS` (0 = none) may be served without a
    /// request at `nowS`: false when `nowS < checkedS` (the clock moved
    /// backwards), else `nowS - checkedS < minRefreshS || nowS < expiresS`.
    /// - Precondition: every time is a clamped clock reading (`clampedClockS`).
    public static func entryIsFresh(nowS: Int64, checkedS: Int64, expiresS: Int64) -> Bool {
        if nowS < checkedS {
            return false
        }
        return nowS - checkedS < minRefreshS || nowS < expiresS
    }

    /// request_floor_applies (wx-metno.c:534-541): true iff a request for the
    /// place was handed to the HTTP layer at `sentS` (nil = no record) fewer
    /// than `minRefreshS` seconds before `nowS`; a record in the future of the
    /// clock does not apply.
    /// - Precondition: every time is a clamped clock reading (`clampedClockS`).
    public static func floorApplies(nowS: Int64, sentS: Int64?) -> Bool {
        guard let sentS, nowS >= sentS else {
            return false
        }
        return nowS - sentS < minRefreshS
    }

    /// The end of the throttle started by an HTTP 429 answered at `nowS`
    /// (on_http_done, wx-metno.c:981): `nowS + throttleS`.
    public static func throttleUntilS(answeredAtS nowS: Int64) -> Int64 {
        nowS + throttleS
    }

    /// The throttle test of metno_fetch_async (wx-metno.c:1177): true iff
    /// `nowS < untilS && untilS - nowS <= throttleS` (a clock earlier than the
    /// 429 answer lifts the throttle). `untilS` 0 = never throttled.
    public static func throttleApplies(nowS: Int64, untilS: Int64) -> Bool {
        nowS < untilS && untilS - nowS <= throttleS
    }

    /// The Last-Modified text a cache entry keeps after an answer
    /// (flight_resolve, wx-metno.c:932-936): the answer's validated
    /// Last-Modified (`HTTPPolicy.usableLastModified(bytes:)`), or, for a 304
    /// that revalidated a cached member, the If-Modified-Since text that was
    /// sent when the answer carried none.
    public static func lastModifiedToStore(
        status: Int, revalidated: Bool, responseLastModified: String?, sentIfModifiedSince: String?
    ) -> String? {
        if status == 304 && revalidated && responseLastModified == nil {
            return sentIfModifiedSince
        }
        return responseLastModified
    }

    // MARK: Parser (wx-metno.c:143-304)

    /// The units the parser converts from (expected_units, wx-metno.c:143-154).
    private static let expectedUnits: [(name: String, unit: String)] = [
        ("air_temperature", "celsius"),
        ("apparent_air_temperature", "celsius"),
        ("cloud_area_fraction", "%"),
        ("relative_humidity", "%"),
        ("wind_speed", "m/s"),
        ("wind_speed_of_gust", "m/s"),
        ("precipitation_amount", "mm"),
    ]

    /// units_are_expected (wx-metno.c:173-187): false iff properties.meta.units
    /// names one of the variables with a value that is not the expected unit
    /// string (byte comparison, like strcmp; a non-string included). A missing
    /// or mistyped units object, or a missing name, is accepted.
    private static func unitsAreExpected(_ props: WxJSON.Object?) -> Bool {
        guard let units = props?.object("meta")?.object("units") else {
            return true
        }
        for expected in expectedUnits {
            guard units.member(expected.name) != nil else {
                continue
            }
            guard let unit = units.string(expected.name), unit.utf8.elementsEqual(expected.unit.utf8) else {
                return false
            }
        }
        return true
    }

    /// details_value (wx-metno.c:210-220): the member times `factor` when the
    /// member is a finite number whose product is finite and within [lo, hi]
    /// (a negative zero becomes +0.0), else NaN.
    private static func detailsValue(
        _ details: WxJSON.Object?, _ name: String, _ factor: Double, _ lo: Double, _ hi: Double
    ) -> Double {
        guard let details, var v = details.number(name) else {
            return .nan
        }
        v *= factor
        if !WxLimits.valueInRange(v, lo, hi) {
            return .nan
        }
        return v == 0.0 ? 0.0 : v
    }

    /// entry_to_hour (wx-metno.c:239-264): the hour of one timeseries element,
    /// or nil when its time does not parse or no value is usable.
    private static func entryToHour(_ entry: WxJSON.Object) -> WxHour? {
        guard let tS = WxTime.parseISO8601(entry.string("time")) else {
            return nil
        }
        let data = entry.object("data")
        let instant = data?.object("instant")?.object("details")
        let next = data?.object("next_1_hours")?.object("details")
        var hour = WxHour()
        hour.tS = tS
        hour.tempC = detailsValue(instant, "air_temperature", 1.0, WxLimits.tempMinC, WxLimits.tempMaxC)
        hour.feelsC = detailsValue(
            instant, "apparent_air_temperature", 1.0, WxLimits.tempMinC, WxLimits.tempMaxC)
        hour.cloudPct = detailsValue(
            instant, "cloud_area_fraction", 1.0, WxLimits.percentMin, WxLimits.percentMax)
        hour.humidityPct = detailsValue(
            instant, "relative_humidity", 1.0, WxLimits.percentMin, WxLimits.percentMax)
        hour.windKmh = detailsValue(instant, "wind_speed", msToKmh, 0.0, WxLimits.windMaxKmh)
        hour.gustKmh = detailsValue(instant, "wind_speed_of_gust", msToKmh, 0.0, WxLimits.windMaxKmh)
        hour.precipMm = detailsValue(next, "precipitation_amount", 1.0, 0.0, WxLimits.precipMaxMmH)
        let usable =
            !hour.tempC.isNaN || !hour.feelsC.isNaN || !hour.cloudPct.isNaN
            || !hour.humidityPct.isNaN || !hour.windKmh.isNaN || !hour.gustKmh.isNaN
            || !hour.precipMm.isNaN
        return usable ? hour : nil
    }

    /// wx_metno_parse_forecast (wx-metno.c:267-304, wx-metno.h:232-284):
    /// parses a locationforecast "complete" document into ONE member with
    /// source "met-no", model "ecmwf" and `fetchedS`.
    ///
    /// The body must be one JSON object (`WxJSON.parse`, at most
    /// `HTTPPolicy.maxBodyBytes` bytes) with an array properties.timeseries;
    /// properties.meta.units, when it names one of the seven variables, must
    /// name the unit converted from. The timeseries is walked in order: an
    /// element becomes an hour when it is an object whose "time" parses
    /// (`WxTime.parseISO8601`), lies on a full hour in 2000..2100 and after the
    /// previous accepted hour, and at least one value is usable; values
    /// outside their ranges are NaN (never clamped), wind and gust are m/s x
    /// 3.6, precipitation comes from next_1_hours, precipProb is NaN and wmo
    /// -1. At most `WxLimits.memberMaxHours` hours are kept.
    ///
    /// - Throws: `.invalidArg` "fetch time out of range" (checked first, before
    ///   the body is looked at); `.parse` with the `WxJSON.parse` messages, or
    ///   "not a locationforecast document", "unexpected units", "no usable
    ///   forecast data". Messages never echo body text.
    public static func parseForecast(_ data: some Collection<UInt8>, fetchedS: Int64) throws(WxError) -> WxMember {
        var member: WxMember
        do {
            member = try WxMember(sourceID: providerID, modelID: modelID, fetchedS: fetchedS)
        } catch {
            throw WxError(.invalidArg, Message.fetchTimeOutOfRange)
        }
        let root = try WxJSON.parseObject(data, maxLength: HTTPPolicy.maxBodyBytes)
        let props = root.object("properties")
        guard let series = props?.array("timeseries") else {
            throw WxError(.parse, Message.notLocationforecast)
        }
        if !unitsAreExpected(props) {
            throw WxError(.parse, Message.unexpectedUnits)
        }
        var i = 0
        while i < series.count && member.hours.count < WxLimits.memberMaxHours {
            if let entry = series[i].object, let hour = entryToHour(entry) {
                member.addHour(hour)
            }
            i += 1
        }
        if member.hours.isEmpty {
            throw WxError(.parse, Message.noUsableData)
        }
        return member
    }
}
