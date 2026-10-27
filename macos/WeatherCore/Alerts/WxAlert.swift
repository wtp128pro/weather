// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WxAlert.swift - one official weather alert for a place, normalized across
// the keyless issuers (NWS; DWD via Bright Sky; MET Norway MetAlerts;
// Environment Canada; MeteoAlarm), the per-place coverage result and the one
// severity scale the app shows. Pure value types: the parsers
// (AlertsPointSources.swift and the feed parsers) build them; alerts are kept
// in memory only, never in forecasts.json.
//
// Severity: the issuer's own awareness colour or level wins wherever one is
// published (DWD, MET Norway, ECCC, MeteoAlarm); the CAP severity is used only
// for NWS, which publishes no colours. CAP severity cannot be mapped the same
// way everywhere: MeteoAlarm issuers pair one CAP severity with different
// colours (DWD Moderate is orange, Meteo-France Moderate is yellow).
// Currency: an alert is shown only while its message has not expired and its
// event has not ended; test and exercise messages, green "no warning" levels
// and cancellations are never alerts.

import Foundation

/// One current official weather alert.
public struct WxAlert: Sendable, Equatable, Identifiable {
    /// The issuer the alert came from.
    public enum Source: String, Sendable, CaseIterable {
        /// US National Weather Service (api.weather.gov), US and territories.
        case nws
        /// Deutscher Wetterdienst through Bright Sky (api.brightsky.dev), Germany.
        case dwd
        /// MET Norway MetAlerts 2.0 (api.met.no), Norway.
        case metNorway
        /// Environment and Climate Change Canada (api.weather.gc.ca), Canada.
        case eccc
        /// MeteoAlarm country feeds (feeds.meteoalarm.org), other European countries.
        case meteoAlarm
    }

    /// The normalized level, lowest to highest; the sidebar shows the highest of a place.
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        /// The issuer gave no usable level (NWS "Unknown", a DWD alert without severity).
        case unknown = 0
        /// Below yellow: NWS Minor, ECCC statements (no colour).
        case minor = 1
        case yellow = 2
        case orange = 3
        case red = 4

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// "<source>:<issuer id>": the same message keeps its id across refreshes.
    public let id: String
    public let source: Source
    /// The event name ("High Surf Advisory", "gale-force gusts", "Storm").
    public let event: String
    /// The issuer's headline; the event name when it gave none.
    public let headline: String
    /// "" when missing.
    public let description: String
    /// The recommended actions; "" when missing.
    public let instruction: String
    public let level: Level
    /// The issuer's own level text as published ("Minor", "moderate", "2; yellow; Moderate");
    /// "" when missing.
    public let issuerSeverity: String
    /// When the event begins (onset, else the effective time), UTC unix seconds; nil when unknown.
    /// It may lie in the future: such an alert reads "from <onset>", not "now".
    public let onsetS: Int64?
    /// When the message stops being valid, UTC unix seconds; nil when the issuer gave none
    /// (open-ended DWD alerts).
    public let expiresS: Int64?
    /// When the event is expected to end, UTC unix seconds; nil when the issuer gave none.
    public let endsS: Int64?
    /// The issuer's page for the alert or its warnings; nil when it gave none.
    public let web: String?

    public init(id: String, source: Source, event: String, headline: String, description: String,
                instruction: String, level: Level, issuerSeverity: String, onsetS: Int64?,
                expiresS: Int64?, endsS: Int64?, web: String?) {
        self.id = id
        self.source = source
        self.event = event
        self.headline = headline
        self.description = description
        self.instruction = instruction
        self.level = level
        self.issuerSeverity = issuerSeverity
        self.onsetS = onsetS
        self.expiresS = expiresS
        self.endsS = endsS
        self.web = web
    }

    /// The end to show ("until ..."): the event end, else the message expiry; nil when open-ended.
    public var untilS: Int64? { endsS ?? expiresS }

    /// Whether the alert may be shown as current at `nowS`: neither its message has expired nor its
    /// event has ended (an alert expiring at `nowS` is expired).
    public func isCurrent(atS nowS: Int64) -> Bool {
        if let e = expiresS, e <= nowS {
            return false
        }
        if let e = endsS, e <= nowS {
            return false
        }
        return true
    }

