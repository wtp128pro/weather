// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Place.swift - a validated, geocoded location. Port of WxPlace
// (src/core/wx-types.h:159-300, src/core/wx-types.c:180-407).
//
// Input model (fidelity with NUL-terminated C strings): every text argument is
// read as UTF-8 bytes up to its first 0x00 byte, and only the stored prefix is
// kept, so "Mia\0mi" is the place "Mia" exactly as in C. A nil argument
// behaves like a NULL pointer. Validation and its order (name, region,
// country, country code, coordinates, time zone) are the C rules; the first
// failing rule decides the message, which never contains the rejected text.

import Foundation

/// A geocoded location (WxPlace). Every instance satisfies the wx_place_new()
/// rules: the only way to make one is the throwing initialiser, so a copy
/// never needs re-validation.
///
/// name, admin1 and country are DISPLAY text: never use them as a path
/// component, a command-line option or a format string. The country code is
/// "" or two ASCII capitals, the time zone is "" or IANA-shaped, and `key` is
/// numeric.
public struct WxPlace: Equatable, Hashable, Sendable {
    /// Place name: 1...256 bytes of usable text (WxText.isUsableName).
    public let name: String
    /// State / region, "" when unknown.
    public let admin1: String
    /// Country name, "" when unknown.
    public let country: String
    /// "" or two ASCII upper-case letters.
    public let countryCode: String
    /// Degrees north, [-90, 90].
    public let lat: Double
    /// Degrees east, [-180, 180].
    public let lon: Double
    /// "" or an IANA-shaped zone name of at most 64 bytes.
    public let timezone: String
    /// True when this place represents a user-specified street address or custom-named location
    /// (such as "Home", "Work", "Friend's place"), allowing multiple locations within the same city.
    public var isCustomLocation: Bool = false
    /// Optional user-assigned label (e.g. "Home", "Work", "Friend's place").
    public var customName: String = ""
    /// Optional resolved street address or locality description (e.g. "1600 Pennsylvania Ave NW, Washington, DC").
    public var streetAddress: String = ""

    /// wx_place_new() on Swift strings: validates and creates a place. A nil
    /// optional argument becomes "".
    ///
    /// - Throws: `WxError` with code `.invalidArg` and a constant message
    ///   ("invalid place name", "invalid region name", "invalid country name",
    ///   "invalid country code", "coordinates out of range", "invalid time zone
    ///   name") for the first rule that fails.
    public init(
        name: String?,
        admin1: String? = nil,
        country: String? = nil,
        countryCode: String? = nil,
        lat: Double,
        lon: Double,
        timezone: String? = nil
    ) throws(WxError) {
        try self.init(
            nameBytes: Self.boundedBytes(name, WxLimits.placeNameMax),
            admin1Bytes: Self.boundedBytes(admin1, WxLimits.placeNameMax),
            countryBytes: Self.boundedBytes(country, WxLimits.placeNameMax),
            countryCodeBytes: Self.boundedBytes(countryCode, 2),
            lat: lat,
            lon: lon,
            timezoneBytes: Self.boundedBytes(timezone, WxLimits.placeTimezoneMax)
        )
    }

    /// wx_place_new() on raw bytes (for input that may not be valid UTF-8).
    /// Each argument ends at its first 0x00 byte or at the end of the array.
    ///
    /// - Throws: as `init(name:admin1:country:countryCode:lat:lon:timezone:)`.
    public init(
        nameBytes: [UInt8]?,
        admin1Bytes: [UInt8]? = nil,
        countryBytes: [UInt8]? = nil,
        countryCodeBytes: [UInt8]? = nil,
        lat: Double,
        lon: Double,
        timezoneBytes: [UInt8]? = nil
    ) throws(WxError) {
        guard let nameBytes, WxText.isUsableName(bytes: nameBytes, maxBytes: WxLimits.placeNameMax) else {
            throw WxError(.invalidArg, "invalid place name")
        }
        if !Self.optionalTextOK(admin1Bytes) {
            throw WxError(.invalidArg, "invalid region name")
        }
        if !Self.optionalTextOK(countryBytes) {
            throw WxError(.invalidArg, "invalid country name")
        }
        if !Self.countryCodeOK(countryCodeBytes) {
            throw WxError(.invalidArg, "invalid country code")
        }
        if !WxGeo.isValid(lat: lat, lon: lon) {
            throw WxError(.invalidArg, "coordinates out of range")
        }
        if !Self.timezoneOK(timezoneBytes) {
            throw WxError(.invalidArg, "invalid time zone name")
        }
        self.name = Self.cString(nameBytes)
        self.admin1 = Self.cString(admin1Bytes)
        self.country = Self.cString(countryBytes)
        // memset + copy of cc[0], cc[1] (src/core/wx-types.c:330-334): "" or two letters.
        let cc = Self.cString(countryCodeBytes)
        self.countryCode = cc.isEmpty ? "" : String(decoding: Array(cc.utf8.prefix(2)), as: UTF8.self)
        self.lat = lat
        self.lon = lon
        self.timezone = Self.cString(timezoneBytes)
    }

