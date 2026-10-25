// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// LiveStationFetcher.swift - dynamic discovery and real-time observation fetching
// from physical local weather & air-quality stations for any (lat, lon) coordinate:
//
// 1. NOAA Aviation Weather Center Global METAR API (aviationweather.gov/api/data/metar)
//    + NWS Official Station Observations API (api.weather.gov/stations/{id}/observations/latest):
//    discovers all nearby ICAO/WMO physical weather stations (ASOS/AWOS/SYNOP) within
//    a bounding box around (lat, lon), upgrades the nearest US station with 5-minute
//    ASOS laser-ceilometer observations from api.weather.gov, and blends temperature,
//    dewpoint/humidity, apparent temperature (Heat Index / Wind Chill), wind speed &
//    gusts, altitude-weighted cloud cover layers, present weather (rain, thunderstorm,
//    snow, fog, drizzle), and hourly precipitation using inverse-distance-squared weighting.
// 2. US EPA AirNow / State DEP ArcGIS FeatureServer (services.arcgis.com/cJ9YHowT8TU7DUyn):
//    discovers nearby physical ground air-quality monitors (PM2.5, PM10, O3) within
//    45 km and computes an inverse-distance-weighted US AQI with 24h comparison,
//    falling back to Open-Meteo's Air Quality API when outside station coverage.
// 3. Calibrated Hourly Sky Cover & 15-Minute Radar Nowcast:
//    fetches NWS meteorologist-calibrated hourly sky forecasts (US) and Open-Meteo
//    multi-altitude cloud layers (cloud_cover_low / mid / high) + 15-minute radar
//    precipitation so upper-tropospheric cirrus never falsely shows 100% Overcast
//    in the 48-hour strip or Clouds card.

import Foundation
import Observation
import WeatherCore

/// Real-time local station observations, calibrated hourly cloud cover, and air quality for a place.
struct LiveStationSnapshot: Sendable, Equatable {
    /// Observed air temperature in °C.
    var tempC: Double?
    /// Observed or derived apparent ("feels like") temperature in °C.
    var feelsC: Double?
    /// Observed relative humidity (0...100%).
    var humidityPct: Double?
    /// Observed sustained wind speed in km/h.
    var windKmh: Double?
    /// Observed wind gusts in km/h.
    var gustKmh: Double?
    /// Effective visual cloud cover (0...100%), weighted by cloud layer altitude so high
    /// thin cirrus (>= 18,000 ft) does not falsely report 100% overcast.
    var cloudPct: Double?
    /// Observed sky/weather condition at the station.
    var condition: WxCondition?
    /// Observed hourly precipitation rate in mm/h.
    var precipMmH: Double?
    /// 15-minute radar precipitation samples (tS, mm/h) for the next 2 hours.
    var radarQuarters: [WxQuarter] = []
    /// Calibrated effective visual cloud cover (%) by hour timestamp (UTC unix seconds).
    var calibratedHourlyCloudPct: [Int64: Double] = [:]
    /// Primary weather station ICAO/WMO identifier (e.g. "KMIA").
    var stationID: String?
    /// Human-readable primary weather station name (e.g. "Miami Intl").
    var stationName: String?
    /// Distance in km from the place to the primary weather station.
    var stationDistanceKm: Double?
    /// Real-time air quality card from local EPA AirNow monitors (or Open-Meteo fallback).
    var airQuality: DetailViewModel.AirQualityCard?

