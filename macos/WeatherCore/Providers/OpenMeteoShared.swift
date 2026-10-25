// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoShared.swift - the constants, the model allow-list and the request
// builders shared by the Open-Meteo parsers (OpenMeteoParse.swift) and the
// Open-Meteo provider and place search. Port of the identity strings, the
// model and variable tables and the path builders of
// src/providers/openmeteo/wx-openmeteo.c:14-243 and the constants of
// src/providers/openmeteo/wx-openmeteo.h:180-191, byte for byte.

import Foundation

/// One entry of the compile-time model allow-list (model_table,
/// wx-openmeteo.c:40-49): an unknown model name makes Open-Meteo refuse the
/// whole request (HTTP 400), so requests are built only from these names. The
/// raw value is the API name used in "models=" and in the body keys; the case
/// order is the C table order.
public enum OpenMeteoModel: String, CaseIterable, Sendable {
    case ncepHrrrConus = "ncep_hrrr_conus"
    case ncepNbmConus = "ncep_nbm_conus"
    case gfsSeamless = "gfs_seamless"
    case ecmwfIfs025 = "ecmwf_ifs025"
    case iconSeamless = "icon_seamless"
    case gemSeamless = "gem_seamless"
    case ukmoSeamless = "ukmo_seamless"
    case meteofranceSeamless = "meteofrance_seamless"
    case knmiSeamless = "knmi_seamless"

    /// model_find (wx-openmeteo.c:98-107): the entry whose API name equals
    /// `apiName` byte for byte (case-sensitive, no prefix match); nil for
    /// nil or any other text.
    public init?(apiName: String?) {
        guard let apiName else {
            return nil
        }
        for model in Self.allCases where Array(model.rawValue.utf8) == Array(apiName.utf8) {
            self = model
            return
        }
        return nil
    }

    /// The name in the "models=" parameter and in the body key suffixes.
    public var apiName: String { rawValue }

    /// The WxMember model id of this model's series.
    public var memberID: String {
        switch self {
        case .ncepHrrrConus: return "hrrr"
        case .ncepNbmConus: return "nbm"
        case .gfsSeamless: return "gfs"
        case .ecmwfIfs025: return "ecmwf"
        case .iconSeamless: return "icon"
        case .gemSeamless: return "gem"
        case .ukmoSeamless: return "ukmo"
        case .meteofranceSeamless: return "meteofrance"
        case .knmiSeamless: return "knmi"
        }
    }
}

/// Open-Meteo constants and request builders (wx-openmeteo.h / wx-openmeteo.c).
public enum OpenMeteoShared {
    // MARK: - Identity (wx-openmeteo.h:180, wx-openmeteo.c:14-18)

    /// WX_OPEN_METEO_ID: the provider id, also the source id of every member.
    public static let providerID = "open-meteo"
    /// OPEN_METEO_NAME.
    public static let name = "Open-Meteo"
    /// OPEN_METEO_ATTRIBUTION: the CC BY 4.0 credit line (do not reword).
    public static let attribution = "Weather data by Open-Meteo.com"
    /// OPEN_METEO_ATTRIBUTION_URL.
    public static let attributionURL = "https://open-meteo.com/"
    /// OPEN_METEO_USER_AGENT (the same text as HTTPPolicy.userAgent).
    public static let userAgent = "weather-app/0.1 (github.com/wtp128pro/weather)"
    /// OPEN_METEO_ACCEPT: the Accept header of every request.
    public static let accept = "application/json"

    // MARK: - Hosts and limits (wx-openmeteo.h:182-191, wx-openmeteo.c:21-25)

