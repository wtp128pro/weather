// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsMeteoAlarm.swift - the MeteoAlarm country feeds
// (feeds.meteoalarm.org/api/v1/warnings/feeds-<country>), the CAP warnings of
// the European services that have no point API the app uses, without an API
// key. Pure: the request builder and the parser; the alerts service picks the
// country's feed (WxAlertRegions.feedSlug, AlertRegions.swift), does the HTTP
// and matches each warning's areas (geocodes or inline polygons) to the
// place. Germany and Norway are asked through Bright Sky and MET Norway
// instead.
//
// A feed is a whole country's warnings with about five days of history: most
// warnings have expired, most of the rest are awareness level 1 green ("no
// warning"), and many start in the future. A warning carries one CAP info
// block per language; the English one is used (en-GB, or "en"), else the
// first. Dropped: an expired message (expires at or before now), an ended
// event (the eventEndingTime parameter some issuers add), level 1 green,
// Cancel, Ack and Error messages, any status but Actual, and a warning that a
// later Actual Update or Cancel in the feed references ("sender,identifier,
// sent"): a Test or Exercise message withdraws nothing. A message without
// expires is open-ended (DWD sends some). Expiry and end are checked first, by
// whichever of the two is readable, so nothing else of an expired warning has
// to be. CAP requires a status and a msgType (Alert, Update, Cancel, Ack or
// Error): a warning that would otherwise be current but lacks either or has
// another msgType, lacks an identifier, a name or readable times, references
// or polygons, or is referenced by an Update or Cancel without a status, makes
// the feed unreadable (nil) instead of hiding or showing it.
// Areas: areaDesc, the geocodes as published (EMMA_ID, NUTS2, NUTS3 and
// others) and the polygons, CAP "lat,lon lat,lon ..." rings (Switzerland and
// Israel publish polygons only); the Netherlands and the United Kingdom flag
// warnings whose polygon is more precise than their geocodes.
//
// Terms: MeteoAlarm licence CC BY 4.0, "Data provided by EUMETNET members".
// The feeds send no ETag and max-age=0.

import Foundation

/// The MeteoAlarm country feeds.
public enum WxMeteoAlarm {
    /// The credit the CC BY 4.0 licence requires.
    public static let attribution = "Data provided by EUMETNET members (MeteoAlarm, CC BY 4.0)."

    /// A point of a warning polygon.
    public struct Point: Sendable, Equatable {
        public let lat: Double
        public let lon: Double

        public init(lat: Double, lon: Double) {
            self.lat = lat
            self.lon = lon
        }
    }

    /// A geocode as published ("EMMA_ID" "HR023", "NUTS3" "FR522").
    public struct Geocode: Sendable, Equatable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// One area a warning covers.
    public struct Area: Sendable, Equatable {
        /// The issuer's name for the area; "" when missing.
        public let description: String
        public let geocodes: [Geocode]
        /// Closed rings of at least 4 points (CAP repeats the first point last).
        public let polygons: [[Point]]

        public init(description: String, geocodes: [Geocode], polygons: [[Point]]) {
            self.description = description
            self.geocodes = geocodes
            self.polygons = polygons
        }

        /// The values of the geocodes named `name` ("EMMA_ID", "NUTS2", "NUTS3").
        public func geocodes(named name: String) -> [String] {
            geocodes.filter { $0.name == name }.map(\.value)
        }
    }

    /// A CAP message identifier as referenced by an Update or Cancel ("sender,identifier,sent").
    public struct Reference: Sendable, Equatable, Hashable {
        public let sender: String
        public let identifier: String
        public let sent: String

        public init(sender: String, identifier: String, sent: String) {
            self.sender = sender
            self.identifier = identifier
            self.sent = sent
        }
    }

    /// One current warning of a feed with the areas it covers.
    public struct Warning: Sendable, Equatable {
        /// The alert as shown (id "meteoAlarm:<CAP identifier>").
        public let alert: WxAlert
        /// "Alert" or "Update".
        public let msgType: String
        /// The earlier messages this one updates (none for an Alert).
        public let references: [Reference]
        /// Empty when the issuer gave none: such a warning matches no place.
        public let areas: [Area]
        /// The issuer flagged the polygons as more precise than the geocodes
        /// (the use_polygon_over_geocode parameter).
        public let polygonOverGeocode: Bool

