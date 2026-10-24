// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// NWSParse.swift - the pure parsers of the National Weather Service provider:
// the /points and /gridpoints response bodies. Port of wx_nws_parse_points and
// wx_nws_parse_gridpoints (src/providers/nws/wx-nws.c:113-339, contract in
// src/providers/nws/wx-nws.h:29-48 and :139-195).
//
// The rules are the C ones, unchanged: the same four units, the same value
// ranges ("drop, never clamp"), precipitation divided evenly over the hours of
// its interval, intervals at most 31 days and never zero, starts on the hour,
// whole-hour durations, first element wins where elements overlap, at most
// 400 elements and 400 distinct hours per layer, the union of the layers'
// hours ascending and cut at 400, and the C error order and messages (which
// never echo body content). Strings (member names, the unit, the grid id) are
// compared by their UTF-8 bytes like C strcmp, never by Unicode equivalence.
//
// Only gridId, gridX and gridY are read from a /points body: every other
// member, including the server-supplied forecastGridData URL, is ignored, so a
// server cannot steer the next request. The caller builds the /gridpoints
// path from the returned grid cell alone.

/// The pure parsers of the NWS (api.weather.gov) provider (wx-nws.h:139-195).
/// Thread-safe: no state.
public enum NWSParse {
    /// Provider id, member source id and member model id (WX_NWS_ID, wx-nws.h:72).
    public static let id = "nws"

    /// Largest accepted gridX / gridY (NWS_GRID_COORD_MAX, wx-nws.c:24).
    public static let gridCoordMax: UInt32 = 999

    /// Seconds per hourly bucket (NWS_HOUR_S, wx-nws.c:25).
    static let hourS: Int64 = 3600

    /// The forecast grid cell of a point (WxNwsGrid, wx-nws.h:83-90). A value
    /// of this type is always valid: `gridID` is exactly three ASCII capital
    /// letters and `x`, `y` are in 0...`gridCoordMax`.
    public struct Grid: Equatable, Hashable, Sendable {
        /// Forecast office: three ASCII capital letters.
        public let gridID: String
        /// Grid column, 0...999.
        public let x: UInt32
        /// Grid row, 0...999.
        public let y: UInt32

