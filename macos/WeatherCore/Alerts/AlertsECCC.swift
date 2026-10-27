// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsECCC.swift - Environment and Climate Change Canada's public weather
// alerts from the GeoMet OGC API (api.weather.gc.ca, collection
// weather-alerts), asked for one point without an API key. Pure: the request
// builder and the parser; the alerts service does the HTTP and gates the
// source by the place's country (CA: the collection answers an empty 200
// anywhere else).
//
// The CQL2 filter INTERSECTS(geometry, POINT(lon lat)) selects the alert
// areas containing the point on the server, so no point-in-polygon pass is
// needed (a bbox query matches by envelope and would need one), and
// skipGeometry drops the area polygons, which are most of the answer. Each
// feature is one alert for one area ("<alert id>_<feature_id>"; ECCC's loader
// puts a fresh UUID there when the area has no feature_id): the alert is the
// part before the first "_" (its id is digits), so it is listed once and keeps
// its id across refreshes.
//
// Currency: the collection keeps an alert whose status_en is "ended" while its
// expiration_datetime is still in the future, so both are checked: status
// ended or cancelled is dropped, and so is an expiration_datetime at or before
// now. issued and continued are live. status_en is the only signal that an
// alert ended early, so an alert that would otherwise be current but carries
// no status_en, or one this parser does not know, makes the answer unreadable
// (nil) instead of being shown or silently dropped. The texts are the English
// ones (*_en); alert_text_en holds the description and the advice together.
// Times: validity_datetime is when the event begins, expiration_datetime when
// the message expires, event_end_datetime when the event is expected to end
// (it may be after the expiry: the alert is reissued before then).
//
// Terms: ECCC Data Server End-use Licence; attribution "Contains information
// licenced under the Data Server End-use Licence of Environment and Climate
// Change Canada."

import Foundation

/// Environment Canada's point alerts (GeoMet OGC API weather-alerts).
public enum WxECCCAlerts {
    /// ECCC's weather site, linked for its alerts (they carry no link).
    public static let weatherURL = "https://weather.gc.ca/"

    /// The attribution the End-use Licence requires.
    public static let attribution = "Contains information licenced under the Data Server End-use Licence of "
        + "Environment and Climate Change Canada."

    // MARK: - Request

    /// The alerts whose areas contain the point, without area geometry, coordinates rounded to 4
    /// decimals (POINT takes longitude first).
    public static func url(lat: Double, lon: Double) -> String {
        String(format: "https://api.weather.gc.ca/collections/weather-alerts/items?f=json&skipGeometry=true"
               + "&limit=100&filter=INTERSECTS(geometry,POINT(%.4f%%20%.4f))", lon, lat)
    }

    // MARK: - Parser

    private struct Response: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let alert_name_en: String?
                let alert_short_name_en: String?
                let alert_text_en: String?
                let risk_colour_en: String?
                let status_en: String?
                let validity_datetime: String?
                let publication_datetime: String?
                let expiration_datetime: String?
                let event_end_datetime: String?
            }
            let id: String?
            let properties: Properties
        }
        let features: [Feature]?
    }

    /// The status_en values of a live alert, and of one that is over.
    private static let liveStatuses: Set<String> = ["issued", "continued"]
    private static let overStatuses: Set<String> = ["ended", "cancelled"]

    /// The coverage of a weather-alerts `items?filter=INTERSECTS(...)` answer (status `status`)
    /// at `nowS`. Ended and cancelled alerts and alerts whose message expired are dropped; an
    /// alert is current until its message expires and its event ends; an alert in several
    /// areas around the point is listed once. An empty answer is `.noAlerts`: the caller gates
    /// by country. Nil for any other answer, and when an alert that is not over lacks an id, a
    /// name, a readable expiry or a known status_en.
    public static func parse(_ data: Data, status: Int, nowS: Int64) -> WxAlertCoverage? {
        guard status == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let features = decoded.features
        else {
            return nil
        }
        var alerts: [WxAlert] = []
        for f in features {
            let p = f.properties
            let state = text(p.status_en).lowercased()
            if overStatuses.contains(state) {
                continue
            }
            guard let expires = WxTime.parseISO8601(p.expiration_datetime) else {
                return nil
            }
            if expires <= nowS {
                continue
            }
            let name = text(p.alert_name_en).isEmpty ? text(p.alert_short_name_en) : text(p.alert_name_en)
            guard liveStatuses.contains(state), let id = alertID(f.id), !name.isEmpty,
                  let onset = time(p.validity_datetime), let published = time(p.publication_datetime),
                  let ends = time(p.event_end_datetime)
            else {
                return nil
            }
            alerts.append(WxAlert(
                id: "eccc:" + id, source: .eccc, event: name, headline: name, description: text(p.alert_text_en),
                instruction: "", level: WxAlert.level(ecccColour: p.risk_colour_en),
                issuerSeverity: text(p.risk_colour_en), onsetS: onset ?? published, expiresS: expires,
                endsS: ends, web: weatherURL))
        }
        var seen = Set<String>()
        let once = alerts.filter { $0.isCurrent(atS: nowS) && seen.insert($0.id).inserted }
        return .covered(once, nowS: nowS)
    }

    // MARK: - Helpers

    /// The alert's id: the feature id up to its first "_" (the area suffix, a feature_id or a
    /// UUID, follows); nil when empty.
    private static func alertID(_ featureKey: String?) -> String? {
        let id = text(featureKey).prefix { $0 != "_" }
        return id.isEmpty ? nil : String(id)
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
}