        public init(alert: WxAlert, msgType: String, references: [Reference], areas: [Area],
                    polygonOverGeocode: Bool) {
            self.alert = alert
            self.msgType = msgType
            self.references = references
            self.areas = areas
            self.polygonOverGeocode = polygonOverGeocode
        }
    }

    // MARK: - Request

    /// The warnings feed of a country by its feed name ("france").
    public static func feedURL(slug: String) -> String {
        "https://feeds.meteoalarm.org/api/v1/warnings/feeds-" + slug
    }

    // MARK: - Parser

    private struct Feed: Decodable {
        struct Entry: Decodable {
            let alert: Alert?
        }
        struct Alert: Decodable {
            let identifier: String?
            let sender: String?
            let status: String?
            let msgType: String?
            let references: String?
            let info: [Info]?
        }
        struct Info: Decodable {
            let language: String?
            let event: String?
            let headline: String?
            let description: String?
            let instruction: String?
            let effective: String?
            let onset: String?
            let expires: String?
            let web: String?
            let parameter: [Pair]?
            let area: [AreaJSON]?
        }
        struct Pair: Decodable {
            let valueName: String?
            let value: String?
        }
        struct AreaJSON: Decodable {
            let areaDesc: String?
            let geocode: [Pair]?
            let polygon: [String]?
        }
        let warnings: [Entry]?
    }

    /// The warnings of a feed answer (status `status`) current at `nowS`, in feed order: an
    /// empty array when the country has none. Nil for any other answer, and when a warning
    /// that would be current cannot be read (see the file comment).
    public static func parse(_ data: Data, status: Int, nowS: Int64) -> [Warning]? {
        guard status == 200, let decoded = try? JSONDecoder().decode(Feed.self, from: data),
              let entries = decoded.warnings
        else {
            return nil
        }
        // What every real Update and Cancel supersedes, whether or not it is itself still current;
        // what one without a status may supersede (a warning it references can be neither shown
        // nor hidden). A Test, Exercise, System or Draft message supersedes nothing.
        var superseded = Set<Reference.Key>(), doubtful = Set<Reference.Key>()
        for e in entries {
            guard let a = e.alert, ["update", "cancel"].contains(text(a.msgType).lowercased()) else {
                continue
            }
            let state = text(a.status)
            guard state.isEmpty || WxAlert.isActual(status: state) else {
                continue
            }
            guard let refs = references(a.references) else {
                return nil
            }
            if state.isEmpty {
                doubtful.formUnion(refs.map(\.key))
            } else {
                superseded.formUnion(refs.map(\.key))
            }
        }
        var warnings: [Warning] = []
        for e in entries {
            guard let a = e.alert, let infos = a.info, let info = infos.first(where: {
                text($0.language).lowercased().hasPrefix("en")
            }) ?? infos.first
            else {
                return nil
            }
            let params = info.parameter ?? []
            // Never shown: expired or ended (by whichever time is readable), green, not a warning,
            // not real, superseded. Only then must the rest be readable.
            let expiresAt = time(info.expires), endsAt = time(param("eventEndingTime", params))
            if isOver([expiresAt, endsAt], nowS: nowS) {
                continue
            }
            guard let expires = expiresAt, let ends = endsAt else {
                return nil
            }
            let awareness = param("awareness_level", params)
            let type = text(a.msgType), state = text(a.status)
            guard let level = WxAlert.level(awareness: awareness),
                  !["cancel", "ack", "error"].contains(type.lowercased()),
                  state.isEmpty || WxAlert.isActual(status: state)
            else {
                continue
            }
            let id = text(a.identifier), key = Reference.Key(sender: text(a.sender), identifier: id)
            if superseded.contains(key) {
                continue
            }
            let event = text(info.event), headline = text(info.headline)
            guard !state.isEmpty, ["alert", "update"].contains(type.lowercased()), !doubtful.contains(key),
                  !id.isEmpty, !(event.isEmpty && headline.isEmpty),
                  let onset = time(info.onset), let effective = time(info.effective),
                  let refs = references(a.references), let areas = areas(info.area)
            else {
                return nil
            }
            let alert = WxAlert(
                id: "meteoAlarm:" + id, source: .meteoAlarm, event: event.isEmpty ? headline : event,
                headline: headline.isEmpty ? event : headline, description: text(info.description),
                instruction: text(info.instruction), level: level, issuerSeverity: text(awareness),
                onsetS: onset ?? effective, expiresS: expires, endsS: ends, web: link(info.web))
            warnings.append(Warning(
                alert: alert, msgType: type, references: refs, areas: areas,
                polygonOverGeocode: text(param("use_polygon_over_geocode", params)).lowercased() == "true"))
        }
        return warnings
    }