    /// Applies the live station observations to a `DetailViewModel.ForecastPage`.
    func apply(
        to page: DetailViewModel.ForecastPage,
        place: AppModel.Place
    ) -> DetailViewModel.ForecastPage {
        let units = place.units
        let nowS = place.nowS
        let placeZone = WxFormat.Zone(timezone: place.place.timezone)
        let forecast = place.forecast
        let baseCurrent = forecast.flatMap { WxBlend.now($0, nowS: nowS) }
        let isDay = baseCurrent?.isDay ?? WxGeo.sunIsUp(lat: place.place.lat, lon: place.place.lon, t: nowS)

        let liveTempC = tempC ?? baseCurrent?.tempC ?? .nan
        let liveHumidity = humidityPct ?? baseCurrent?.humidityPct ?? .nan
        let liveWindKmh = windKmh ?? baseCurrent?.windKmh ?? .nan
        let liveGustKmh = gustKmh ?? baseCurrent?.gustKmh ?? .nan
        let liveFeelsC = feelsC ?? (liveTempC.isFinite
            ? Self.computeFeelsLikeC(
                tempC: liveTempC,
                humidityPct: liveHumidity.isFinite ? liveHumidity : 50.0,
                windKmh: liveWindKmh.isFinite ? liveWindKmh : 0.0
            )
            : (baseCurrent?.feelsC ?? .nan))
        let liveCloudPct = cloudPct ?? baseCurrent?.cloudPct ?? .nan
        let livePrecipMmH = precipMmH ?? baseCurrent?.precipMm ?? .nan

        // Determine effective current condition from station observation + cloud cover.
        let resolvedCondition: WxCondition = {
            if let cond = condition, cond != .unknown {
                let isDrySky: Bool = switch cond {
                case .clear, .mostlyClear, .partlyCloudy, .mostlyCloudy, .overcast: true
                default: false
                }
                if isDrySky && liveCloudPct.isFinite {
                    return WxConditionRules.cloudCondition(liveCloudPct)
                }
                return cond
            }
            if liveCloudPct.isFinite {
                return WxConditionRules.cloudCondition(liveCloudPct)
            }
            return page.now.conditionCode
        }()

        let entry = WxConditionSymbol.entry(resolvedCondition, isDay: isDay)
        let conditionLabel = WxConditionRules.label(resolvedCondition)

        // Update Today's High/Low if the live station temperature exceeds or undercuts the model range.
        var updatedHighLow = page.now.highLow
        var updatedDays = page.days
        if let forecast, liveTempC.isFinite {
            if let todayIndex = forecast.days.firstIndex(where: {
                $0.startS <= nowS && nowS < WxFormat.localDayEnd($0.startS, zone: placeZone)
            }) {
                var todayDay = forecast.days[todayIndex]
                if !todayDay.tempMaxC.isFinite || liveTempC > todayDay.tempMaxC {
                    todayDay.tempMaxC = liveTempC
                }
                if !todayDay.tempMinC.isFinite || liveTempC < todayDay.tempMinC {
                    todayDay.tempMinC = liveTempC
                }
                updatedHighLow = WxFormat.highLowLabel(
                    day: todayDay,
                    forecast: forecast,
                    nowS: nowS,
                    timezone: place.place.timezone,
                    units: units
                )
                if !updatedDays.isEmpty, updatedDays[0].day == "Today" {
                    let row0 = updatedDays[0]
                    var day0Cond = row0.conditionCode
                    var day0Sym = row0.symbolName
                    var day0Gtk = row0.gtkIconName
                    // If Today's icon is a dry sky class and we have calibrated cloud cover, refine Today's sky icon.
                    if WxConditionSymbol.precipitationRank(day0Cond) == 0 && day0Cond != .fog,
                       liveCloudPct.isFinite
                    {
                        let todayEnd = WxFormat.localDayEnd(todayDay.startS, zone: placeZone)
                        var cloudSamples: [Double] = [liveCloudPct]
                        for (tS, cPct) in calibratedHourlyCloudPct where tS >= nowS && tS < todayEnd {
                            cloudSamples.append(cPct)
                        }
                        let avgCloud = cloudSamples.reduce(0.0, +) / Double(cloudSamples.count)
                        day0Cond = WxConditionRules.cloudCondition(avgCloud)
                        let dayEntry = WxConditionSymbol.entry(day0Cond, isDay: true)
                        day0Sym = dayEntry.symbolName
                        day0Gtk = dayEntry.gtkIconName
                    }
                    updatedDays[0] = DetailViewModel.DayRow(
                        startS: row0.startS,
                        day: row0.day,
                        symbolName: day0Sym,
                        gtkIconName: day0Gtk,
                        rain: row0.rain,
                        low: WxFormat.temp(todayDay.tempMinC, units: units, withUnit: false),
                        high: WxFormat.temp(todayDay.tempMaxC, units: units, withUnit: false),
                        tooltip: row0.tooltip,
                        conditionCode: day0Cond
                    )
                }
            }
        }

        let gustPart = (liveGustKmh.isFinite && liveWindKmh.isFinite && liveGustKmh >= liveWindKmh + 4.0)
            ? ", gusts " + WxFormat.wind(liveGustKmh, units: units)
            : ""
        let windString = "Wind " + WxFormat.wind(liveWindKmh, units: units) + gustPart
            + " \u{00B7} Humidity " + WxFormat.percent(liveHumidity)

        let updatedNow = DetailViewModel.Now(
            symbolName: entry.symbolName,
            gtkIconName: entry.gtkIconName,
            iconAccessibilityLabel: conditionLabel,
            temperature: liveTempC.isFinite
                ? WxFormat.temp(liveTempC, units: units, withUnit: true)
                : page.now.temperature,
            condition: conditionLabel,
            feelsLike: liveFeelsC.isFinite
                ? "Feels like " + WxFormat.temp(liveFeelsC, units: units, withUnit: false)
                : page.now.feelsLike,
            highLow: updatedHighLow,
            wind: windString,
            conditionCode: resolvedCondition,
            isDay: isDay
        )

        // Update Clouds card with observed cloud cover, calibrated lookahead sentence, and station note.
        let updatedClouds: DetailViewModel.CloudCard = {
            guard liveCloudPct.isFinite else { return page.clouds }
            let cover = "Cloud cover " + WxFormat.percent(liveCloudPct) + " \u{00B7} "
                + WxConditionRules.cloudLabel(liveCloudPct)
            let baseSentence = Self.cloudSentence(
                liveCloudPct: liveCloudPct,
                calibratedHourlyCloudPct: calibratedHourlyCloudPct,
                forecast: forecast,
                nowS: nowS,
                zone: placeZone,
                fallback: page.clouds.sentence
            )
            let stationTag = Self.stationShortTag(
                id: stationID,
                name: stationName,
                distanceKm: stationDistanceKm,
                units: units
            )
            let sentence = stationTag.map { "\(baseSentence) \u{00B7} Observed at \($0)" } ?? baseSentence
            return DetailViewModel.CloudCard(cover: cover, sentence: sentence)
        }()

        // Update Rain card if live station or 15-min radar reports active precipitation
        // that the hourly model forecast missed, and ensure the 2-hour nowcast chart
        // renders whenever sub-hourly 15-minute radar quarters are available.
        let resolvedNowcast: RainChartData = {
            if page.rain.nowcast.hasData || radarQuarters.isEmpty {
                return page.rain.nowcast
            }
            return RainChartData(
                hours: forecast?.hours ?? [],
                quarters: radarQuarters,
                units: units,
                nowS: nowS,
                view: .nowcast,
                zone: placeZone
            )
        }()

        let updatedRain: DetailViewModel.RainCard = {
            let isLivePrecip = WxConditionSymbol.precipitationRank(resolvedCondition) > 0
                || (livePrecipMmH.isFinite && livePrecipMmH >= 0.1)
            if isLivePrecip && page.rain.headline.hasPrefix("No rain") {
                let stationNote = Self.stationShortTag(
                    id: stationID,
                    name: stationName,
                    distanceKm: stationDistanceKm,
                    units: units
                )
                let rateText = (livePrecipMmH.isFinite && livePrecipMmH > 0)
                    ? WxFormat.precip(livePrecipMmH, units: units) + "/h"
                    : conditionLabel.lowercased()
                let detail = stationNote.map { "Live observation (\($0)): \(rateText)." }
                    ?? "Live station observation: \(rateText)."
                return DetailViewModel.RainCard(
                    headline: "\(conditionLabel) reported now",
                    detail: detail,
                    nowcast: resolvedNowcast,
                    hourly: page.rain.hourly
                )
            }
            if page.rain.headline.hasPrefix("No rain"),
               let firstWet = radarQuarters.first(where: { $0.tS > nowS && $0.precipMm >= 0.1 })
            {
                let minutes = max(1, (firstWet.tS - nowS + 59) / 60)
                if minutes <= 90 {
                    return DetailViewModel.RainCard(
                        headline: "Rain starting in \(minutes) minute\(minutes == 1 ? "" : "s")",
                        detail: "Detected by high-resolution 15-minute precipitation radar.",
                        nowcast: resolvedNowcast,
                        hourly: page.rain.hourly
                    )
                }
            }
            if resolvedNowcast != page.rain.nowcast {
                return DetailViewModel.RainCard(
                    headline: page.rain.headline,
                    detail: page.rain.detail,
                    nowcast: resolvedNowcast,
                    hourly: page.rain.hourly
                )
            }
            return page.rain
        }()

        // Update the 48-hour strip:
        // - Card 0 ("Now") gets the live station temperature, icon, feels-like, wind, and cloud cover.
        // - Hours 1...6 get an exponentially decaying observation-to-model bias correction
        //   (ΔT(Δt) = ΔT_0 · exp(-Δt / τ_MOS), τ_MOS = 3.5h) so the hourly strip transitions
        //   smoothly from the live street-address observation into the NWP ensemble curve.
        // - Upcoming dry hours get calibrated visual cloud cover so high NWP cirrus doesn't show 100% Overcast.
        let modelNowTempC = baseCurrent?.tempC ?? .nan
        let tempInnovationC: Double = (liveTempC.isFinite && modelNowTempC.isFinite)
            ? max(-8.0, min(8.0, liveTempC - modelNowTempC))
            : 0.0
        let mosDecayTauS = 3.5 * 3600.0
        let hourByTS: [Int64: WxBlendHour] = forecast.map {
            Dictionary($0.hours.map { ($0.tS, $0) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]

        var updatedHours = page.hours
        for idx in updatedHours.indices {
            let hCard = updatedHours[idx]
            if idx == 0 && hCard.isNow {
                let tempNoUnit = liveTempC.isFinite
                    ? WxFormat.temp(liveTempC, units: units, withUnit: false)
                    : hCard.temp
                let tempWithUnit = liveTempC.isFinite
                    ? WxFormat.temp(liveTempC, units: units, withUnit: true)
                    : hCard.temp
                let feelsWithUnit = liveFeelsC.isFinite
                    ? WxFormat.temp(liveFeelsC, units: units, withUnit: true)
                    : tempWithUnit
                let cloudText = liveCloudPct.isFinite
                    ? "Cloud " + WxFormat.percent(liveCloudPct)
                    : hCard.cloud
                let tooltip = WxFormat.clock(nowS, zone: placeZone)
                    + "\nFeels like " + feelsWithUnit
                    + "\nWind " + WxFormat.wind(liveWindKmh, units: units)
                    + "\nRain " + WxFormat.precip(livePrecipMmH.isFinite ? livePrecipMmH : 0.0, units: units)
                updatedHours[0] = DetailViewModel.HourCard(
                    startS: hCard.startS,
                    isNow: true,
                    hour: hCard.hour,
                    symbolName: entry.symbolName,
                    gtkIconName: entry.gtkIconName,
                    temp: tempNoUnit,
                    rain: hCard.rain,
                    cloud: cloudText,
                    tooltip: tooltip,
                    conditionCode: resolvedCondition,
                    isDay: isDay
                )
            } else {
                let leadS = Double(max(0, hCard.startS - nowS))
                var newTempText = hCard.temp
                if abs(tempInnovationC) >= 0.25,
                   leadS > 0,
                   leadS <= 6.0 * 3600.0,
                   let rawHour = hourByTS[hCard.startS],
                   rawHour.tempC.isFinite
                {
                    let correctedTempC = rawHour.tempC + tempInnovationC * exp(-leadS / mosDecayTauS)
                    newTempText = WxFormat.temp(correctedTempC, units: units, withUnit: false)
                }

                if let calCloud = calibratedHourlyCloudPct[hCard.startS],
                   calCloud.isFinite,
                   WxConditionSymbol.precipitationRank(hCard.conditionCode) == 0,
                   hCard.conditionCode != .fog
                {
                    let newCond = WxConditionRules.cloudCondition(calCloud)
                    let newEntry = WxConditionSymbol.entry(newCond, isDay: hCard.isDay)
                    updatedHours[idx] = DetailViewModel.HourCard(
                        startS: hCard.startS,
                        isNow: hCard.isNow,
                        hour: hCard.hour,
                        symbolName: newEntry.symbolName,
                        gtkIconName: newEntry.gtkIconName,
                        temp: newTempText,
                        rain: hCard.rain,
                        cloud: "Cloud " + WxFormat.percent(calCloud),
                        tooltip: hCard.tooltip,
                        conditionCode: newCond,
                        isDay: hCard.isDay
                    )
                } else if newTempText != hCard.temp {
                    updatedHours[idx] = DetailViewModel.HourCard(
                        startS: hCard.startS,
                        isNow: hCard.isNow,
                        hour: hCard.hour,
                        symbolName: hCard.symbolName,
                        gtkIconName: hCard.gtkIconName,
                        temp: newTempText,
                        rain: hCard.rain,
                        cloud: hCard.cloud,
                        tooltip: hCard.tooltip,
                        conditionCode: hCard.conditionCode,
                        isDay: hCard.isDay
                    )
                }
            }
        }

        // Append discovered local station to footer when present.
        var updatedFooter = page.footer
        if let id = stationID {
            let distText = stationDistanceKm.map { Self.formatDistance(km: $0, units: units) }
            let stationBadge = distText.map { "\(id) (\($0))" } ?? id
            if !updatedFooter.contains(id) {
                updatedFooter += " \u{00B7} Station: \(stationBadge)"
            }
        }

        return DetailViewModel.ForecastPage(
            place: page.place,
            showsOfflineBadge: page.showsOfflineBadge,
            showsStaleBadge: page.showsStaleBadge,
            staleBadgeTooltip: page.staleBadgeTooltip,
            now: updatedNow,
            rain: updatedRain,
            clouds: updatedClouds,
            airQuality: airQuality ?? page.airQuality,
            hours: updatedHours,
            days: updatedDays,
            footer: updatedFooter,
            showsRefreshing: page.showsRefreshing,
            attribution: page.attribution,
            attributionMarkup: page.attributionMarkup,
            partial: page.partial
        )
    }

    /// Applies the live station observations to a sidebar `RowViewModel`.
    func apply(to row: RowViewModel, units: WxUnits, nowS: Int64) -> RowViewModel {
        guard let base = row.current ?? (tempC != nil ? WxBlendHour(tS: nowS) : nil) else {
            return row
        }
        let isDay = row.current?.isDay ?? WxGeo.sunIsUp(lat: row.place.lat, lon: row.place.lon, t: nowS)
        var live = base
        if let tempC, tempC.isFinite { live.tempC = tempC }
        if let feelsC, feelsC.isFinite { live.feelsC = feelsC }
        if let humidityPct, humidityPct.isFinite { live.humidityPct = humidityPct }
        if let windKmh, windKmh.isFinite { live.windKmh = windKmh }
        if let gustKmh, gustKmh.isFinite { live.gustKmh = gustKmh }
        if let cloudPct, cloudPct.isFinite { live.cloudPct = cloudPct }
        if let precipMmH, precipMmH.isFinite { live.precipMm = precipMmH }
        if let condition, condition != .unknown {
            let isDrySky: Bool = switch condition {
            case .clear, .mostlyClear, .partlyCloudy, .mostlyCloudy, .overcast: true
            default: false
            }
            live.condition = (isDrySky && live.cloudPct.isFinite)
                ? WxConditionRules.cloudCondition(live.cloudPct)
                : condition
        } else if live.cloudPct.isFinite {
            live.condition = WxConditionRules.cloudCondition(live.cloudPct)
        }
        live.isDay = isDay

        var liveHint: String? = nil
        if WxConditionSymbol.precipitationRank(live.condition) > 0,
           row.hint.hasPrefix("Dry")
        {
            liveHint = "\(WxConditionRules.label(live.condition)) now"
        }
        return row.withLiveCurrent(live, liveHint: liveHint, units: units)
    }

    // MARK: - Formatting & Meteorological Helpers

    static func formatDistance(km: Double, units: WxUnits) -> String {
        if units == .metric {
            return String(format: "%.1f km", km)
        }
        let miles = km * 0.621371192237334
        return String(format: "%.1f mi", miles)
    }

    static func stationShortTag(
        id: String?,
        name: String?,
        distanceKm: Double?,
        units: WxUnits
    ) -> String? {
        let label = name ?? id
        guard let label, !label.isEmpty else { return nil }
        if let distanceKm, distanceKm.isFinite {
            return "\(label), \(formatDistance(km: distanceKm, units: units))"
        }
        return label
    }

    /// Computes apparent ("feels like") temperature in °C from air temperature (°C),
    /// relative humidity (%), and wind speed (km/h) using NWS Heat Index, NWS Wind Chill,
    /// or NWS mild apparent temperature rules.
    static func computeFeelsLikeC(tempC: Double, humidityPct: Double, windKmh: Double) -> Double {
        let rh = max(0.0, min(100.0, humidityPct))
        let vKmh = max(0.0, windKmh)

        // Cold wind chill regime (T <= 10°C and wind > 4.8 km/h)
        if tempC <= 10.0 && vKmh > 4.8 {
            let vPow = pow(vKmh, 0.16)
            return 13.12 + 0.6215 * tempC - 11.37 * vPow + 0.3965 * tempC * vPow
        }

        // Warm humid Heat Index regime (T >= 26.7°C / 80°F and RH >= 40%)
        if tempC >= 26.7 && rh >= 40.0 {
            let tF = tempC * 9.0 / 5.0 + 32.0
            let hiF = -42.379
                + 2.04901523 * tF
                + 10.14333127 * rh
                - 0.22475541 * tF * rh
                - 0.00683783 * tF * tF
                - 0.05481717 * rh * rh
                + 0.00122874 * tF * tF * rh
                + 0.00085282 * tF * rh * rh
                - 0.00000199 * tF * tF * rh * rh
            return (hiF - 32.0) * 5.0 / 9.0
        }

        // Mild regime (10°C < T < 26.7°C)
        if tempC >= 23.0 && rh > 55.0 {
            return tempC + (rh - 55.0) * 0.035
        }
        if tempC < 18.0 && vKmh > 12.0 {
            return tempC - min(2.0, (vKmh - 12.0) * 0.06)
        }
        return tempC
    }

    /// Builds a cloud sentence starting from the live observed cloud cover band and scanning
    /// the calibrated upcoming hours for the next sky change within 24 hours.
    private static func cloudSentence(
        liveCloudPct: Double,
        calibratedHourlyCloudPct: [Int64: Double],
        forecast: WxForecast?,
        nowS: Int64,
        zone: WxFormat.Zone,
        fallback: String
    ) -> String {
        guard let curBand = cloudBand(liveCloudPct) else { return fallback }
        let bandNow = ["Clear", "Mostly clear", "Partly cloudy", "Mostly cloudy", "Overcast"]
        let bandSteady = ["Clear skies", "Mostly clear skies", "Partly cloudy", "Mostly cloudy", "Overcast"]
        let bandTarget = ["clearing", "mostly clear", "partly cloudy", "mostly cloudy", "clouding over"]

        guard let hours = forecast?.hours, !hours.isEmpty else {
            return "\(bandSteady[curBand]) for the next 24 hours"
        }

        let lookaheadEnd = nowS + 24 * 3600
        for h in hours where h.tS >= nowS + 3600 && h.tS < lookaheadEnd {
            let effectiveCloud = calibratedHourlyCloudPct[h.tS] ?? h.cloudPct
            if let band = cloudBand(effectiveCloud), band != curBand {
                let clock = WxFormat.hourLabel(h.tS, zone: zone)
                let day = WxFormat.weekday(h.tS, zone: zone, nowS: nowS)
                let when: String
                if day == "Today" {
                    when = "around \(clock)"
                } else if day == "Tomorrow" {
                    when = "tomorrow around \(clock)"
                } else {
                    when = "\(day) around \(clock)"
                }
                return "\(bandNow[curBand]) now, \(bandTarget[band]) \(when)"
            }
        }
        return "\(bandSteady[curBand]) for the next 24 hours"
    }

    private static func cloudBand(_ pct: Double) -> Int? {
        guard pct.isFinite, pct >= 0.0, pct <= 100.0 else { return nil }
        if pct < 12.5 { return 0 }
        if pct < 37.5 { return 1 }
        if pct < 62.5 { return 2 }
        if pct < 87.5 { return 3 }
        return 4
    }
}

// MARK: - Shared Store for Sidebar & Detail Pane

/// Caches live station snapshots per place key so both `ShellSidebar` and `DetailView` stay in sync.
@MainActor
@Observable
final class LiveStationStore {
    static let shared = LiveStationStore()

    private(set) var snapshots: [String: LiveStationSnapshot] = [:]
    @ObservationIgnored private var lastFetchedAt: [String: (fetchedS: Int64, units: WxUnits)] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    func snapshot(for place: AppModel.Place?) -> LiveStationSnapshot? {
        guard let place, !place.offline else { return nil }
        return snapshots[place.key]
    }

    func refreshIfNeeded(for place: AppModel.Place) async {
        guard !place.offline else { return }
        let key = place.key
        if let prev = lastFetchedAt[key],
           prev.fetchedS == place.fetchedS,
           prev.units == place.units,
           snapshots[key] != nil
        {
            return
        }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        if let fetched = await LiveStationFetcher.fetch(
            lat: place.place.lat,
            lon: place.place.lon,
            units: place.units
        ) {
            snapshots[key] = fetched
            lastFetchedAt[key] = (place.fetchedS, place.units)
        }
    }

    func refreshAll(places: [AppModel.Place]) async {
        await withTaskGroup(of: Void.self) { group in
            for place in places where !place.offline {
                group.addTask { [weak self] in
                    await self?.refreshIfNeeded(for: place)
                }
            }
        }
    }
}

// MARK: - Live Station Discovery & Fetching Engine

enum LiveStationFetcher {
    /// Dynamically discovers and fetches live weather and air-quality observations from the
    /// nearest physical stations and high-resolution surface models around `(lat, lon)`.
    static func fetch(
        lat: Double,
        lon: Double,
        units: WxUnits = .imperial
    ) async -> LiveStationSnapshot? {
        async let openMeteoTask = fetchOpenMeteoCurrent(lat: lat, lon: lon)
        async let nwsHourlyTask = fetchNWSHourlySky(lat: lat, lon: lon)
        async let aqiTask = fetchAirQuality(lat: lat, lon: lon, units: units)

        let omCurrent = await openMeteoTask
        async let metarTask = fetchNearbyMETAR(
            lat: lat,
            lon: lon,
            targetElevationM: omCurrent?.elevationM,
            upperCloudPct: omCurrent?.upperCloudPct
        )

        let (metar, nwsHourlySky, aqi) = await (metarTask, nwsHourlyTask, aqiTask)
        if metar == nil && omCurrent == nil && aqi == nil {
            return nil
        }

        var snapshot = LiveStationSnapshot()
        snapshot.airQuality = aqi

        if let metar {
            // Distance- and freshness-aware multi-service fusion between the elevation-adjusted
            // multi-station observation and Open-Meteo's 90m-DEM downscaled surface analysis:
            // - At d = 0 km, α_obs ≈ 0.94 (physical station dominates).
            // - At d = 25 km, α_obs ≈ 0.72.
            // - At d = 60 km, α_obs ≈ 0.42 (high-resolution DEM surface analysis prevents macro-scale smoothing).
            let distFactor = exp(-pow(metar.distanceKm / 38.0, 2.0))
            let ageFactor = exp(-Double(max(0, metar.ageSeconds)) / 3600.0)
            let obsAlpha = max(0.35, min(0.95, 0.35 + 0.60 * distFactor * ageFactor))

            if let omTemp = omCurrent?.tempC, omTemp.isFinite {
                snapshot.tempC = obsAlpha * metar.tempC + (1.0 - obsAlpha) * omTemp
            } else {
                snapshot.tempC = metar.tempC
            }

            if let mHum = metar.humidityPct, let omHum = omCurrent?.humidityPct, omHum.isFinite {
                snapshot.humidityPct = max(0.0, min(100.0, obsAlpha * mHum + (1.0 - obsAlpha) * omHum))
            } else {
                snapshot.humidityPct = metar.humidityPct ?? omCurrent?.humidityPct
            }

            if let mWind = metar.windKmh, let omWind = omCurrent?.windKmh, omWind.isFinite {
                snapshot.windKmh = obsAlpha * mWind + (1.0 - obsAlpha) * omWind
            } else {
                snapshot.windKmh = metar.windKmh ?? omCurrent?.windKmh
            }

            snapshot.gustKmh = metar.gustKmh ?? omCurrent?.gustKmh
            snapshot.cloudPct = metar.cloudPct ?? omCurrent?.cloudPct
            snapshot.precipMmH = metar.precipMmH ?? omCurrent?.precipMmH
            snapshot.condition = metar.condition ?? omCurrent?.condition
            snapshot.stationID = metar.stationID
            snapshot.stationName = metar.stationName
            snapshot.stationDistanceKm = metar.distanceKm
            if let t = snapshot.tempC {
                snapshot.feelsC = LiveStationSnapshot.computeFeelsLikeC(
                    tempC: t,
                    humidityPct: snapshot.humidityPct ?? 50.0,
                    windKmh: snapshot.windKmh ?? 0.0
                )
            } else if let feels = metar.feelsC {
                snapshot.feelsC = feels
            }
        } else if let omCurrent {
            snapshot.tempC = omCurrent.tempC
            snapshot.feelsC = omCurrent.feelsC
            snapshot.humidityPct = omCurrent.humidityPct
            snapshot.windKmh = omCurrent.windKmh
            snapshot.gustKmh = omCurrent.gustKmh
            snapshot.cloudPct = omCurrent.cloudPct
            snapshot.precipMmH = omCurrent.precipMmH
            snapshot.condition = omCurrent.condition
        }

        if let quarters = omCurrent?.radarQuarters {
            snapshot.radarQuarters = quarters
        }

        // Merge calibrated hourly sky cover: prefer NWS human-forecaster hourly sky cover in the US,
        // supplemented by Open-Meteo altitude-weighted low/mid/high cloud layers globally.
        var hourlyClouds = omCurrent?.calibratedHourlyCloudPct ?? [:]
        for (tS, pct) in nwsHourlySky {
            hourlyClouds[tS] = pct
        }
        snapshot.calibratedHourlyCloudPct = hourlyClouds

        return snapshot
    }

    // MARK: - 1. Multi-Station 3D Anisotropic / Shepard / Psychrometric METAR + NWS ASOS Fusion

    private struct METARObservation: Decodable {
        struct CloudLayer: Decodable {
            let cover: String?
            let base: Int?
        }
        let icaoId: String?
        let name: String?
        let lat: Double?
        let lon: Double?
        let elev: Double?
        let obsTime: Int64?
        let temp: Double?
        let dewp: Double?
        let wspd: Double?
        let wgst: Double?
        let cover: String?
        let clouds: [CloudLayer]?
        let wxString: String?
        let precip: Double?
    }

    private struct BlendedMETAR {
        var tempC: Double
        var feelsC: Double?
        var humidityPct: Double?
        var windKmh: Double?
        var gustKmh: Double?
        var cloudPct: Double?
        var precipMmH: Double?
        var condition: WxCondition?
        var stationID: String
        var stationName: String?
        var distanceKm: Double
        var ageSeconds: Int64
    }

    private struct CandidateStation {
        let obs: METARObservation
        let distKm: Double
        let bearingRad: Double
        let elevM: Double?
        let ageS: Int64
        let adjustedTempC: Double
        let adjustedDewpC: Double?
        let horizWeight: Double
        let vertWeight: Double
        var shepardFactor: Double = 1.0
        var qcPenalty: Double = 1.0
    }

    private static func fetchNearbyMETAR(
        lat: Double,
        lon: Double,
        targetElevationM: Double?,
        upperCloudPct: Double?
    ) async -> BlendedMETAR? {
        var stations = await queryMETARBox(lat: lat, lon: lon, delta: 0.45)
        if stations.isEmpty {
            stations = await queryMETARBox(lat: lat, lon: lon, delta: 0.88)
        }
        guard !stations.isEmpty else { return nil }

        let nowEpoch = Int64(Date().timeIntervalSince1970)
        let isDaytime = WxGeo.sunIsUp(lat: lat, lon: lon, t: nowEpoch)

        // Adaptive environmental lapse rate Γ_T (°C/m) and dewpoint lapse rate Γ_Td (°C/m):
        // - Daytime mixed boundary layer: -0.0068 °C/m
        // - Nighttime radiative stability: -0.0042 °C/m
        let gammaTempPerM = isDaytime ? -0.0068 : -0.0042
        let gammaDewpPerM = -0.0019

        let ranked: [CandidateStation] = stations.compactMap { obs in
            guard let sLat = obs.lat, let sLon = obs.lon,
                  let rawTemp = obs.temp, rawTemp.isFinite, rawTemp >= -90, rawTemp <= 65
            else {
                return nil
            }
            let ageS = obs.obsTime.map { max(0, nowEpoch - $0) } ?? 1200
            if ageS > 3 * 3600 {
                return nil
            }
            let d = WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: sLat, bLon: sLon)
            guard d.isFinite, d <= 95.0 else { return nil }

            // Compute elevation difference Δz = z_target - z_station (clamped to ±1800 m)
            let dz: Double = {
                guard let z0 = targetElevationM, let zStation = obs.elev, z0.isFinite, zStation.isFinite else {
                    return 0.0
                }
                return max(-1800.0, min(1800.0, z0 - zStation))
            }()

            let adjTemp = rawTemp + gammaTempPerM * dz
            let adjDewp: Double? = obs.dewp.flatMap { td in
                guard td.isFinite, td >= -95, td <= 50 else { return nil }
                return min(adjTemp, td + gammaDewpPerM * dz)
            }

            // 3D anisotropic horizontal + vertical kernel (L_h = 22 km, d_0 = 8 km, L_z = 350 m)
            let wHoriz = exp(-pow(d, 2.0) / (2.0 * 22.0 * 22.0)) / (1.0 + pow(d / 8.0, 2.0))
            let wVert = exp(-pow(dz, 2.0) / (2.0 * 350.0 * 350.0))
            let bearing = initialBearingRadians(fromLat: lat, fromLon: lon, toLat: sLat, toLon: sLon)

            return CandidateStation(
                obs: obs,
                distKm: d,
                bearingRad: bearing,
                elevM: obs.elev,
                ageS: ageS,
                adjustedTempC: adjTemp,
                adjustedDewpC: adjDewp,
                horizWeight: wHoriz,
                vertWeight: wVert
            )
        }
        .sorted { $0.distKm < $1.distKm }

        guard let nearest = ranked.first else { return nil }

        // Select up to 8 stations within 60 km (or fallback to nearest)
        let poolSlice = ranked.filter { $0.distKm <= 60.0 }.prefix(8)
        var pool = poolSlice.isEmpty ? [nearest] : Array(poolSlice)

        // Shepard directional isolation / angular de-clustering factor s_i:
        // Prevents a tight cluster of stations on one bearing from overpowering an isolated station
        // on the opposite side of the target street address.
        if pool.count >= 2 {
            for i in pool.indices {
                var angularShadow = 0.0
                for j in pool.indices where j != i {
                    let cosDiff = cos(pool[i].bearingRad - pool[j].bearingRad)
                    let dirOverlap = pow(max(0.0, (1.0 + cosDiff) * 0.5), 4.0)
                    let ratio = sqrt(max(1e-6, pool[j].horizWeight / max(pool[i].horizWeight, 1e-6)))
                    angularShadow += ratio * dirOverlap
                }
                pool[i].shepardFactor = 1.0 / (1.0 + angularShadow)
            }
        }

        // Spatial Buddy Quality Control using Median Absolute Deviation (MAD) when >= 3 stations exist
        if pool.count >= 3 {
            let sortedTemps = pool.map(\.adjustedTempC).sorted()
            let medianTemp = sortedTemps[sortedTemps.count / 2]
            let absDevs = sortedTemps.map { abs($0 - medianTemp) }.sorted()
            let mad = max(1.0, absDevs[absDevs.count / 2])
            let threshold = 3.2 * mad
            for i in pool.indices {
                let resid = abs(pool[i].adjustedTempC - medianTemp)
                if resid > threshold {
                    pool[i].qcPenalty = pow(threshold / resid, 2.0)
                }
            }
        }

        // Variable-specific temporal exponential decay constants:
        // τ_temp = 2700 s (45 min), τ_wind = 1200 s (20 min), τ_wx = 900 s (15 min)
        var tempSum = 0.0, tempW = 0.0
        var dewpSum = 0.0, dewpW = 0.0
        var windSum = 0.0, windW = 0.0
        var gustExcessSqSum = 0.0, gustW = 0.0
        var cloudSum = 0.0, cloudW = 0.0
        var precipSum = 0.0, precipW = 0.0

        for item in pool {
            let baseSpatialW = item.horizWeight * item.vertWeight * item.shepardFactor * item.qcPenalty
            let wTemp = baseSpatialW * exp(-Double(item.ageS) / 2700.0)
            let wWind = baseSpatialW * exp(-Double(item.ageS) / 1200.0)
            let wWx = baseSpatialW * exp(-Double(item.ageS) / 900.0)

            tempSum += item.adjustedTempC * wTemp
            tempW += wTemp

            if let td = item.adjustedDewpC {
                dewpSum += td * wTemp
                dewpW += wTemp
            }
            if let wspd = item.obs.wspd, wspd >= 0 {
                let kmh = wspd * 1.852
                windSum += kmh * wWind
                windW += wWind
                if let wgst = item.obs.wgst, wgst > wspd {
                    let excessKmh = max(0.0, (wgst - wspd) * 1.852)
                    gustExcessSqSum += (excessKmh * excessKmh) * wWind
                    gustW += wWind
                }
            }
            if let cPct = effectiveMETARCloudCover(obs: item.obs, upperCloudPct: upperCloudPct) {
                cloudSum += cPct * wWx
                cloudW += wWx
            }
            if let pIn = item.obs.precip, pIn >= 0 {
                precipSum += (pIn * 25.4) * wWx
                precipW += wWx
            }
        }

        guard tempW > 0 else { return nil }
        var blendedTemp = tempSum / tempW
        var blendedDewp = dewpW > 0 ? min(blendedTemp, dewpSum / dewpW) : nil
        var blendedFeels: Double? = nil
        var blendedHum = blendedDewp.map { relativeHumidity(tempC: blendedTemp, dewpC: $0) }
        var blendedWind = windW > 0 ? (windSum / windW) : nil
        var blendedGust: Double? = {
            guard let u = blendedWind, gustW > 0 else { return nil }
            let rmsExcess = sqrt(gustExcessSqSum / gustW)
            return rmsExcess >= 3.5 ? (u + rmsExcess) : nil
        }()
        var blendedCloud = cloudW > 0 ? (cloudSum / cloudW) : nil
        var blendedPrecip = precipW > 0 ? (precipSum / precipW) : nil
        var bestAgeS = nearest.ageS

        let stationID = nearest.obs.icaoId ?? "METAR"
        let stationName = cleanStationName(nearest.obs.name)

        // If the primary station is a US ICAO station (K..., P..., T...), also query NWS api.weather.gov
        // for 5-minute / 15-minute sub-hourly ASOS updates and official laser-ceilometer sky cover.
        // For German/Dutch/Central European stations (ED..., ET..., EH..., EB..., LO..., LS...), query
        // Bright Sky (DWD/KNMI 10-minute SYNOP observations).
        var subHourlyObs: NWSLatestObs? = await fetchNWSLatestObservation(stationID: stationID)
        if subHourlyObs == nil,
           WxGeo.inCentralEurope(lat: lat, lon: lon) || WxGeo.inBenelux(lat: lat, lon: lon)
               || stationID.hasPrefix("ED") || stationID.hasPrefix("ET") || stationID.hasPrefix("EH")
        {
            subHourlyObs = await fetchBrightSkyLatestObservation(lat: lat, lon: lon)
        }

        var nwsCondition: WxCondition? = nil
        if let nwsObs = subHourlyObs,
           nwsObs.timestampS >= (nearest.obs.obsTime ?? 0)
        {
            bestAgeS = max(0, nowEpoch - nwsObs.timestampS)
            let dz: Double = {
                guard let z0 = targetElevationM, let zStation = nwsObs.elevM ?? nearest.elevM else { return 0.0 }
                return max(-1800.0, min(1800.0, z0 - zStation))
            }()
            if let nwsTemp = nwsObs.tempC {
                let adjNwsTemp = nwsTemp + gammaTempPerM * dz
                blendedTemp = (adjNwsTemp * 0.65) + (blendedTemp * 0.35)
            }
            if let nwsDewp = nwsObs.dewpC {
                let adjNwsDewp = min(blendedTemp, nwsDewp + gammaDewpPerM * dz)
                blendedDewp = blendedDewp.map { (adjNwsDewp * 0.65) + ($0 * 0.35) } ?? adjNwsDewp
                blendedHum = relativeHumidity(tempC: blendedTemp, dewpC: blendedDewp!)
            } else if let nwsHum = nwsObs.humidityPct {
                blendedHum = nwsHum
            }
            if let nwsFeels = nwsObs.feelsC {
                blendedFeels = nwsFeels
            }
            if let nwsWind = nwsObs.windKmh {
                blendedWind = blendedWind.map { (nwsWind * 0.65) + ($0 * 0.35) } ?? nwsWind
            }
            if let nwsGust = nwsObs.gustKmh {
                blendedGust = max(blendedGust ?? 0.0, nwsGust)
            }
            if let nwsCloud = nwsObs.cloudPct {
                if let upper = upperCloudPct, nwsCloud < 25.0, upper > 30.0 {
                    // Combine ASOS <=12,000 ft ceilometer with NWP upper-tropospheric cloud transmittance
                    let lowT = 1.0 - (nwsCloud / 100.0)
                    let highT = 1.0 - (upper / 100.0)
                    blendedCloud = 100.0 * (1.0 - lowT * highT)
                } else {
                    blendedCloud = nwsCloud
                }
            }
            nwsCondition = nwsObs.condition
        }

        // Compute psychrometric Stull (2011) wet-bulb temperature T_w for hydrometeor phase discrimination
        let effectiveRH = blendedHum ?? 55.0
        let wetBulbC = computeWetBulbC(tempC: blendedTemp, humidityPct: effectiveRH)

        // Parse present weather string from the nearest station (if within 38 km)
        var wxCond: WxCondition? = nwsCondition
        if wxCond == nil, nearest.distKm <= 38.0, let wx = nearest.obs.wxString, !wx.isEmpty {
            wxCond = parseMETARWxString(
                wx,
                tempC: blendedTemp,
                wetBulbC: wetBulbC,
                cloudPct: blendedCloud ?? 50.0
            )
            if blendedPrecip == nil, let wxCond, WxConditionSymbol.precipitationRank(wxCond) > 0 {
                blendedPrecip = switch wxCond {
                case .heavyRain, .thunderstorm: 8.5
                case .rain, .snow, .sleet: 3.0
                case .lightRain, .showers: 1.0
                case .drizzle: 0.3
                default: 0.0
                }
            }
        }

        if wxCond == nil, let blendedCloud {
            wxCond = WxConditionRules.cloudCondition(blendedCloud)
        }

        return BlendedMETAR(
            tempC: blendedTemp,
            feelsC: blendedFeels,
            humidityPct: blendedHum,
            windKmh: blendedWind,
            gustKmh: blendedGust,
            cloudPct: blendedCloud,
            precipMmH: blendedPrecip,
            condition: wxCond,
            stationID: stationID,
            stationName: stationName,
            distanceKm: nearest.distKm,
            ageSeconds: bestAgeS
        )
    }

    private struct NWSLatestObs {
        var timestampS: Int64
        var elevM: Double?
        var tempC: Double?
        var dewpC: Double?
        var feelsC: Double?
        var humidityPct: Double?
        var windKmh: Double?
        var gustKmh: Double?
        var cloudPct: Double?
        var condition: WxCondition?
    }

    private struct NWSObservationResponse: Decodable {
        struct QuantitativeValue: Decodable {
            let value: Double?
            let unitCode: String?
        }
        struct CloudLayer: Decodable {
            let base: QuantitativeValue?
            let amount: String?
        }
        struct Properties: Decodable {
            let timestamp: String?
            let textDescription: String?
            let elevation: QuantitativeValue?
            let temperature: QuantitativeValue?
            let dewpoint: QuantitativeValue?
            let relativeHumidity: QuantitativeValue?
            let heatIndex: QuantitativeValue?
            let windChill: QuantitativeValue?
            let windSpeed: QuantitativeValue?
            let windGust: QuantitativeValue?
            let cloudLayers: [CloudLayer]?
        }
        let properties: Properties?
    }

    private static func fetchNWSLatestObservation(stationID: String) async -> NWSLatestObs? {
        guard stationID.count == 4,
              let first = stationID.first,
              first == "K" || first == "P" || first == "T"
        else {
            return nil
        }
        guard let url = URL(string: "https://api.weather.gov/stations/\(stationID)/observations/latest") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("WeatherApp/1.0 (macOS; local-station-observer)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 4.0
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(NWSObservationResponse.self, from: data)
            guard let props = decoded.properties else { return nil }

            let iso = ISO8601DateFormatter()
            let ts = props.timestamp.flatMap { iso.date(from: $0)?.timeIntervalSince1970 }.map(Int64.init) ?? 0
            let tempC = props.temperature?.value
            guard let tempC, tempC.isFinite else { return nil }

            let dewpC = props.dewpoint?.value.flatMap { $0.isFinite ? $0 : nil }
            let elevM = props.elevation?.value.flatMap { $0.isFinite ? $0 : nil }
            let feelsC = props.heatIndex?.value ?? props.windChill?.value
            let rh = props.relativeHumidity?.value

            let windKmh: Double? = {
                guard let v = props.windSpeed?.value, v.isFinite else { return nil }
                if let unit = props.windSpeed?.unitCode, unit.contains("m_s") {
                    return v * 3.6
                }
                return v
            }()
            let gustKmh: Double? = {
                guard let v = props.windGust?.value, v.isFinite else { return nil }
                if let unit = props.windGust?.unitCode, unit.contains("m_s") {
                    return v * 3.6
                }
                return v
            }()

            var cloudPct: Double? = nil
            if let layers = props.cloudLayers, !layers.isEmpty {
                var transmittance = 1.0
                for layer in layers {
                    guard let amount = layer.amount?.uppercased() else { continue }
                    let rawPct = oktasCoverPercent(amount)
                    let baseMeters = layer.base?.value ?? 1500.0
                    let weight: Double = baseMeters >= 5500.0 ? 0.30 : (baseMeters >= 3600.0 ? 0.72 : 1.0)
                    let layerOpacity = max(0.0, min(1.0, (rawPct * weight) / 100.0))
                    transmittance *= (1.0 - layerOpacity)
                }
                cloudPct = max(0.0, min(100.0, 100.0 * (1.0 - transmittance)))
            }

            let wetBulbC = computeWetBulbC(tempC: tempC, humidityPct: rh ?? 55.0)
            let cond = parseNWSTextDescription(
                props.textDescription,
                tempC: tempC,
                wetBulbC: wetBulbC,
                cloudPct: &cloudPct
            )
            return NWSLatestObs(
                timestampS: ts,
                elevM: elevM,
                tempC: tempC,
                dewpC: dewpC,
                feelsC: feelsC,
                humidityPct: rh,
                windKmh: windKmh,
                gustKmh: gustKmh,
                cloudPct: cloudPct,
                condition: cond
            )
        } catch {
            return nil
        }
    }

    private struct BrightSkyCurrentResponse: Decodable {
        struct Weather: Decodable {
            let timestamp: String?
            let temperature: Double?
            let dew_point: Double?
            let relative_humidity: Double?
            let wind_speed_10: Double?
            let wind_speed_30: Double?
            let wind_gust_speed_10: Double?
            let wind_gust_speed_30: Double?
            let cloud_cover: Double?
            let condition: String?
            let icon: String?
        }
        struct Source: Decodable {
            let height: Double?
        }
        let weather: Weather?
        let sources: [Source]?
    }

    /// Queries DWD / KNMI 10-minute SYNOP observations via Bright Sky (`api.brightsky.dev/current_weather`)
    /// for Germany, the Netherlands, Benelux, and Central Europe.
    private static func fetchBrightSkyLatestObservation(lat: Double, lon: Double) async -> NWSLatestObs? {
        let urlStr = String(
            format: "https://api.brightsky.dev/current_weather?lat=%.4f&lon=%.4f",
            lat, lon
        )
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("WeatherApp/1.0 (macOS; local-station-observer)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 4.0
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(BrightSkyCurrentResponse.self, from: data)
            guard let wx = decoded.weather,
                  let tempC = wx.temperature, tempC.isFinite
            else {
                return nil
            }
            let iso = ISO8601DateFormatter()
            let ts = wx.timestamp.flatMap { iso.date(from: $0)?.timeIntervalSince1970 }.map(Int64.init) ?? 0
            let dewpC = wx.dew_point.flatMap { $0.isFinite ? $0 : nil }
            let rh = wx.relative_humidity.flatMap { $0.isFinite ? $0 : nil }
            let windKmh = (wx.wind_speed_10 ?? wx.wind_speed_30).flatMap { $0.isFinite ? $0 : nil }
            let gustKmh = (wx.wind_gust_speed_10 ?? wx.wind_gust_speed_30).flatMap { $0.isFinite ? $0 : nil }
            var cloudPct = wx.cloud_cover.flatMap { $0.isFinite ? max(0.0, min(100.0, $0)) : nil }
            let elevM = decoded.sources?.first?.height.flatMap { $0.isFinite ? $0 : nil }

            let wetBulbC = computeWetBulbC(tempC: tempC, humidityPct: rh ?? 55.0)
            let cond = parseNWSTextDescription(
                wx.condition ?? wx.icon,
                tempC: tempC,
                wetBulbC: wetBulbC,
                cloudPct: &cloudPct
            )
            return NWSLatestObs(
                timestampS: ts,
                elevM: elevM,
                tempC: tempC,
                dewpC: dewpC,
                feelsC: nil,
                humidityPct: rh,
                windKmh: windKmh,
                gustKmh: gustKmh,
                cloudPct: cloudPct,
                condition: cond
            )
        } catch {
            return nil
        }
    }

    private static func parseNWSTextDescription(
        _ text: String?,
        tempC: Double,
        wetBulbC: Double,
        cloudPct: inout Double?
    ) -> WxCondition? {
        guard let text = text?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        if text.contains("thunder") || text.contains("t-storm") {
            return .thunderstorm
        }
        if text.contains("freezing") || text.contains("sleet") || text.contains("ice pellets") {
            return .sleet
        }
        if text.contains("snow") || text.contains("flurries") || text.contains("blizzard") {
            return wetBulbC <= 0.8 ? .snow : (wetBulbC <= 2.0 ? .sleet : .rain)
        }
        if text.contains("heavy rain") {
            return .heavyRain
        }
        if text.contains("shower") {
            return .showers
        }
        if text.contains("light rain") {
            return .lightRain
        }
        if text.contains("rain") {
            return tempC <= -0.5 ? .sleet : .rain
        }
        if text.contains("drizzle") {
            return .drizzle
        }
        if text.contains("fog") {
            return .fog
        }
        if text.contains("mostly clear") || text.contains("mostly sunny") || text.contains("few clouds") {
            if cloudPct == nil { cloudPct = 22.0 }
            return .mostlyClear
        }
        if text.contains("clear") || text.contains("sunny") || text.contains("fair") {
            if cloudPct == nil { cloudPct = 5.0 }
            return .clear
        }
        if text.contains("partly cloudy") || text.contains("partly sunny") {
            if cloudPct == nil { cloudPct = 48.0 }
            return .partlyCloudy
        }
        if text.contains("mostly cloudy") {
            if cloudPct == nil { cloudPct = 76.0 }
            return .mostlyCloudy
        }
        if text.contains("overcast") || text.contains("cloudy") {
            if cloudPct == nil { cloudPct = 95.0 }
            return .overcast
        }
        return nil
    }

    /// Queries NWS `api.weather.gov/points/{lat},{lon}` -> `forecastHourly` to obtain
    /// meteorologist-calibrated hourly sky cover for US locations.
    private struct NWSPointsResponse: Decodable {
        struct Properties: Decodable {
            let forecastHourly: String?
        }
        let properties: Properties?
    }

    private struct NWSHourlyForecastResponse: Decodable {
        struct Period: Decodable {
            let startTime: String?
            let shortForecast: String?
        }
        struct Properties: Decodable {
            let periods: [Period]?
        }
        let properties: Properties?
    }

    private static func fetchNWSHourlySky(lat: Double, lon: Double) async -> [Int64: Double] {
        guard WxGeo.inUSNWS(lat: lat, lon: lon) || WxGeo.inCONUS(lat: lat, lon: lon) else {
            return [:]
        }
        let pointsURLStr = String(format: "https://api.weather.gov/points/%.4f,%.4f", lat, lon)
        guard let pointsURL = URL(string: pointsURLStr) else { return [:] }
        var req = URLRequest(url: pointsURL)
        req.setValue("WeatherApp/1.0 (macOS; local-station-observer)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 4.0
        do {
            let (pData, pResp) = try await URLSession.shared.data(for: req)
            guard let pHttp = pResp as? HTTPURLResponse, pHttp.statusCode == 200 else { return [:] }
            let points = try JSONDecoder().decode(NWSPointsResponse.self, from: pData)
            guard let hourlyURLStr = points.properties?.forecastHourly,
                  let hourlyURL = URL(string: hourlyURLStr)
            else {
                return [:]
            }
            var hReq = URLRequest(url: hourlyURL)
            hReq.setValue("WeatherApp/1.0 (macOS; local-station-observer)", forHTTPHeaderField: "User-Agent")
            hReq.timeoutInterval = 4.5
            let (hData, hResp) = try await URLSession.shared.data(for: hReq)
            guard let hHttp = hResp as? HTTPURLResponse, hHttp.statusCode == 200 else { return [:] }
            let decoded = try JSONDecoder().decode(NWSHourlyForecastResponse.self, from: hData)
            let iso = ISO8601DateFormatter()
            var out: [Int64: Double] = [:]
            for period in (decoded.properties?.periods ?? []).prefix(48) {
                guard let st = period.startTime,
                      let date = iso.date(from: st)
                else {
                    continue
                }
                let tS = Int64(date.timeIntervalSince1970)
                var inferredCloud: Double? = nil
                _ = parseNWSTextDescription(
                    period.shortForecast,
                    tempC: 20.0,
                    wetBulbC: 15.0,
                    cloudPct: &inferredCloud
                )
                if let inferredCloud {
                    out[tS] = inferredCloud
                }
            }
            return out
        } catch {
            return [:]
        }
    }

    private static func queryMETARBox(lat: Double, lon: Double, delta: Double) async -> [METARObservation] {
        let minLat = max(-89.9, lat - delta)
        let maxLat = min(89.9, lat + delta)
        let minLon = max(-179.9, lon - delta)
        let maxLon = min(179.9, lon + delta)
        let urlStr = String(
            format: "https://aviationweather.gov/api/data/metar?bbox=%.4f,%.4f,%.4f,%.4f&format=json",
            minLat, minLon, maxLat, maxLon
        )
        guard let url = URL(string: urlStr) else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                return []
            }
            return (try? JSONDecoder().decode([METARObservation].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    /// Computes initial forward azimuth (bearing in radians) from `(fromLat, fromLon)` to `(toLat, toLon)`
    /// for Shepard directional isolation de-clustering.
    private static func initialBearingRadians(
        fromLat: Double,
        fromLon: Double,
        toLat: Double,
        toLon: Double
    ) -> Double {
        let phi1 = fromLat * .pi / 180.0
        let phi2 = toLat * .pi / 180.0
        let dLon = (toLon - fromLon) * .pi / 180.0
        let y = sin(dLon) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLon)
        return atan2(y, x)
    }

    /// Computes relative humidity (0...100%) from air temperature and dewpoint (°C)
    /// using the Alduchov & Eskridge (1996) / Magnus-Tetens saturation vapor pressure relationship.
    private static func relativeHumidity(tempC: Double, dewpC: Double) -> Double {
        let a = 17.625
        let b = 243.04
        let gammaTd = (a * dewpC) / (b + dewpC)
        let gammaT = (a * tempC) / (b + tempC)
        let rh = 100.0 * exp(gammaTd - gammaT)
        return max(0.0, min(100.0, rh))
    }

    /// Computes psychrometric wet-bulb temperature T_w (°C) using Stull's (2011) empirical
    /// formula (Journal of Applied Meteorology and Climatology, 50, 2267-2269) for accurate
    /// rain / sleet / snow hydrometeor phase discrimination.
    static func computeWetBulbC(tempC: Double, humidityPct: Double) -> Double {
        let rh = max(5.0, min(100.0, humidityPct))
        let t = tempC
        let term1 = t * atan(0.151977 * sqrt(rh + 8.313659))
        let term2 = atan(t + rh)
        let term3 = -atan(rh - 1.676331)
        let term4 = 0.00391838 * pow(rh, 1.5) * atan(0.023101 * rh)
        return term1 + term2 + term3 + term4 - 4.686035
    }

    /// Computes effective visual sky cover (0...100%) from METAR cloud layers using radiative
    /// random-overlap transmittance (`1 - ∏ (1 - α_k C_k)`), and fuses with NWP mid/high
    /// cloud opacity when the ASOS laser ceilometer (12,000-ft ceiling) reports clear below 12,000 ft.
    private static func effectiveMETARCloudCover(
        obs: METARObservation,
        upperCloudPct: Double? = nil
    ) -> Double? {
        var stationCover: Double? = nil
        if let layers = obs.clouds, !layers.isEmpty {
            var transmittance = 1.0
            for layer in layers {
                guard let code = layer.cover?.uppercased() else { continue }
                let rawPct = oktasCoverPercent(code)
                let baseFt = layer.base ?? 5000
                let altitudeWeight: Double = if baseFt >= 18_000 {
                    0.30
                } else if baseFt >= 12_000 {
                    0.72
                } else {
                    1.0
                }
                let layerOpacity = max(0.0, min(1.0, (rawPct * altitudeWeight) / 100.0))
                transmittance *= (1.0 - layerOpacity)
            }
            stationCover = max(0.0, min(100.0, 100.0 * (1.0 - transmittance)))
        } else if let topCover = obs.cover?.uppercased() {
            stationCover = oktasCoverPercent(topCover)
        }

        // ASOS laser ceilometers top out at 12,000 ft (3,650 m): if the station reports mostly clear
        // below 12,000 ft while NWP reports significant altostratus/cirrostratus aloft, combine via
        // random overlap.
        if let sc = stationCover {
            if let upper = upperCloudPct, sc < 25.0, upper > 30.0 {
                let lowT = 1.0 - (sc / 100.0)
                let highT = 1.0 - (upper / 100.0)
                return max(0.0, min(100.0, 100.0 * (1.0 - lowT * highT)))
            }
            return sc
        }
        return nil
    }

    private static func oktasCoverPercent(_ code: String) -> Double {
        switch code {
        case "CLR", "SKC", "CAVOK", "NCD", "NSC": return 0.0
        case "FEW": return 18.0
        case "SCT": return 44.0
        case "BKN": return 75.0
        case "OVC", "OVX": return 100.0
        default: return 0.0
        }
    }

    private static func parseMETARWxString(
        _ wx: String,
        tempC: Double,
        wetBulbC: Double,
        cloudPct: Double
    ) -> WxCondition? {
        let u = wx.uppercased()
        if u.contains("TS") {
            return .thunderstorm
        }
        if u.contains("FZRA") || u.contains("FZDZ") || u.contains("PL") || u.contains("IC") {
            return .sleet
        }
        if u.contains("SN") || u.contains("SG") || u.contains("GS") || u.contains("GR") {
            return wetBulbC <= 0.8 ? .snow : (wetBulbC <= 2.0 ? .sleet : .rain)
        }
        if u.contains("SHRA") || u.contains("SH") {
            return .showers
        }
        if u.contains("+RA") {
            return .heavyRain
        }
        if u.contains("-RA") {
            return cloudPct < 85.0 ? .showers : .lightRain
        }
        if u.contains("RA") {
            return tempC <= -0.5 ? .sleet : .rain
        }
        if u.contains("DZ") {
            return .drizzle
        }
        if u.contains("FG") {
            return .fog
        }
        return nil
    }

    /// Cleans ICAO station names like "MIAMI INTL, FL, US" -> "Miami Intl".
    private static func cleanStationName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let firstPart = raw.split(separator: ",").first.map(String.init) ?? raw
        let trimmed = firstPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(separator: " ")
            .map { word -> String in
                let upper = word.uppercased()
                if upper == "AP" || upper == "ARPT" { return "Airport" }
                if upper == "INTL" { return "Intl" }
                if upper == "EXEC" { return "Executive" }
                if upper == "MUNI" { return "Municipal" }
                if upper == "RGNL" { return "Regional" }
                return upper.prefix(1) + upper.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    // MARK: - 2. Open-Meteo High-Resolution Current, 90m DEM Elevation, Multi-Altitude Cloud Layers & 15-Min Radar

    private struct OpenMeteoCurrentSnapshot {
        var elevationM: Double?
        var tempC: Double?
        var feelsC: Double?
        var humidityPct: Double?
        var windKmh: Double?
        var gustKmh: Double?
        var cloudPct: Double?
        var upperCloudPct: Double?
        var precipMmH: Double?
        var condition: WxCondition?
        var radarQuarters: [WxQuarter]
        var calibratedHourlyCloudPct: [Int64: Double]
    }

    private struct OpenMeteoForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double?
            let relative_humidity_2m: Double?
            let apparent_temperature: Double?
            let precipitation: Double?
            let rain: Double?
            let showers: Double?
            let snowfall: Double?
            let weather_code: Int?
            let cloud_cover: Double?
            let cloud_cover_low: Double?
            let cloud_cover_mid: Double?
            let cloud_cover_high: Double?
            let wind_speed_10m: Double?
            let wind_gusts_10m: Double?
        }
        struct Hourly: Decodable {
            let time: [Int64]?
            let cloud_cover_low: [Double?]?
            let cloud_cover_mid: [Double?]?
            let cloud_cover_high: [Double?]?
            let precipitation: [Double?]?
        }
        struct Minutely15: Decodable {
            let time: [Int64]?
            let precipitation: [Double?]?
        }
        let elevation: Double?
        let current: Current?
        let hourly: Hourly?
        let minutely_15: Minutely15?
    }

    private static func fetchOpenMeteoCurrent(lat: Double, lon: Double) async -> OpenMeteoCurrentSnapshot? {
        let urlStr = String(
            format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,rain,showers,snowfall,weather_code,cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,wind_speed_10m,wind_gusts_10m&hourly=cloud_cover_low,cloud_cover_mid,cloud_cover_high,precipitation&minutely_15=precipitation&forecast_days=2&forecast_minutely_15=8&timeformat=unixtime",
            lat, lon
        )
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
            guard let cur = decoded.current else { return nil }

            let effectiveCloud: Double? = {
                if let low = cur.cloud_cover_low, let mid = cur.cloud_cover_mid, let high = cur.cloud_cover_high {
                    return altitudeWeightedCloud(
                        low: low,
                        mid: mid,
                        high: high,
                        precipMm: cur.precipitation ?? 0.0
                    )
                }
                return cur.cloud_cover
            }()

            let upperCloud: Double? = {
                if let mid = cur.cloud_cover_mid, let high = cur.cloud_cover_high {
                    return altitudeWeightedCloud(
                        low: 0.0,
                        mid: mid,
                        high: high,
                        precipMm: cur.precipitation ?? 0.0
                    )
                }
                return nil
            }()

            let precipRate = cur.precipitation ?? 0.0
            let wmoVotes = cur.weather_code.map { [$0] } ?? []
            let derivedCond = WxConditionRules.derive(
                WxConditionInput(
                    cloudPct: effectiveCloud ?? .nan,
                    precipProb: precipRate >= 0.1 ? 80.0 : 0.0,
                    precipMmH: precipRate,
                    tempC: cur.temperature_2m ?? .nan,
                    wmoVotes: wmoVotes
                )
            )

            var quarters: [WxQuarter] = []
            if let times = decoded.minutely_15?.time,
               let precips = decoded.minutely_15?.precipitation
            {
                let count = min(times.count, precips.count)
                for i in 0..<count {
                    let tS = times[i]
                    guard tS >= WxLimits.timeMinS, tS < WxLimits.timeMaxS, tS % 900 == 0 else {
                        continue
                    }
                    let mm15 = precips[i] ?? 0.0
                    quarters.append(WxQuarter(tS: tS, precipMm: max(0.0, mm15 * 4.0)))
                }
            }

            var hourlyClouds: [Int64: Double] = [:]
            if let hTimes = decoded.hourly?.time,
               let hLow = decoded.hourly?.cloud_cover_low,
               let hMid = decoded.hourly?.cloud_cover_mid,
               let hHigh = decoded.hourly?.cloud_cover_high
            {
                let hPrecip = decoded.hourly?.precipitation
                let n = min(hTimes.count, hLow.count, hMid.count, hHigh.count)
                for i in 0..<n {
                    if let l = hLow[i], let m = hMid[i], let h = hHigh[i] {
                        let p = (hPrecip != nil && i < hPrecip!.count) ? (hPrecip![i] ?? 0.0) : 0.0
                        hourlyClouds[hTimes[i]] = altitudeWeightedCloud(low: l, mid: m, high: h, precipMm: p)
                    }
                }
            }

            return OpenMeteoCurrentSnapshot(
                elevationM: decoded.elevation,
                tempC: cur.temperature_2m,
                feelsC: cur.apparent_temperature,
                humidityPct: cur.relative_humidity_2m,
                windKmh: cur.wind_speed_10m,
                gustKmh: cur.wind_gusts_10m,
                cloudPct: effectiveCloud,
                upperCloudPct: upperCloud,
                precipMmH: cur.precipitation,
                condition: derivedCond,
                radarQuarters: quarters,
                calibratedHourlyCloudPct: hourlyClouds
            )
        } catch {
            return nil
        }
    }

    /// Computes effective visual cloud cover from NWP low/mid/high cloud layers using radiative
    /// random-overlap transmittance (`1 - (1 - α_low C_low)(1 - α_mid C_mid)(1 - α_high C_high)`),
    /// ensuring dry upper-tropospheric cirrus/altostratus (`low < 25%`, `precip == 0`) does not
    /// falsely report 100% Overcast.
    private static func altitudeWeightedCloud(
        low: Double,
        mid: Double,
        high: Double,
        precipMm: Double
    ) -> Double {
        let lowOpacity = max(0.0, min(1.0, low / 100.0))
        let midWeight: Double = (low < 25.0 && high >= 75.0 && precipMm < 0.1) ? 0.34 : 0.76
        let midOpacity = max(0.0, min(1.0, (mid * midWeight) / 100.0))
        let highOpacity = max(0.0, min(1.0, (high * 0.24) / 100.0))
        let transmittance = (1.0 - lowOpacity) * (1.0 - midOpacity) * (1.0 - highOpacity)
        return max(0.0, min(100.0, 100.0 * (1.0 - transmittance)))
    }

    // MARK: - 3. Local Air Quality Monitor Discovery (EPA AirNow + Open-Meteo Fallback)

    private struct ArcGISFeatureResponse<Attributes: Decodable>: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable {
                let x: Double?
                let y: Double?
            }
            let attributes: Attributes
            let geometry: Geometry?
        }
        let features: [Feature]?
    }

    private struct CurrentMonitorAttributes: Decodable {
        let SiteName: String?
        let OZONEPM_AQI: Double?
    }

    private struct HourlyMonitorAttributes: Decodable {
        let SiteName: String?
        let OZONEPM_AQI: Double?
        let Latitude: Double?
        let Longitude: Double?
    }

    private struct OpenMeteoAQIResponse: Decodable {
        struct Current: Decodable {
            let us_aqi: Int?
            let european_aqi: Int?
            let pm2_5: Double?
            let nitrogen_dioxide: Double?
            let ozone: Double?
        }
        struct Hourly: Decodable {
            let us_aqi: [Int?]?
        }
        let current: Current?
        let hourly: Hourly?
    }

    private struct OpenMeteoAQISnapshot {
        let currentAQI: Int
        let yesterdayAQI: Int?
        let europeanAQI: Int?
        let pm25: Double?
        let no2: Double?
        let ozone: Double?
    }

    private static func fetchAirQuality(
        lat: Double,
        lon: Double,
        units: WxUnits
    ) async -> DetailViewModel.AirQualityCard? {
        async let epaCurrentTask = fetchEPACurrentMonitors(lat: lat, lon: lon)
        async let epaHourlyTask = fetchEPAHourlyMonitors(lat: lat, lon: lon)
        async let openMeteoAQITask = fetchOpenMeteoAQI(lat: lat, lon: lon)

        let (epaCurrent, epaHourly, omAQI) = await (epaCurrentTask, epaHourlyTask, openMeteoAQITask)

        struct StationReading {
            let name: String
            let aqi: Int
            let distKm: Double
        }

        let sourceReadings = !epaCurrent.isEmpty ? epaCurrent : epaHourly.recent
        var byName: [String: StationReading] = [:]
        for item in sourceReadings {
            if let existing = byName[item.name] {
                if item.distKm < existing.distKm {
                    byName[item.name] = StationReading(name: item.name, aqi: item.aqi, distKm: item.distKm)
                }
            } else {
                byName[item.name] = StationReading(name: item.name, aqi: item.aqi, distKm: item.distKm)
            }
        }

        let stations = byName.values.sorted { $0.distKm < $1.distKm }
        if let nearest = stations.first {
            let pool = stations.filter { $0.distKm <= 35.0 }.prefix(3)
            let activePool = pool.isEmpty ? [nearest] : Array(pool)

            var weightedSum = 0.0
            var weightTotal = 0.0
            for s in activePool {
                let w = 1.0 / pow(max(s.distKm, 2.0), 2.0)
                weightedSum += Double(s.aqi) * w
                weightTotal += w
            }
            let blendedAQI = max(0, min(500, Int((weightedSum / max(weightTotal, 1e-9)).rounded())))
            let refAQI = epaHourly.referenceAQI ?? omAQI?.yesterdayAQI
            let baseSummary = DetailViewModel.AirQualityCard.summarySentence(
                aqi: blendedAQI,
                referenceAQI: refAQI
            )
            let distStr = LiveStationSnapshot.formatDistance(km: nearest.distKm, units: units)
            let summary = "\(baseSummary) \u{00B7} Local monitor: \(nearest.name) (\(distStr))"

            return DetailViewModel.AirQualityCard(
                index: blendedAQI,
                valueText: "\(blendedAQI)",
                category: DetailViewModel.AirQualityCard.categoryLabel(for: blendedAQI),
                summary: summary
            )
        }

        if let omAQI {
            let clamped = max(0, min(500, omAQI.currentAQI))
            let baseSummary = DetailViewModel.AirQualityCard.summarySentence(
                aqi: clamped,
                referenceAQI: omAQI.yesterdayAQI
            )
            var details: [String] = []
            if WxGeo.inEurope(lat: lat, lon: lon), let eu = omAQI.europeanAQI {
                details.append("EAQI \(eu)")
            }
            if let pm25 = omAQI.pm25, pm25.isFinite {
                details.append(String(format: "PM2.5 %.0f \u{00B5}g/m\u{00B3}", pm25))
            }
            if let no2 = omAQI.no2, no2.isFinite {
                details.append(String(format: "NO\u{2082} %.0f \u{00B5}g/m\u{00B3}", no2))
            }
            let summary = details.isEmpty
                ? baseSummary
                : "\(baseSummary) \u{00B7} \(details.joined(separator: ", "))"
            return DetailViewModel.AirQualityCard(
                index: clamped,
                valueText: "\(clamped)",
                category: DetailViewModel.AirQualityCard.categoryLabel(for: clamped),
                summary: summary
            )
        }

        return nil
    }

    private static func fetchEPACurrentMonitors(
        lat: Double,
        lon: Double
    ) async -> [(name: String, aqi: Int, distKm: Double)] {
        guard !WxGeo.inEurope(lat: lat, lon: lon) else { return [] }
        let urlStr = String(
            format: "https://services.arcgis.com/cJ9YHowT8TU7DUyn/arcgis/rest/services/Air_Now_Current_Monitors_Ozone_and_PM/FeatureServer/0/query?where=OZONEPM_AQI%%20IS%%20NOT%%20NULL&geometry=%.4f,%.4f&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&distance=45000&units=esriSRUnit_Meter&outFields=SiteName,OZONEPM_AQI&outSR=4326&f=json",
            lon, lat
        )
        guard let url = URL(string: urlStr) else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(ArcGISFeatureResponse<CurrentMonitorAttributes>.self, from: data)
            return (decoded.features ?? []).compactMap { f in
                guard let rawAQI = f.attributes.OZONEPM_AQI, rawAQI.isFinite else { return nil }
                let aqi = Int(rawAQI.rounded())
                guard aqi >= 0, aqi <= 500,
                      let sLon = f.geometry?.x, let sLat = f.geometry?.y
                else {
                    return nil
                }
                let name = (f.attributes.SiteName ?? "AirNow").trimmingCharacters(in: .whitespacesAndNewlines)
                let dist = WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: sLat, bLon: sLon)
                guard dist.isFinite else { return nil }
                return (name: name, aqi: aqi, distKm: dist)
            }
        } catch {
            return []
        }
    }

    private static func fetchEPAHourlyMonitors(
        lat: Double,
        lon: Double
    ) async -> (recent: [(name: String, aqi: Int, distKm: Double)], referenceAQI: Int?) {
        guard !WxGeo.inEurope(lat: lat, lon: lon) else { return ([], nil) }
        let urlStr = String(
            format: "https://services.arcgis.com/cJ9YHowT8TU7DUyn/arcgis/rest/services/Air_Now_Monitor_Data_Public/FeatureServer/0/query?where=OZONEPM_AQI%%20IS%%20NOT%%20NULL&geometry=%.4f,%.4f&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&distance=35000&units=esriSRUnit_Meter&outFields=SiteName,OZONEPM_AQI,Latitude,Longitude,ValidTime&orderByFields=ValidTime%%20DESC&resultRecordCount=30&outSR=4326&f=json",
            lon, lat
        )
        guard let url = URL(string: urlStr) else { return ([], nil) }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return ([], nil) }
            let decoded = try JSONDecoder().decode(ArcGISFeatureResponse<HourlyMonitorAttributes>.self, from: data)
            var seen: Set<String> = []
            var recent: [(name: String, aqi: Int, distKm: Double)] = []
            var allAQIs: [Int] = []

            for f in decoded.features ?? [] {
                guard let rawAQI = f.attributes.OZONEPM_AQI, rawAQI.isFinite else { continue }
                let aqi = Int(rawAQI.rounded())
                guard aqi >= 0, aqi <= 500 else { continue }
                allAQIs.append(aqi)
                let sLat = f.attributes.Latitude ?? f.geometry?.y
                let sLon = f.attributes.Longitude ?? f.geometry?.x
                guard let sLat, let sLon else { continue }
                let name = (f.attributes.SiteName ?? "AirNow").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                let dist = WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: sLat, bLon: sLon)
                if dist.isFinite {
                    recent.append((name: name, aqi: aqi, distKm: dist))
                }
            }
            let referenceAQI = allAQIs.count >= 6 ? allAQIs.last : nil
            return (recent, referenceAQI)
        } catch {
            return ([], nil)
        }
    }

    private static func fetchOpenMeteoAQI(
        lat: Double,
        lon: Double
    ) async -> OpenMeteoAQISnapshot? {
        let urlStr = String(
            format: "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.4f&longitude=%.4f&current=us_aqi,european_aqi,pm2_5,nitrogen_dioxide,ozone&hourly=us_aqi&past_days=1&forecast_days=1",
            lat, lon
        )
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(OpenMeteoAQIResponse.self, from: data)
            guard let aqi = decoded.current?.us_aqi else { return nil }
            let pastValues = decoded.hourly?.us_aqi?.compactMap { $0 } ?? []
            let yesterdayAQI = pastValues.count >= 24 ? pastValues[pastValues.count - 24] : nil
            return OpenMeteoAQISnapshot(
                currentAQI: aqi,
                yesterdayAQI: yesterdayAQI,
                europeanAQI: decoded.current?.european_aqi,
                pm25: decoded.current?.pm2_5,
                no2: decoded.current?.nitrogen_dioxide,
                ozone: decoded.current?.ozone
            )
        } catch {
            return nil
        }
    }
}
