// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsPointSources.swift - the alert issuers asked for one point, without
// an API key: NWS (api.weather.gov, US and territories), DWD through Bright
// Sky (api.brightsky.dev, Germany) and MET Norway MetAlerts 2.0 (api.met.no,
// Norway). Pure: request builders and parsers; the alerts service does the
// HTTP (HTTPClient, with the app's identifying User-Agent: NWS answers 403
// without one, MET Norway's terms require one) and gates each source by the
// place's country (WxAlert.pointSource(countryCode:)).
//
// Each parser takes the HTTP status and body and returns the coverage with
// the alerts current at `nowS`: nil when the answer is not a recognizable
// one (a malformed body, an unknown error, an alert it cannot read), never a
// false "no alerts". CAP requires a status: an alert without one could be a
// test or a real warning, so one that would otherwise be current makes the
// answer unreadable (nil); one already over by a readable time is dropped,
// like any explicit Test, Exercise, System or Draft message. Coverage: NWS answers 400 "out of bounds" outside its
// area, Bright Sky 404 "not covered by the DWD"; MET Norway answers an empty
// 200 anywhere outside Norway. Currency: NWS `expires` is the message's,
// `ends` the event's; Bright Sky's `expires` (the expected event end) may be
// null and is then open-ended; MET Norway's validity is `when.interval`
// [start, end] and many alerts start in the future.
//
// Terms: NWS data is open and free to use for any purpose; Bright Sky is free
// with no key, under the DWD's terms of use; MET Norway data is CC BY 4.0
// (credit and link), coordinates at most 4 decimals, at most one alerts poll
// per 10 minutes, honouring Expires and If-Modified-Since.

import Foundation

/// The point-query alert issuers (NWS, Bright Sky, MET Norway).
public enum WxPointAlerts {
    /// The DWD warnings page, linked for Bright Sky alerts (they carry no link).
    public static let dwdWarningsURL = "https://www.dwd.de/"

    // MARK: - Requests

    /// NWS: the active alerts whose zones contain the point (GeoJSON).
    public static func nwsURL(lat: Double, lon: Double) -> String {
        String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f", lat, lon)
    }

    /// Bright Sky: the DWD alerts of the municipality cell containing the point.
    public static func brightSkyURL(lat: Double, lon: Double) -> String {
        String(format: "https://api.brightsky.dev/alerts?lat=%.4f&lon=%.4f", lat, lon)
    }

    /// MET Norway: the current alerts covering the point, in English (Norwegian without
    /// `lang=en`), coordinates rounded to 4 decimals (5 or more are refused with 403).
    public static func metNorwayURL(lat: Double, lon: Double) -> String {
        String(format: "https://api.met.no/weatherapi/metalerts/2.0/current.json?lat=%.4f&lon=%.4f&lang=en",
               lat, lon)
    }

    // MARK: - NWS