    /// wx_place_key: the stable identity key, "%.4f,%.4f" of the coordinates
    /// rounded by `WxGeo.round4` (so -0 prints as 0.0000) with a '.' decimal
    /// point whatever the locale, e.g. "25.7617,-80.1918". Only [0-9.,-]; it
    /// may START with '-', so prefix it before using it in a file name.
    public var key: String {
        Self.fixed4(WxGeo.round4(lat)) + "," + Self.fixed4(WxGeo.round4(lon))
    }

    /// wx_place_label: "Name, Admin1, Country" with empty parts omitted
    /// ("Miami, Florida, United States", "Reykjavik, Iceland", "Oslo").
    public var label: String {
        var label = name
        if !admin1.isEmpty {
            label += ", " + admin1
        }
        if !country.isEmpty {
            label += ", " + country
        }
        return label
    }

    /// Primary display title (e.g. "Home", "Work", "Friend's place", street line, or city name).
    public var displayTitle: String {
        !customName.isEmpty ? customName : name
    }

    /// Subtitle describing the street address or region/country underneath the primary title.
    public var displayAddressSubtitle: String {
        var parts: [String] = []
        if !admin1.isEmpty {
            parts.append(admin1)
        } else if !streetAddress.isEmpty && streetAddress != name {
            parts.append(streetAddress)
        }
        if !country.isEmpty {
            let lastPart = parts.last ?? ""
            if !lastPart.localizedCaseInsensitiveContains(country) {
                parts.append(country)
            }
        }
        return parts.joined(separator: ", ")
    }