    // MARK: - The severity scale

    /// NWS: the CAP severity, on the MeteoAlarm convention (Extreme red, Severe orange, Moderate
    /// yellow); NWS itself publishes no colours.
    public static func level(nwsSeverity s: String?) -> Level {
        switch s?.lowercased() {
        case "extreme": return .red
        case "severe": return .orange
        case "moderate": return .yellow
        case "minor": return .minor
        default: return .unknown
        }
    }

    /// DWD (Bright Sky): DWD's four levels pass through as severity; minor is level 1 of 4
    /// (yellow), moderate level 2 (orange), severe and extreme levels 3 and 4 (red).
    public static func level(dwdSeverity s: String?) -> Level {
        switch s?.lowercased() {
        case "extreme", "severe": return .red
        case "moderate": return .orange
        case "minor": return .yellow
        default: return .unknown
        }
    }

    /// MET Norway and MeteoAlarm: the awareness level "N; colour; Name" ("2; yellow; Moderate"),
    /// by its colour, else by its number (2 yellow, 3 orange, 4 red). Nil for green (level 1),
    /// which is no warning and is dropped; unknown when missing or unreadable.
    public static func level(awareness text: String?) -> Level? {
        let fields = (text ?? "").split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let byColour = fields.count > 1 ? fields[1] : ""
        let byNumber = ["1": "green", "2": "yellow", "3": "orange", "4": "red"][fields.first ?? ""] ?? ""
        switch byColour.isEmpty ? byNumber : byColour {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return nil
        default: return .unknown
        }
    }

    /// ECCC: the risk colour (risk_colour_en); a statement without a colour is minor.
    public static func level(ecccColour c: String?) -> Level {
        switch c?.trimmingCharacters(in: .whitespaces).lowercased() ?? "" {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "": return .minor
        default: return .unknown
        }
    }

    /// Whether a CAP status is a real alert: only "Actual" is; Test, Exercise, System and Draft
    /// messages (and a missing status) are never shown.
    public static func isActual(status: String?) -> Bool {
        status?.lowercased() == "actual"
    }

    // MARK: - Coverage

    /// The point-query issuer for an ISO 3166-1 alpha-2 country code: NWS for the US and its
    /// territories (PR, VI, GU, AS, MP, UM), DWD for DE, MET Norway for NO; nil elsewhere. The
    /// answer still decides for NWS and Bright Sky (Wake Island, UM, is out of NWS bounds). MET
    /// Norway answers an empty 200 outside Norway, so only the country says it covers a place;
    /// Svalbard and Jan Mayen (SJ) are not claimed (vendor-silent).
    public static func pointSource(countryCode: String) -> Source? {
        switch countryCode.uppercased() {
        case "US", "PR", "VI", "GU", "AS", "MP", "UM": return .nws
        case "DE": return .dwd
        case "NO": return .metNorway
        default: return nil
        }
    }
}

/// What an issuer says about a place.
public enum WxAlertCoverage: Sendable, Equatable {
    /// It covers the place and has current alerts for it (never empty; highest level first).
    case alerts([WxAlert])
    /// It covers the place and has no current alert for it.
    case noAlerts
    /// It does not cover the place (it said so).
    case notCovered

    /// `.alerts` of the alerts current at `nowS` (highest level, then earliest onset, first), or
    /// `.noAlerts` when none is.
    public static func covered(_ alerts: [WxAlert], nowS: Int64) -> WxAlertCoverage {
        let current = alerts.filter { $0.isCurrent(atS: nowS) }.sorted {
            ($1.level.rawValue, $0.onsetS ?? .min, $0.id) < ($0.level.rawValue, $1.onsetS ?? .min, $1.id)
        }
        return current.isEmpty ? .noAlerts : .alerts(current)
    }

    /// The current alerts; empty unless `.alerts`.
    public var alerts: [WxAlert] {
        if case .alerts(let a) = self {
            return a
        }
        return []
    }
}