    /// WX_OPEN_METEO_BASE_URL: the fixed origin of the forecast API.
    public static let baseURL = "https://api.open-meteo.com"
    /// WX_OPEN_METEO_GEOCODING_BASE_URL: the fixed origin of the place search.
    public static let geocodingBaseURL = "https://geocoding-api.open-meteo.com"
    /// WX_OPEN_METEO_MAX_TIME_STEPS: most "time" entries of a forecast body.
    public static let maxTimeSteps = 384
    /// WX_OPEN_METEO_NOWCAST_GRACE_MS: request B's window from the START of a fetch, ms.
    public static let nowcastGraceMs = 2000
    /// WX_OPEN_METEO_SEARCH_MIN_BYTES: shortest accepted search text after trimming, bytes.
    public static let searchMinBytes = 2
    /// WX_OPEN_METEO_SEARCH_MAX_BYTES: longest accepted search text after trimming, bytes.
    public static let searchMaxBytes = 64
    /// MAX_MODELS: most models of one request (the whole allow-list).
    public static let maxModels = 9
    /// SEARCH_COUNT: hits requested from the place search ("count=10").
    public static let searchCount = 10
    /// REASON_MAX_CHARS: longest server error reason put into a message, characters.
    public static let reasonMaxChars = 120
    /// WX_GEOCODER_MAX_HITS (src/net/wx-provider.h:55): most hits a search returns.
    public static let geocoderMaxHits = 20
    /// The model id of the 15-minute nowcast member (request B).
    public static let nowcastModelID = "hrrr15"

    // MARK: - Model choice (wx-openmeteo.c:128-154)

    /// models_for_place: the models of request A for a place, in request
    /// order, and whether the place is in the CONUS branch (which also sends
    /// request B). The coordinates are used as given (the C code passes the
    /// place's lat/lon unrounded).
    public static func models(lat: Double, lon: Double) -> (models: [OpenMeteoModel], conus: Bool) {
        var out: [OpenMeteoModel] = []
        var conus = false
        if WxGeo.inUSNWS(lat: lat, lon: lon) {
            if WxGeo.inCONUS(lat: lat, lon: lon) {
                conus = true
                out.append(.ncepHrrrConus)
                out.append(.ncepNbmConus)
            }
            out.append(.gfsSeamless)
            out.append(.ecmwfIfs025)
            out.append(.iconSeamless)
            out.append(.gemSeamless)
            return (out, conus)
        }
        out.append(.ecmwfIfs025)
        out.append(.iconSeamless)
        out.append(.gemSeamless)
        out.append(.gfsSeamless)
        if WxGeo.inEurope(lat: lat, lon: lon) {
            out.append(.ukmoSeamless)
            out.append(.meteofranceSeamless)
        }
        return (out, conus)
    }

    /// Region-aware model selection and 15-minute sub-hourly nowcast path for a `WxPlace`.
    /// Adds `knmi_seamless` (KNMI HARMONIE-AROME 2 km) across UK, Netherlands, and Germany,
    /// fixes `inCONUS` HRRR/NBM coverage for Canadian cities south of 53N (e.g. Calgary,
    /// Vancouver, Winnipeg, Halifax), and enables 15-minute sub-hourly precipitation
    /// nowcasting across Europe and Canada in addition to CONUS.
    public static func models(for place: WxPlace) -> (models: [OpenMeteoModel], nowcastPath: String?) {
        let region = WxGeo.region(for: place)
        let lat = place.lat
        let lon = place.lon
        switch region {
        case .ukIreland:
            let m: [OpenMeteoModel] = [
                .ukmoSeamless, .ecmwfIfs025, .iconSeamless, .knmiSeamless, .meteofranceSeamless, .gfsSeamless,
                .gemSeamless,
            ]
            return (m, nowcastPath(lat: lat, lon: lon, model: nil))
        case .beneluxNorthSea:
            let m: [OpenMeteoModel] = [
                .knmiSeamless, .iconSeamless, .ecmwfIfs025, .ukmoSeamless, .meteofranceSeamless, .gfsSeamless,
                .gemSeamless,
            ]
            return (m, nowcastPath(lat: lat, lon: lon, model: .knmiSeamless))
        case .centralEurope:
            let m: [OpenMeteoModel] = [
                .iconSeamless, .ecmwfIfs025, .knmiSeamless, .meteofranceSeamless, .ukmoSeamless, .gfsSeamless,
                .gemSeamless,
            ]
            return (m, nowcastPath(lat: lat, lon: lon, model: .iconSeamless))
        case .nordic, .europeOther:
            let m: [OpenMeteoModel] = [
                .ecmwfIfs025, .iconSeamless, .ukmoSeamless, .meteofranceSeamless, .knmiSeamless, .gemSeamless,
                .gfsSeamless,
            ]
            let nc = (lat <= 65.0 && lon >= -11.0 && lon <= 25.0)
                ? nowcastPath(lat: lat, lon: lon, model: nil)
                : nil
            return (m, nc)
        case .canada:
            var m: [OpenMeteoModel] = [.gemSeamless]
            let inHrrrDomain = WxGeo.inCONUS(lat: lat, lon: lon)
            if inHrrrDomain {
                m.append(.ncepHrrrConus)
                m.append(.ncepNbmConus)
            }
            m.append(contentsOf: [.ecmwfIfs025, .iconSeamless, .gfsSeamless])
            let nc = inHrrrDomain
                ? nowcastPath(lat: lat, lon: lon, model: .ncepHrrrConus)
                : nowcastPath(lat: lat, lon: lon, model: nil)
            return (m, nc)
        case .us:
            let c = models(lat: lat, lon: lon)
            return (c.models, c.conus ? nowcastPath(lat: lat, lon: lon) : nil)
        case .world:
            let c = models(lat: lat, lon: lon)
            return (c.models, nil)
        }
    }

