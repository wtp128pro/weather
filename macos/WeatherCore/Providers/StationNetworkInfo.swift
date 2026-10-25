// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationNetworkInfo.swift - what Settings > Stations and the Help Book say about
// each surface-observation network: its name, where it has stations, what it
// reports, and, for the networks that need the user's own key, how to get one.

import Foundation

/// How the user gets the key of a network that needs one.
public struct WxStationKeyInfo: Sendable, Equatable {
    /// The service the user registers with.
    public let serviceName: String
    /// Where to register.
    public let signUpURL: String
    /// What the field asks for ("API key", "Client ID").
    public let keyLabel: String
    /// The registration steps, in order.
    public let steps: [String]
    /// The free plan's limits, as the service states them.
    public let limits: String
}

extension WxStationNetwork {
    /// The network's name in Settings.
    public var displayName: String {
        switch self {
        case .metar: "Airport reports (METAR)"
        case .nwsASOS: "NWS airport stations (ASOS)"
        case .ecccSWOB: "Environment Canada stations (SWOB)"
        case .iemMesonet: "Iowa Environmental Mesonet"
        case .dwdSYNOP: "Deutscher Wetterdienst"
        case .dmi: "Danish Meteorological Institute"
        case .fmi: "Finnish Meteorological Institute"
        case .smhi: "SMHI"
        case .geosphere: "GeoSphere Austria"
        case .meteoSwiss: "MeteoSwiss"
        case .metOffice: "Met Office"
        case .knmi: "KNMI"
        case .frost: "MET Norway (Frost)"
        case .meteoFrance: "Météo-France"
        case .aemet: "AEMET"
        }
    }

    /// Where the network has stations.
    public var coverageText: String {
        switch self {
        case .metar: "Airports worldwide"
        case .nwsASOS: "United States"
        case .ecccSWOB: "Canada"
        case .iemMesonet: "United States"
        case .dwdSYNOP: "Germany"
        case .dmi: "Denmark, Faroe Islands, Greenland"
        case .fmi: "Finland"
        case .smhi: "Sweden"
        case .geosphere: "Austria"
        case .meteoSwiss: "Switzerland"
        case .metOffice: "United Kingdom"
        case .knmi: "Netherlands"
        case .frost: "Norway"
        case .meteoFrance: "France"
        case .aemet: "Spain"
        }
    }

    /// What the network reports, and how often.
    public var detailText: String {
        switch self {
        case .metar:
            "Hourly airport weather reports (plus specials when the weather changes), from NOAA's Aviation Weather Center."
        case .nwsASOS:
            "The latest 5-minute report of the three nearest US airports, from the National Weather Service."
        case .ecccSWOB:
            "Real-time reports of Environment Canada's climate and airport stations and of partner networks (road weather, provinces)."
        case .iemMesonet:
            "US road-weather, river-gauge, soil-climate and research stations of the NWS forecast office's area, collected by Iowa State University."
        case .dwdSYNOP:
            "10-minute reports of the German weather service's synoptic stations, via Bright Sky."
        case .dmi:
            "10-minute reports of DMI's stations."
        case .fmi:
            "10-minute reports of FMI's stations."
        case .smhi:
            "Hourly reports of SMHI's stations."
        case .geosphere:
            "10-minute reports of GeoSphere Austria's automatic stations (TAWES)."
        case .meteoSwiss:
            "10-minute reports of the SwissMetNet stations."
        case .metOffice:
            "Hourly reports of the Met Office's UK land stations."
        case .knmi:
            "10-minute reports of KNMI's automatic weather stations."
        case .frost:
            "The latest reports of MET Norway's stations, from the Frost API."
        case .meteoFrance:
            "Reports of Météo-France's surface stations."
        case .aemet:
            "Hourly reports of AEMET's automatic stations."
        }
    }

    /// The network needs the user's own key (Settings > Stations).
    public var requiresKey: Bool {
        switch self {
        case .metOffice, .knmi, .frost, .meteoFrance, .aemet: true
        case .metar, .nwsASOS, .ecccSWOB, .iemMesonet, .dwdSYNOP, .dmi, .fmi, .smhi, .geosphere, .meteoSwiss: false
        }
    }
}