    /// Returns a copy of this place with a custom location label (e.g. "Home", "Work", "Friend's place")
    /// and/or resolved street address, preserving the underlying address so the custom name can be
    /// edited or cleared at any time.
    public func withCustomLocation(
        customName: String?,
        streetAddress: String? = nil,
        isCustomLocation: Bool = true
    ) throws(WxError) -> WxPlace {
        let cleanCustom = WxText.sanitize(
            customName?.trimmingCharacters(in: .whitespacesAndNewlines),
            maxBytes: WxLimits.placeNameMax
        )
        let underlyingAddress: String = {
            if let streetAddress {
                let s = WxText.sanitize(
                    streetAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                    maxBytes: WxLimits.placeNameMax
                )
                if !s.isEmpty { return s }
            }
            if !self.streetAddress.isEmpty {
                return self.streetAddress
            }
            if !self.customName.isEmpty && !self.admin1.isEmpty {
                return self.admin1
            }
            if !self.admin1.isEmpty {
                return WxText.sanitize("\(self.name), \(self.admin1)", maxBytes: WxLimits.placeNameMax)
            }
            return self.name
        }()

        let newName: String
        let newAdmin1: String
        if !cleanCustom.isEmpty && WxText.isUsableName(cleanCustom, maxBytes: WxLimits.placeNameMax) {
            newName = cleanCustom
            newAdmin1 = WxText.isUsableName(underlyingAddress, maxBytes: WxLimits.placeNameMax)
                ? underlyingAddress
                : self.admin1
        } else {
            if let comma = underlyingAddress.firstIndex(of: ",") {
                let head = String(underlyingAddress[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = String(underlyingAddress[underlyingAddress.index(after: comma)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                newName = WxText.isUsableName(head, maxBytes: WxLimits.placeNameMax) ? head : self.name
                newAdmin1 = WxText.isUsableName(tail, maxBytes: WxLimits.placeNameMax) ? tail : ""
            } else {
                newName = WxText.isUsableName(underlyingAddress, maxBytes: WxLimits.placeNameMax)
                    ? underlyingAddress
                    : self.name
                // The customise branch above stores the street address as admin1;
                // keeping that copy would label the cleared place "X, X, Country".
                newAdmin1 = (self.admin1 == underlyingAddress) ? "" : self.admin1
            }
        }

        var updated = try WxPlace(
            name: newName,
            admin1: newAdmin1.isEmpty ? nil : newAdmin1,
            country: self.country.isEmpty ? nil : self.country,
            countryCode: self.countryCode.isEmpty ? nil : self.countryCode,
            lat: self.lat,
            lon: self.lon,
            timezone: self.timezone.isEmpty ? nil : self.timezone
        )
        updated.customName = (!cleanCustom.isEmpty && WxText.isUsableName(cleanCustom, maxBytes: WxLimits.placeNameMax))
            ? cleanCustom
            : ""
        updated.streetAddress = WxText.isUsableName(underlyingAddress, maxBytes: WxLimits.placeNameMax)
            ? underlyingAddress
            : ""
        updated.isCustomLocation = isCustomLocation || !updated.customName.isEmpty
        return updated
    }

    /// Returns a copy of this place at slightly adjusted coordinates (used when two distinct custom
    /// locations share the exact same 4-decimal-place rounded coordinate key).
    public func withCoordinates(lat: Double, lon: Double) throws(WxError) -> WxPlace {
        var updated = try WxPlace(
            name: self.name,
            admin1: self.admin1.isEmpty ? nil : self.admin1,
            country: self.country.isEmpty ? nil : self.country,
            countryCode: self.countryCode.isEmpty ? nil : self.countryCode,
            lat: lat,
            lon: lon,
            timezone: self.timezone.isEmpty ? nil : self.timezone
        )
        updated.isCustomLocation = self.isCustomLocation
        updated.customName = self.customName
        updated.streetAddress = self.streetAddress
        return updated
    }

    // MARK: - Private helpers

    /// "%.4f" without localisation (g_ascii_formatd): '.' is always the decimal point.
    private static func fixed4(_ v: Double) -> String {
        String(format: "%.4f", locale: nil, v)
    }

    /// The UTF-8 bytes of `s`, at most `limit` + 1 of them (the C validators
    /// never look further; anything longer without a NUL is rejected either way).
    private static func boundedBytes(_ s: String?, _ limit: Int) -> [UInt8]? {
        guard let s else {
            return nil
        }
        return Array(s.utf8.prefix(limit + 1))
    }

    /// The bytes before the first 0x00 (all of them without one).
    private static func cPrefix(_ bytes: [UInt8]?) -> ArraySlice<UInt8> {
        guard let bytes else {
            return []
        }
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return bytes[..<end]
    }

    /// g_strdup(s != NULL ? s : ""): the C string as a Swift string. Only
    /// called after validation, so the bytes are valid UTF-8.
    private static func cString(_ bytes: [UInt8]?) -> String {
        String(decoding: cPrefix(bytes), as: UTF8.self)
    }

    /// The byte at `i` of the C string, 0 at and after its terminator.
    private static func cByte(_ s: ArraySlice<UInt8>, _ i: Int) -> UInt8 {
        i < s.count ? s[s.startIndex + i] : 0
    }

    /// optional_text_ok (src/core/wx-types.c:192-196): nil, "" or a usable name.
    private static func optionalTextOK(_ bytes: [UInt8]?) -> Bool {
        guard let bytes else {
            return true
        }
        if bytes.isEmpty || bytes[0] == 0 {
            return true
        }
        return WxText.isUsableName(bytes: bytes, maxBytes: WxLimits.placeNameMax)
    }

    /// country_code_ok (src/core/wx-types.c:209-215): nil, "" or exactly two
    /// ASCII upper-case letters.
    private static func countryCodeOK(_ bytes: [UInt8]?) -> Bool {
        guard let bytes else {
            return true
        }
        let cc = cPrefix(bytes)
        if cByte(cc, 0) == 0 {
            return true
        }
        let c0 = cByte(cc, 0)
        let c1 = cByte(cc, 1)
        return c0 >= 0x41 && c0 <= 0x5A && c1 >= 0x41 && c1 <= 0x5A && cByte(cc, 2) == 0
    }

    /// timezone_ok (src/core/wx-types.c:236-263): nil, "" or "/"-separated
    /// components, each starting with an ASCII letter and continuing with
    /// [A-Za-z0-9_+-]; no leading, trailing or doubled '/'; at most 64 bytes.
    private static func timezoneOK(_ bytes: [UInt8]?) -> Bool {
        guard let bytes else {
            return true
        }
        // memchr(tz, '\0', WX_PLACE_TIMEZONE_MAX + 1)
        let window = bytes.prefix(WxLimits.placeTimezoneMax + 1)
        let length: Int
        if let nul = window.firstIndex(of: 0) {
            length = nul
        } else if bytes.count <= WxLimits.placeTimezoneMax {
            length = bytes.count  // the array ended: its end is the terminator
        } else {
            return false
        }
        var atComponentStart = true
        for c in bytes[0..<length] {
            if c == 0x2F {  // '/'
                if atComponentStart {  // leading '/' or an empty component ("//")
                    return false
                }
                atComponentStart = true
                continue
            }
            let letter = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
            if atComponentStart && !letter {  // also rejects ".", ".." and "-x"
                return false
            }
            if !(letter || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2B || c == 0x2D) {
                return false
            }
            atComponentStart = false
        }
        return length == 0 || !atComponentStart  // "" is fine, a trailing '/' is not
    }
}