    // MARK: - Request paths (wx-openmeteo.c:172-243, :1582-1585)

    /// coord_text: g_ascii_formatd("%.4f", wx_geo_round4(v)), a '.' decimal
    /// point whatever the locale.
    public static func coordText(_ v: Double) -> String {
        String(format: "%.4f", locale: nil, WxGeo.round4(v))
    }

    /// forecast_path: the path and query of request A (hourly multi-model).
    public static func forecastPath(lat: Double, lon: Double, models: [OpenMeteoModel]) -> String {
        let list = models.map(\.apiName).joined(separator: ",")
        return "/v1/forecast?latitude=" + coordText(lat) + "&longitude=" + coordText(lon)
            + "&hourly=temperature_2m,apparent_temperature,relative_humidity_2m,"
            + "precipitation,precipitation_probability,cloud_cover,wind_speed_10m,"
            + "wind_gusts_10m,weather_code&models="
            + list
            + "&timeformat=unixtime&timezone=GMT&forecast_days=10&wind_speed_unit=kmh"
            + "&temperature_unit=celsius&precipitation_unit=mm"
    }

    /// nowcast_path: the path and query of request B (15-minute HRRR precipitation).
    public static func nowcastPath(lat: Double, lon: Double) -> String {
        nowcastPath(lat: lat, lon: lon, model: .ncepHrrrConus)
    }

    /// Region-selectable 15-minute precipitation nowcast path. When `model` is nil,
    /// Open-Meteo's best-match high-resolution 15-minute model (e.g. UKMO 2km /
    /// KNMI HARMONIE / DWD ICON-D2 / ECCC HRDPS) is queried.
    public static func nowcastPath(lat: Double, lon: Double, model: OpenMeteoModel?) -> String {
        let modelParam = model.map { "&models=" + $0.apiName } ?? ""
        return "/v1/forecast?latitude=" + coordText(lat) + "&longitude=" + coordText(lon)
            + "&minutely_15=precipitation" + modelParam + "&forecast_minutely_15=12"
            + "&timeformat=unixtime&timezone=GMT&precipitation_unit=mm"
    }

    /// The place-search path for an already trimmed and validated text
    /// (geocoder_search_async, wx-openmeteo.c:1582-1585):
    /// "/v1/search?name=<escaped>&count=10&language=en&format=json", where
    /// every byte but ALPHA DIGIT - . _ ~ is written as %XX with upper-case
    /// hex (g_uri_escape_string(text, NULL, FALSE)). The text checks (trim,
    /// SEARCH_MIN_BYTES, wx_text_is_usable_name) belong to the caller.
    public static func searchPath(escaping text: String) -> String {
        "/v1/search?name=" + uriEscape(text) + "&count=" + String(searchCount) + "&language=en&format=json"
    }

    /// g_uri_escape_string(text, NULL, FALSE) on the UTF-8 bytes of `text`.
    private static func uriEscape(_ text: String) -> String {
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 3)
        for b in text.utf8 {
            let unreserved = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
                || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
            if unreserved {
                out.append(b)
            } else {
                out.append(0x25)
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