extension WxStationNetwork {
    /// How to get the key of a network that needs one; nil for the others.
    public var keyInfo: WxStationKeyInfo? {
        switch self {
        case .metOffice:
            WxStationKeyInfo(
                serviceName: "Met Office Weather DataHub", signUpURL: "https://datahub.metoffice.gov.uk/",
                keyLabel: "API key",
                steps: [
                    "Open the Met Office Weather DataHub and choose Login/Register. Register with your e-mail address and confirm it.",
                    "In the profile menu, choose My subscriptions › Subscribe, pick the Land Observations product, select its free plan and click Subscribe.",
                    "Copy the API key that is shown. It is shown only once; if you lose it, use Manage › Reset Credentials to get a new one.",
                    "Paste the key here and click Save.",
                ],
                limits: "Free plan: up to 360 calls a day (the count resets at 00:00 UTC). The app reads at most 3 stations "
                    + "per place, each at most once an hour, so a few UK places fit within it. About 150 stations, hourly.")
        case .knmi:
            WxStationKeyInfo(
                serviceName: "KNMI Developer Portal", signUpURL: "https://developer.dataplatform.knmi.nl/register/",
                keyLabel: "EDR API key",
                steps: [
                    "Register at the KNMI Developer Portal with an e-mail address that will keep working, and confirm it.",
                    "Log in, open the API Catalog, and on the \u{201C}EDR API\u{201D} card click \u{201C}Request an API key\u{201D}. "
                        + "A key for the Open Data API does not work here.",
                    "Copy the key while it is displayed (it starts with \u{201C}eyJ\u{201D}). The catalog later shows only a short "
                        + "hash, which is not the key.",
                    "Paste the key here and click Save.",
                ],
                limits: "Free, also for commercial use, and it does not expire. 1,000 requests an hour; the app makes about "
                    + "7 an hour per area. About 50 stations measure temperature, every 10 minutes.")
        case .frost:
            WxStationKeyInfo(
                serviceName: "Frost (MET Norway)", signUpURL: "https://frost.met.no/auth/requestCredentials.html",
                keyLabel: "client ID",
                steps: [
                    "Open the Frost \u{201C}Request credentials\u{201D} page and enter your e-mail address.",
                    "The next page shows a client ID and a client secret. Only the client ID is needed; keep both safe.",
                    "Paste the client ID here and click Save.",
                ],
                limits: "Free. There is no fixed quota; MET Norway asks for no more than about one request a second on "
                    + "average. The app makes at most 2 requests per place every 5 minutes, and keeps the station list a day.")
        case .meteoFrance:
            WxStationKeyInfo(
                serviceName: "Météo-France API portal", signUpURL: "https://portail-api.meteofrance.fr/web/en/",
                keyLabel: "API key",
                steps: [
                    "On the Météo-France API portal, choose Sign in › Create account. Pick a user name (not your e-mail "
                        + "address), confirm the e-mail you receive, then sign in with the user name.",
                    "Open the \u{201C}Package Observations\u{201D} API (DonneesPubliquesPaquetObservation), version 2, and click "
                        + "\u{201C}Subscribe to the API for free\u{201D}.",
                    "Only after subscribing: My APIs › Generate Token › choose \u{201C}API Key\u{201D} and enter a validity in "
                        + "seconds (up to 3 years: 94608000). A key generated before subscribing does not work.",
                    "Copy the key, paste it here and click Save.",
                ],
                limits: "Free. 100 requests a minute; the app makes 1 request per 6 minutes for all of France, plus the "
                    + "station list once a day. The subscription must be renewed every 2 years (My APIs › Renew).")
        case .aemet:
            WxStationKeyInfo(
                serviceName: "AEMET OpenData", signUpURL: "https://opendata.aemet.es/centrodedescargas/altaUsuario",
                keyLabel: "API key",
                steps: [
                    "Open AEMET OpenData's API key request page, enter your e-mail address and tick \u{201C}No soy un "
                        + "robot\u{201D} (I am not a robot).",
                    "Within 5 days, click the link in the e-mail \u{201C}Petición generación API Key servicio Aemet "
                        + "OpenData\u{201D}.",
                    "A second e-mail, \u{201C}Alta en el servicio Aemet OpenData\u{201D}, contains the key. Copy all of it: "
                        + "it is long, and the first or last character is easily missed.",
                    "Paste the key here and click Save.",
                ],
                limits: "Free. A key expires 3 months after it is issued (the app shows when); request a new one the same "
                    + "way and use Replace. 40 requests a minute; the app makes 2 requests per 15 minutes for all of Spain. "
                    + "About 830 stations, hourly.")
        case .metar, .nwsASOS, .ecccSWOB, .iemMesonet, .dwdSYNOP, .dmi, .fmi, .smhi, .geosphere, .meteoSwiss:
            nil
        }
    }
}

extension WxStationKeyInfo {
    /// The expiry (UTC unix seconds) written in a key that is a JSON Web Token (AEMET, Météo-France):
    /// the `exp` of its payload; nil for other keys or a token without one. The token is only read,
    /// not verified: the service decides.
    public static func expiry(ofKey key: String) -> Int64? {
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = claims["exp"] as? NSNumber
        else {
            return nil
        }
        return exp.int64Value
    }
}