        /// A grid cell, or nil when `gridID` is not exactly three ASCII
        /// capitals (compared by UTF-8 bytes) or a coordinate exceeds
        /// `gridCoordMax`.
        public init?(gridID: String, x: UInt32, y: UInt32) {
            let bytes = Array(gridID.utf8)
            guard bytes.count == 3, bytes.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }),
                x <= NWSParse.gridCoordMax, y <= NWSParse.gridCoordMax
            else {
                return nil
            }
            self.gridID = gridID
            self.x = x
            self.y = y
        }
    }

    /// Error message of a /points body without a valid cell (wx-nws.c:143).
    static let messageNoGrid = "no valid forecast grid in response"
    /// Error message of a /gridpoints body without `properties` (wx-nws.c:303).
    static let messageNoProperties = "response has no properties"
    /// Error message of a /gridpoints body without one usable value (wx-nws.c:335).
    static let messageNoData = "response has no usable forecast"

    // MARK: - /points

    /// Extracts properties.gridId (exactly three ASCII capitals) and
    /// properties.gridX / properties.gridY (integral numbers 0...999) from a
    /// /points body (wx_nws_parse_points, wx-nws.c:125-149). Everything else
    /// is ignored, including any URL the server supplies. At most
    /// `HTTPPolicy.maxBodyBytes` bytes are accepted and exactly the bytes of
    /// `data` are read.
    ///
    /// - Throws: `.parse` with WxJSON's fixed messages for a body that is not
    ///   a JSON object, else `.parse` "no valid forecast grid in response".
    ///   Messages never echo body content.
    public static func parsePoints<Bytes: Collection<UInt8>>(_ data: Bytes) throws(WxError) -> Grid {
        let root = try WxJSON.parseObject(data, maxLength: HTTPPolicy.maxBodyBytes)
        let props = root.object("properties")
        guard let id = props?.string("gridId"),
            let x = gridCoord(props, "gridX"), let y = gridCoord(props, "gridY"),
            let grid = Grid(gridID: id, x: x, y: y)
        else {
            throw WxError(.parse, messageNoGrid)
        }
        return grid
    }

    /// grid_coord (wx-nws.c:113-122): the member when it is a finite integral
    /// number in 0...gridCoordMax, else nil.
    private static func gridCoord(_ props: WxJSON.Object?, _ name: String) -> UInt32? {
        guard let v = props?.number(name), v >= 0.0, v <= Double(gridCoordMax),
            v == v.rounded(.down)
        else {
            return nil
        }
        return UInt32(v)
    }

    // MARK: - /gridpoints

    /// The WxHour field a layer fills (offsetof(WxHour, ...) in wx-nws.c:164-178).
    private enum Field: Sendable {
        case temp, feels, humidity, cloud, wind, gust, probability, precipitation

        func store(_ value: Double, in hour: inout WxHour) {
            switch self {
            case .temp: hour.tempC = value
            case .feels: hour.feelsC = value
            case .humidity: hour.humidityPct = value
            case .cloud: hour.cloudPct = value
            case .wind: hour.windKmh = value
            case .gust: hour.gustKmh = value
            case .probability: hour.precipProb = value
            case .precipitation: hour.precipMm = value
            }
        }
    }

    /// One grid layer that becomes a field of WxHour (Layer, wx-nws.c:155-162).
    private struct Layer: Sendable {
        /// Member of "properties".
        let name: String
        /// The only accepted unit.
        let uom: String
        /// Valid range of the stored (per hour) value.
        let lo: Double
        let hi: Double
        let field: Field
        /// The value is a total over the interval: divide it among the hours.
        let total: Bool
    }

    /// The eight layers read, in the C order (layers[], wx-nws.c:164-178).
    private static let layers: [Layer] = [
        Layer(name: "temperature", uom: "wmoUnit:degC", lo: WxLimits.tempMinC, hi: WxLimits.tempMaxC,
              field: .temp, total: false),
        Layer(name: "apparentTemperature", uom: "wmoUnit:degC", lo: WxLimits.tempMinC, hi: WxLimits.tempMaxC,
              field: .feels, total: false),
        Layer(name: "relativeHumidity", uom: "wmoUnit:percent", lo: WxLimits.percentMin, hi: WxLimits.percentMax,
              field: .humidity, total: false),
        Layer(name: "skyCover", uom: "wmoUnit:percent", lo: WxLimits.percentMin, hi: WxLimits.percentMax,
              field: .cloud, total: false),
        Layer(name: "windSpeed", uom: "wmoUnit:km_h-1", lo: 0.0, hi: WxLimits.windMaxKmh,
              field: .wind, total: false),
        Layer(name: "windGust", uom: "wmoUnit:km_h-1", lo: 0.0, hi: WxLimits.windMaxKmh,
              field: .gust, total: false),
        Layer(name: "probabilityOfPrecipitation", uom: "wmoUnit:percent", lo: WxLimits.percentMin,
              hi: WxLimits.percentMax, field: .probability, total: false),
        Layer(name: "quantitativePrecipitation", uom: "wmoUnit:mm", lo: 0.0, hi: WxLimits.precipMaxMmH,
              field: .precipitation, total: true),
    ]

    /// Builds the one member (source "nws", model "nws", `fetchedS`, wmo -1,
    /// no quarters) of a /gridpoints body (wx_nws_parse_gridpoints,
    /// wx-nws.c:291-339; rules in wx-nws.h:29-48). At most
    /// `HTTPPolicy.maxBodyBytes` bytes are accepted and exactly the bytes of
    /// `data` are read.
    ///
    /// - Returns: a member with 1...400 strictly ascending hours, each a
    ///   multiple of 3600 with at least one finite value.
    /// - Throws: in this order: `.parse` (WxJSON's messages, or "response has
    ///   no properties"); `.invalidArg` "fetch time out of range" when
    ///   `fetchedS` is outside [timeMinS, timeMaxS); `.notFound` "response has
    ///   no usable forecast" when no layer yields a usable value.
    public static func parseGridpoints<Bytes: Collection<UInt8>>(
        _ data: Bytes, fetchedS: Int64
    ) throws(WxError) -> WxMember {
        let root = try WxJSON.parseObject(data, maxLength: HTTPPolicy.maxBodyBytes)
        guard let props = root.object("properties") else {
            throw WxError(.parse, messageNoProperties)
        }
        var member = try WxMember(sourceID: id, modelID: id, fetchedS: fetchedS)

        var table: [Int64: WxHour] = [:]
        for layer in layers {
            let object = props.object(layer.name)
            guard let values = object?.array("values"), let uom = object?.string("uom"),
                uom.utf8.elementsEqual(layer.uom.utf8)
            else {
                continue
            }
            collect(layer, values, into: &table)
        }

        for t in table.keys.sorted() {
            guard let hour = table[t], member.addHour(hour) else {
                break
            }
        }
        if member.hours.isEmpty {
            throw WxError(.notFound, messageNoData)
        }
        return member
    }

    /// element_value (wx-nws.c:199-219): validates one element and computes
    /// the per-hour value, or nil when the element is not usable.
    private static func elementValue(
        _ layer: Layer, _ element: WxJSON.Node
    ) -> (start: Int64, hours: Int, value: Double)? {
        guard let object = element.object,
            let interval = WxTime.parseInterval(object.string("validTime")),
            interval.start % hourS == 0, interval.duration % hourS == 0,
            var v = object.member("value")?.number
        else {
            return nil
        }
        let hours = interval.duration / hourS
        if layer.total {
            v /= Double(hours)
        }
        guard WxLimits.valueInRange(v, layer.lo, layer.hi) else {
            return nil
        }
        return (interval.start, Int(hours), v == 0.0 ? 0.0 : v)
    }

    /// layer_collect (wx-nws.c:238-265): expands the first
    /// `WxLimits.memberMaxHours` elements of one layer into `table`, the
    /// first element winning each hour, at most `memberMaxHours` distinct
    /// hours of this layer, buckets outside [timeMinS, timeMaxS) dropped.
    private static func collect(_ layer: Layer, _ values: [WxJSON.Node], into table: inout [Int64: WxHour]) {
        let cap = WxLimits.memberMaxHours
        var seen = Set<Int64>()
        for element in values.prefix(cap) {
            // Once `cap` hours are taken no later element can add one; C keeps
            // validating the rest without effect, so stopping here gives the
            // same table.
            if seen.count >= cap {
                break
            }
            guard let e = elementValue(layer, element) else {
                continue
            }
            for h in 0..<e.hours {
                if seen.count >= cap {
                    break
                }
                let t = e.start + Int64(h) * hourS
                if !WxHour.timeInRange(t) || seen.contains(t) {
                    continue
                }
                seen.insert(t)
                layer.field.store(e.value, in: &table[t, default: WxHour(tS: t)])
            }
        }
    }
}