    // MARK: - Helpers

    /// The value of the first parameter named `name`; nil when absent.
    private static func param(_ name: String, _ params: [Feed.Pair]) -> String? {
        params.first { $0.valueName == name }?.value
    }

    /// The whitespace-separated "sender,identifier,sent" references; nil when one is unreadable.
    private static func references(_ s: String?) -> [Reference]? {
        var refs: [Reference] = []
        for entry in text(s).split(whereSeparator: \.isWhitespace) {
            let f = entry.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, !f[0].isEmpty, !f[1].isEmpty else {
                return nil
            }
            refs.append(Reference(sender: f[0], identifier: f[1], sent: f[2]))
        }
        return refs
    }

    /// The areas of an info block; nil when a polygon is unreadable.
    private static func areas(_ list: [Feed.AreaJSON]?) -> [Area]? {
        var areas: [Area] = []
        for a in list ?? [] {
            var rings: [[Point]] = []
            for p in a.polygon ?? [] {
                guard let ring = polygon(p) else {
                    return nil
                }
                rings.append(ring)
            }
            let codes = (a.geocode ?? []).compactMap { g -> Geocode? in
                let name = text(g.valueName), value = text(g.value)
                return name.isEmpty || value.isEmpty ? nil : Geocode(name: name, value: value)
            }
            areas.append(Area(description: text(a.areaDesc), geocodes: codes, polygons: rings))
        }
        return areas
    }

    /// A CAP polygon "lat,lon lat,lon ..." of at least 4 points; nil when unreadable.
    private static func polygon(_ s: String) -> [Point]? {
        var ring: [Point] = []
        for pair in s.split(whereSeparator: \.isWhitespace) {
            let f = pair.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 2, let lat = Double(f[0]), let lon = Double(f[1]),
                  (-90...90).contains(lat), (-180...180).contains(lon)
            else {
                return nil
            }
            ring.append(Point(lat: lat, lon: lon))
        }
        return ring.count >= 4 ? ring : nil
    }

    /// Whether one of `times` (read by `time(_:)`) is at or before `nowS`; absent and unreadable
    /// times say nothing.
    private static func isOver(_ times: [Int64??], nowS: Int64) -> Bool {
        times.contains { t in
            if case .some(.some(let s)) = t {
                return s <= nowS
            }
            return false
        }
    }

    /// A time that may be absent: .some(nil) when absent or empty, nil when present but unreadable.
    private static func time(_ s: String?) -> Int64?? {
        guard let s, !s.isEmpty else {
            return .some(nil)
        }
        guard let t = WxTime.parseISO8601(s) else {
            return nil
        }
        return .some(t)
    }

    /// Issuer text trimmed of surrounding whitespace; "" when missing.
    private static func text(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An http(s) link, or nil.
    private static func link(_ s: String?) -> String? {
        let t = text(s)
        return t.hasPrefix("https://") || t.hasPrefix("http://") ? t : nil
    }
}

extension WxMeteoAlarm.Reference {
    /// A message is superseded by sender and identifier (the sent time only restates them).
    fileprivate struct Key: Hashable {
        let sender: String
        let identifier: String
    }

    fileprivate var key: Key { Key(sender: sender, identifier: identifier) }
}
