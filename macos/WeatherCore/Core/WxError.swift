// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WxError.swift - the error type of every weather module and the shared limits
// and value/id validators. Port of src/core/wx-types.h:20-157 and
// src/core/wx-types.c:10-55 (errors, limits and validation constants,
// wx_value_in_range, wx_id_is_valid).

import Foundation

/// An error of the WX_ERROR domain (src/core/wx-types.h:24-37): a code plus a
/// constant, human-readable message. Messages never contain rejected input.
public struct WxError: Error, Equatable, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    /// The error codes; the raw values are the C ordinals (src/core/wx-types.h:28-37).
    public enum Code: Int, CaseIterable, Sendable {
        /// Connection failed / DNS / TLS / I/O error (WX_ERROR_NETWORK = 0).
        case network = 0
        /// The request exceeded its deadline (WX_ERROR_TIMEOUT = 1).
        case timeout = 1
        /// Unexpected HTTP status, not 404 / 429 (WX_ERROR_HTTP = 2).
        case http = 2
        /// HTTP 429 or provider-signalled throttling (WX_ERROR_RATE_LIMITED = 3).
        case rateLimited = 3
        /// Response/text did not match the expected shape (WX_ERROR_PARSE = 4).
        case parse = 4
        /// Unknown place / HTTP 404 / no usable data (WX_ERROR_NOT_FOUND = 5).
        case notFound = 5
        /// The caller passed a value the API rejects (WX_ERROR_INVALID_ARG = 6).
        case invalidArg = 6
        /// The provider does not cover the request (WX_ERROR_UNSUPPORTED = 7).
        case unsupported = 7
    }

    /// The error code.
    public let code: Code
    /// The message (GError.message). Callers pass constant text, never input.
    public let message: String

    /// Creates an error with `code` and `message`.
    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    /// The message.
    public var description: String { message }

    /// The message (so `localizedDescription` shows it).
    public var errorDescription: String? { message }
}

/// Limits and validation constants (src/core/wx-types.h:57-107) and the value /
/// id validators (src/core/wx-types.h:129,154; src/core/wx-types.c:29-55).
public enum WxLimits {
    /// Longest place / admin / country name, in bytes (WX_PLACE_NAME_MAX).
    public static let placeNameMax = 256
    /// Longest IANA time zone name, in bytes (WX_PLACE_TIMEZONE_MAX).
    public static let placeTimezoneMax = 64
    /// Maximum number of saved places per user (WX_PLACE_MAX).
    public static let placeMax = 50

    /// Maximum number of hourly entries in one member (WX_MEMBER_MAX_HOURS).
    public static let memberMaxHours = 400
    /// Maximum number of 15-minute entries in one member (WX_MEMBER_MAX_QUARTERS).
    public static let memberMaxQuarters = 1536
    /// Longest source_id / model_id, in bytes (WX_ID_MAX).
    public static let idMax = 32

    /// Maximum number of hourly entries in a forecast (WX_FORECAST_MAX_HOURS).
    public static let forecastMaxHours = 400
    /// Maximum number of 15-minute entries in a forecast (WX_FORECAST_MAX_QUARTERS).
    public static let forecastMaxQuarters = memberMaxQuarters
    /// Maximum number of daily entries in a forecast (WX_FORECAST_MAX_DAYS).
    public static let forecastMaxDays = 16
    /// Maximum number of source-status entries in a forecast (WX_FORECAST_MAX_SOURCES).
    public static let forecastMaxSources = 16

    /// Longest source name / attribution text, in bytes (WX_SOURCE_TEXT_MAX).
    public static let sourceTextMax = 256
    /// Longest attribution URL, in bytes (WX_SOURCE_URL_MAX).
    public static let sourceURLMax = 512

    /// Earliest accepted timestamp, 2000-01-01T00:00:00Z, inclusive (WX_TIME_MIN_S).
    public static let timeMinS: Int64 = 946_684_800
    /// Upper bound of accepted timestamps, 2101-01-01T00:00:00Z, EXCLUSIVE (WX_TIME_MAX_S).
    public static let timeMaxS: Int64 = 4_133_980_800

    /// Valid air temperature range, degC (WX_TEMP_MIN_C / WX_TEMP_MAX_C).
    public static let tempMinC = -100.0
    public static let tempMaxC = 70.0
    /// Valid wind / gust speed upper bound, km/h (WX_WIND_MAX_KMH).
    public static let windMaxKmh = 500.0
    /// Valid precipitation rate upper bound, mm per hour (WX_PRECIP_MAX_MM_H).
    public static let precipMaxMmH = 500.0
    /// Valid daily precipitation total upper bound, mm (WX_PRECIP_MAX_MM_DAY = 500 * 24).
    public static let precipMaxMmDay = precipMaxMmH * 24.0
    /// Valid spread between members, degC (WX_TEMP_SPREAD_MAX_C = 70 - (-100)).
    public static let tempSpreadMaxC = tempMaxC - tempMinC
    /// Valid percentage range (WX_PERCENT_MIN / WX_PERCENT_MAX).
    public static let percentMin = 0.0
    public static let percentMax = 100.0

    /// wx_value_in_range: true iff `v` is finite and `lo <= v <= hi` (so false
    /// when any argument is NaN). Out-of-range data is dropped, never clamped.
    public static func valueInRange(_ v: Double, _ lo: Double, _ hi: Double) -> Bool {
        v.isFinite && v >= lo && v <= hi
    }

    /// wx_id_is_valid: true iff the id (read up to its first 0x00 byte, at most
    /// `idMax` + 1 bytes examined) matches `[a-z0-9][a-z0-9_.-]{0,31}`.
    public static func isValidID<Bytes: Collection<UInt8>>(bytes: Bytes) -> Bool {
        let window = Array(bytes.prefix(idMax + 1))
        let length: Int
        if let nul = window.firstIndex(of: 0) {
            length = nul
        } else if window.count <= idMax {
            length = window.count  // the collection ended: its end is the terminator
        } else {
            return false  // memchr found no NUL in idMax + 1 bytes
        }
        if length == 0 {
            return false
        }
        let first = window[0]
        if !((first >= 0x61 && first <= 0x7A) || (first >= 0x30 && first <= 0x39)) {
            return false
        }
        for c in window[0..<length] {
            let ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2E || c == 0x2D
            if !ok {
                return false
            }
        }
        return true
    }

    /// `isValidID(bytes:)` of the UTF-8 bytes of `id`; false for nil.
    public static func isValidID(_ id: String?) -> Bool {
        guard let id else {
            return false
        }
        return isValidID(bytes: id.utf8)
    }
}