    private struct NWSResponse: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let id: String?
                let event: String?
                let headline: String?
                let description: String?
                let instruction: String?
                let severity: String?
                let status: String?
                let messageType: String?
                let effective: String?
                let onset: String?
                let expires: String?
                let ends: String?
                let web: String?
            }
            let id: String?
            let properties: Properties
        }
        let features: [Feature]?
    }

    /// An RFC 7807 problem (NWS errors) or a FastAPI error (Bright Sky).
    private struct Problem: Decodable {
        let detail: String?
    }

    /// The coverage of an NWS `alerts/active?point=` answer (status `status`) at `nowS`. HTTP 400
    /// "out of bounds" is not covered; Test, Exercise, System and Draft messages and Cancel, Ack
    /// and Error message types are dropped; an alert is current until its message expires and
    /// its event ends. Nil for any other answer, and when an alert lacks an id, a name or a
    /// readable expiry, or lacks a status and is not over.
    public static func parseNWS(_ data: Data, status: Int, nowS: Int64) -> WxAlertCoverage? {
        if status == 400 {
            return isProblem(data, containing: "out of bounds") ? .notCovered : nil
        }
        guard status == 200, let decoded = try? JSONDecoder().decode(NWSResponse.self, from: data),
              let features = decoded.features
        else {
            return nil
        }
        var alerts: [WxAlert] = []
        for f in features {
            let p = f.properties
            let state = text(p.status)
            guard state.isEmpty || WxAlert.isActual(status: state),
                  !["cancel", "ack", "error"].contains(p.messageType?.lowercased() ?? "")
            else {
                continue
            }
            if state.isEmpty {
                if isOver([time(p.expires), time(p.ends)], nowS: nowS) {
                    continue
                }
                return nil
            }
            let event = text(p.event), headline = text(p.headline)
            guard let id = p.id ?? f.id, !id.isEmpty, !(event.isEmpty && headline.isEmpty),
                  let expires = WxTime.parseISO8601(p.expires),
                  let ends = time(p.ends), let onset = time(p.onset), let effective = time(p.effective)
            else {
                return nil
            }
            alerts.append(WxAlert(
                id: "nws:" + id, source: .nws, event: event.isEmpty ? headline : event,
                headline: headline.isEmpty ? event : headline, description: text(p.description),
                instruction: text(p.instruction), level: WxAlert.level(nwsSeverity: p.severity),
                issuerSeverity: text(p.severity), onsetS: onset ?? effective, expiresS: expires, endsS: ends,
                web: link(p.web)))
        }
        return .covered(alerts, nowS: nowS)
    }

    // MARK: - Bright Sky (DWD)

    /// An id published as a number or a string (Bright Sky's `alert_id` is documented as the CAP
    /// identifier string but served as an integer).
    private struct FlexibleID: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int64.self) {
                value = String(n)
            } else {
                value = try c.decode(String.self)
            }
        }
    }

    private struct BrightSkyResponse: Decodable {
        struct Alert: Decodable {
            let id: FlexibleID?
            let alert_id: FlexibleID?
            let status: String?
            let effective: String?
            let onset: String?
            let expires: String?
            let severity: String?
            let event_en: String?
            let headline_en: String?
            let description_en: String?
            let instruction_en: String?
        }
        let alerts: [Alert]?
    }

    /// The coverage of a Bright Sky `alerts?lat=&lon=` answer (status `status`) at `nowS`, from
    /// the English (`*_en`) texts. HTTP 404 "not covered" is not covered; `status` test is
    /// dropped; a null `expires` is open-ended and kept; a null severity is unknown. Nil for
    /// any other answer, and when an alert lacks an id or a name or has an unreadable time, or
    /// lacks a status and is not over.
    public static func parseBrightSky(_ data: Data, status: Int, nowS: Int64) -> WxAlertCoverage? {
        if status == 404 {
            return isProblem(data, containing: "not covered") ? .notCovered : nil
        }
        guard status == 200, let decoded = try? JSONDecoder().decode(BrightSkyResponse.self, from: data),
              let items = decoded.alerts
        else {
            return nil
        }
        var alerts: [WxAlert] = []
        for a in items {
            let state = text(a.status)
            guard state.isEmpty || WxAlert.isActual(status: state) else {
                continue
            }
            if state.isEmpty {
                if isOver([time(a.expires)], nowS: nowS) {
                    continue
                }
                return nil
            }
            let event = text(a.event_en), headline = text(a.headline_en)
            guard let id = (a.alert_id ?? a.id)?.value, !id.isEmpty, !(event.isEmpty && headline.isEmpty),
                  let expires = time(a.expires), let onset = time(a.onset), let effective = time(a.effective)
            else {
                return nil
            }
            alerts.append(WxAlert(
                id: "dwd:" + id, source: .dwd, event: event.isEmpty ? headline : event,
                headline: headline.isEmpty ? event : headline, description: text(a.description_en),
                instruction: text(a.instruction_en), level: WxAlert.level(dwdSeverity: a.severity),
                issuerSeverity: text(a.severity), onsetS: onset ?? effective, expiresS: expires, endsS: nil,
                web: dwdWarningsURL))
        }
        return .covered(alerts, nowS: nowS)
    }

    // MARK: - MET Norway MetAlerts

    private struct METResponse: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let id: String?
                let title: String?
                let event: String?
                let eventAwarenessName: String?
                let description: String?
                let instruction: String?
                let awareness_level: String?
                let status: String?
                let type: String?
                let eventEndingTime: String?
                let web: String?
            }
            struct When: Decodable {
                let interval: [String]?
            }
            let properties: Properties
            let when: When?
        }
        let features: [Feature]?
    }

    /// The coverage of a MetAlerts `current.json?lat=&lon=&lang=en` answer (status `status`) at
    /// `nowS`. Valid from `when.interval[0]` to `when.interval[1]` (the expiry); Test status,
    /// Cancel type and green levels are dropped. An empty answer is `.noAlerts` whether or not
    /// the point is in Norway: the caller gates by country. Nil for any other answer, and when
    /// an alert lacks an id, a name or a readable interval, or lacks a status and is not over.
    public static func parseMETNorway(_ data: Data, status: Int, nowS: Int64) -> WxAlertCoverage? {
        guard status == 200, let decoded = try? JSONDecoder().decode(METResponse.self, from: data),
              let features = decoded.features
        else {
            return nil
        }
        var alerts: [WxAlert] = []
        for f in features {
            let p = f.properties
            let state = text(p.status)
            guard state.isEmpty || WxAlert.isActual(status: state), p.type?.lowercased() != "cancel",
                  let level = WxAlert.level(awareness: p.awareness_level)
            else {
                continue
            }
            if state.isEmpty {
                let interval = f.when?.interval ?? []
                let end: Int64?? = interval.count == 2 ? time(interval[1]) : nil
                if isOver([end, time(p.eventEndingTime)], nowS: nowS) {
                    continue
                }
                return nil
            }
            let event = text(p.eventAwarenessName).isEmpty ? text(p.event) : text(p.eventAwarenessName)
            let headline = text(p.title)
            guard let id = p.id, !id.isEmpty, !(event.isEmpty && headline.isEmpty),
                  let interval = f.when?.interval, interval.count == 2,
                  let start = WxTime.parseISO8601(interval[0]), let end = WxTime.parseISO8601(interval[1]),
                  let ends = time(p.eventEndingTime)
            else {
                return nil
            }
            alerts.append(WxAlert(
                id: "metno:" + id, source: .metNorway, event: event.isEmpty ? headline : event,
                headline: headline.isEmpty ? event : headline, description: text(p.description),
                instruction: text(p.instruction), level: level, issuerSeverity: text(p.awareness_level),
                onsetS: start, expiresS: end, endsS: ends, web: link(p.web)))
        }
        return .covered(alerts, nowS: nowS)
    }

    // MARK: - Helpers

    /// Whether `data` is an error object whose detail contains `phrase` (case-insensitive).
    private static func isProblem(_ data: Data, containing phrase: String) -> Bool {
        guard let p = try? JSONDecoder().decode(Problem.self, from: data), let detail = p.detail else {
            return false
        }
        return detail.range(of: phrase, options: .caseInsensitive) != nil
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
