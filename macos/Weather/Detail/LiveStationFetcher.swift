// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// LiveStationFetcher.swift - dynamic discovery and real-time observation fetching
// from physical local weather & air-quality stations for any (lat, lon) coordinate:
//
// 1. Multi-network surface stations (StationNetworkFetcher gathers them: METAR worldwide; NWS
//    ASOS and Iowa Environmental Mesonet in the US; ECCC SWOB in Canada; DWD, DMI, FMI, SMHI,
//    GeoSphere Austria and MeteoSwiss in Europe), tested against each other (leave-one-out
//    cross-validation into the persistent station catalog's health) and blended by
//    WxStationFusion (WeatherCore) with the same 3D anisotropic kernel, Shepard de-clustering
//    and MAD buddy check in every country. Fuses temperature, dewpoint/humidity, wind speed &
//    gusts, altitude-weighted cloud cover, present weather (rain, thunderstorm, snow, fog,
//    drizzle) and precipitation rate. A close, fresh blend also teaches the place's local
//    forecast bias (WxLocalBias, through AppModel).
// 2. US EPA AirNow / State DEP ArcGIS FeatureServer (services.arcgis.com/cJ9YHowT8TU7DUyn):
//    the nearest physical ground air-quality monitor within 45 km and its reported US AQI
//    (ozone/PM, never interpolated between monitors) with its 24h comparison, falling back
//    to the CAMS forecast of Open-Meteo's Air Quality API when outside station coverage.
// 3. Calibrated Hourly Sky Cover & 15-Minute Radar Nowcast:
//    fetches NWS meteorologist-calibrated hourly sky forecasts (US) and Open-Meteo
//    multi-altitude cloud layers (cloud_cover_low / mid / high) + 15-minute radar
//    precipitation so upper-tropospheric cirrus never falsely shows 100% Overcast
//    in the 48-hour strip or Clouds card.

import AppKit
import Foundation
import Observation
import WeatherCore

/// Real-time local station observations, calibrated hourly cloud cover, and air quality for a place.
nonisolated struct LiveStationSnapshot: Sendable, Equatable {
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
    /// 15-minute radar precipitation for the next 2 hours: the amount over [tS, tS + 900), mm
    /// (WxQuarter).
    var radarQuarters: [WxQuarter] = []
    /// Calibrated effective visual cloud cover (%) by hour timestamp (UTC unix seconds).
    var calibratedHourlyCloudPct: [Int64: Double] = [:]
    /// Primary weather station ICAO/WMO identifier (e.g. "KMIA").
    var stationID: String?
    /// Human-readable primary weather station name (e.g. "Miami Intl").
    var stationName: String?
    /// Distance in km from the place to the primary weather station.
    var stationDistanceKm: Double?
    /// Number of distinct station sites blended into the observation (1 when only the primary).
    var stationCount: Int = 0
    /// The networks whose reports the blend could use (credited on the attribution line), with the
    /// time of each one's newest report.
    var networks: [WxStationNetwork: Int64] = [:]
    /// The Air Quality card: the nearest AirNow monitor as reported, else the CAMS forecast.
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
            // Quarters are labelled by their start: the one in progress (tS <= now < tS + 900) counts,
            // and rain in it starts now (1 minute).
            if page.rain.headline.hasPrefix("No rain"),
               let firstWet = radarQuarters.first(where: { $0.tS + 900 > nowS && $0.precipMm * 4.0 >= 0.1 })
            {
                let minutes = max(1, (max(firstWet.tS, nowS) - nowS + 59) / 60)
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
            let others = stationCount > 1 ? " +\(stationCount - 1) nearby" : ""
            if !updatedFooter.contains(id) {
                updatedFooter += " \u{00B7} Station: \(stationBadge)\(others)"
            }
        }

        let result = DetailViewModel.ForecastPage(
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
        let credits = WxStationNetworks.credits(for: Set(networks.keys), newestReportS: networks)
        return result.addingAttribution(credits + [airQuality?.credit].compactMap { $0 })
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

/// Caches live station snapshots per place key so both `ShellSidebar` and `DetailView` stay in
/// sync, and owns the persistent station catalog (`WxStationCatalog`: every station received,
/// its reachability and its tested track record).
@MainActor
@Observable
final class LiveStationStore {
    static let shared = LiveStationStore()

    private(set) var snapshots: [String: LiveStationSnapshot] = [:]
    /// The outcome of each network's latest fetch (Settings > Stations).
    private(set) var networkStatus: [WxStationNetwork: StationNetworkStatus] = [:]
    /// The networks with a saved key (the keys themselves stay in `keys`, not observed).
    private(set) var networksWithKeys: Set<WxStationNetwork> = []
    /// The expiry written in a saved key (AEMET and Météo-France keys carry one), UTC unix seconds.
    private(set) var keyExpiries: [WxStationNetwork: Int64] = [:]
    /// Bumped when the catalog changes, so Settings re-reads it.
    private(set) var catalogRevision: UInt64 = 0
    @ObservationIgnored private var keys: [WxStationNetwork: String] = [:]
    @ObservationIgnored private var keysLoaded = false
    /// Bumped by every change of the station configuration (a key, a network on or off):
    /// every place's snapshot is fetched again.
    @ObservationIgnored private var configRevision: UInt64 = 0
    @ObservationIgnored private var lastFetchedAt: [String: (fetchedS: Int64, units: WxUnits, config: UInt64)] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// The place of a refresh asked for while its key was in flight (fetched again after it).
    @ObservationIgnored private var pendingRefresh: [String: AppModel.Place] = [:]
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private(set) var catalog = WxStationCatalog()
    @ObservationIgnored private var catalogLoaded = false
    @ObservationIgnored private var catalogPath = ""
    @ObservationIgnored private var catalogSaveTask: Task<Void, Never>?
    /// The catalog is written at most this often, s.
    private static let catalogSaveDelayS = 60

    init() {
        // Every quit path replies to applicationShouldTerminate, then AppKit posts willTerminate
        // on the main thread before the process exits: the debounced catalog save is written then.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushCatalog() }
        }
    }

    /// Connects the store to the app model: the catalog file lives next to its settings, and the
    /// fused observations teach it the places' local forecast bias.
    func attach(_ model: AppModel) async {
        self.model = model
        loadKeysIfNeeded()
        let path = WxStationCatalog.defaultPath(configDirectory: model.storage.configDirectory)
        guard path != catalogPath else { return }
        catalogPath = path
        catalog = await Task.detached(priority: .utility) { WxStationCatalog.load(path: path) }.value
        catalogLoaded = true
    }

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
           prev.config == configRevision,
           snapshots[key] != nil
        {
            return
        }
        guard !inFlight.contains(key) else {
            // The units or the configuration may have changed since the flight started: fetch
            // again when it ends.
            pendingRefresh[key] = place
            return
        }
        inFlight.insert(key)

        let config = configRevision
        if var fetched = await LiveStationFetcher.fetch(place: place, store: self) {
            // An air-quality source that did not answer this time: the last reading while it is
            // recent (the card says when it was measured) and in the same units (its text has them).
            if fetched.airQuality == nil, lastFetchedAt[key]?.units == place.units,
               let last = snapshots[key]?.airQuality, let validS = last.validS,
               Int64(Date().timeIntervalSince1970) - validS <= WxAirQuality.maxAgeS
            {
                fetched.airQuality = last
            }
            snapshots[key] = fetched
            lastFetchedAt[key] = (place.fetchedS, place.units, config)
        } else {
            // No live source answered: the previous snapshot is no longer shown as current.
            snapshots[key] = nil
        }
        inFlight.remove(key)
        if let asked = pendingRefresh.removeValue(forKey: key) {
            // With the place as it is now (the model's, once attached), in a new task: the caller
            // of this flight may be a cancelled .task(id:). A no-op when nothing changed.
            let current = model.map { m in m.places.first { $0.key == key } } ?? asked
            if let current {
                Task { await refreshIfNeeded(for: current) }
            }
        }
    }

    func refreshAll(model: AppModel) async {
        await attach(model)
        await withTaskGroup(of: Void.self) { group in
            for place in model.places where !place.offline {
                group.addTask { [weak self] in
                    await self?.refreshIfNeeded(for: place)
                }
            }
        }
    }

    // MARK: Catalog (main actor; the fetcher hops here to record what it learned)

    func recordFetch(_ observations: [WxStationObservation], coverage: WxStationCoverage, nowS: Int64) {
        guard catalogLoaded else { return }
        catalog.recordFetch(observations, coverage: coverage, nowS: nowS)
        catalogRevision &+= 1
        scheduleCatalogSave()
    }

    func recordTests(_ residuals: [String: Double], nowS: Int64) {
        guard catalogLoaded, !residuals.isEmpty else { return }
        catalog.recordTests(residuals, nowS: nowS)
        catalogRevision &+= 1
        scheduleCatalogSave()
    }

    func setDEMElevations(_ elevations: [String: Double]) {
        guard catalogLoaded, !elevations.isEmpty else { return }
        for (key, elev) in elevations {
            catalog.setDEMElevation(elev, key: key)
        }
        scheduleCatalogSave()
    }

    func learnLocalBias(key: String, observedTempC: Double, nowS: Int64) {
        model?.learnLocalBias(key: key, observedTempC: observedTempC, nowS: nowS)
    }

    // MARK: Configuration (Settings > Stations)

    /// What the fetcher may use now: the networks turned on, and the keys of the keyed ones.
    var fetchConfiguration: StationNetworkFetcher.Configuration {
        let disabled = model?.stationSettings.disabledNetworks ?? []
        return StationNetworkFetcher.Configuration(
            disabled: disabled, keys: keys.filter { !disabled.contains($0.key) })
    }

    func recordStatus(_ status: StationNetworkStatus, for network: WxStationNetwork) {
        networkStatus[network] = status
    }

    /// Saves (or, with nil, removes) a network's key in the Keychain; false when the Keychain
    /// refused it.
    @discardableResult
    func setKey(_ key: String?, for network: WxStationNetwork) -> Bool {
        loadKeysIfNeeded()
        guard StationKeys.setKey(key, for: network) else { return false }
        keys[network] = StationKeys.normalized(key)
        keysChanged()
        networkStatus[network] = nil
        configurationChanged()
        return true
    }

    /// A network was turned on or off, or a key changed: every place is fetched again.
    func configurationChanged() {
        configRevision &+= 1
        if let model {
            Task { await refreshAll(model: model) }
        }
    }

    /// The catalogued stations near a point, nearest first.
    func nearbyStations(lat: Double, lon: Double, radiusKm: Double = WxStationFusion.poolRadiusKm) -> [WxStationCatalog.Nearby] {
        _ = catalogRevision
        return catalog.nearby(lat: lat, lon: lon, radiusKm: radiusKm, nowS: Int64(Date().timeIntervalSince1970))
    }

    /// Forgets every station and its track record; they are found again on the next refresh.
    func forgetAllStations() {
        guard catalogLoaded else { return }
        catalog.removeAll()
        catalogRevision &+= 1
        scheduleCatalogSave()
        configurationChanged()
    }

    private func loadKeysIfNeeded() {
        guard !keysLoaded else { return }
        keysLoaded = true
        for network in WxStationNetwork.allCases where network.requiresKey {
            if let key = StationKeys.key(for: network) {
                keys[network] = key
            }
        }
        keysChanged()
    }

    private func keysChanged() {
        networksWithKeys = Set(keys.keys)
        keyExpiries = keys.compactMapValues { WxStationKeyInfo.expiry(ofKey: $0) }
    }

    /// Writes a pending catalog save now (the app is quitting).
    private func flushCatalog() {
        guard let task = catalogSaveTask else { return }
        task.cancel()
        catalogSaveTask = nil
        catalog.save(path: catalogPath)
    }

    private func scheduleCatalogSave() {
        guard !catalogPath.isEmpty, catalogSaveTask == nil else { return }
        catalogSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.catalogSaveDelayS))
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.catalog
            let path = self.catalogPath
            self.catalogSaveTask = nil
            await Task.detached(priority: .utility) { snapshot.save(path: path) }.value
        }
    }
}

// MARK: - Live Station Discovery & Fetching Engine

nonisolated enum LiveStationFetcher {
    /// Dynamically discovers and fetches live weather and air-quality observations from every
    /// station network covering the place and from high-resolution surface models, tests the
    /// stations against each other, and fuses them (WxStationFusion).
    static func fetch(place: AppModel.Place, store: LiveStationStore) async -> LiveStationSnapshot? {
        let lat = place.place.lat
        let lon = place.place.lon
        let region = WxGeo.region(for: place.place)
        let units = place.units

        async let openMeteoTask = fetchOpenMeteoCurrent(lat: lat, lon: lon)
        async let aqiTask = fetchAirQuality(
            lat: lat, lon: lon, units: units, zone: WxFormat.Zone(timezone: place.place.timezone))
        let points = region == .us ? await StationHTTP.shared.nwsPoints(lat: lat, lon: lon) : nil
        async let nwsHourlyTask = fetchNWSHourlySky(forecastHourlyURL: points?.forecastHourly)
        let configuration = await store.fetchConfiguration
        async let observationsTask = StationNetworkFetcher.gather(
            lat: lat, lon: lon, region: region, wfo: points?.cwa, placeName: place.place.name,
            configuration: configuration, store: store)

        let (omCurrent, observations, nwsHourlySky, aqi) = await (
            openMeteoTask, observationsTask, nwsHourlyTask, aqiTask
        )
        let nowS = Int64(Date().timeIntervalSince1970)

        // Test every station against its neighbours, then blend with the updated health.
        let tested = await store.catalog
        let residuals = WxStationFusion.crossValidate(
            observations, nowS: nowS, health: { tested.health($0, nowS: nowS) })
        await store.recordTests(residuals, nowS: nowS)
        let catalog = await store.catalog
        let stations = WxStationFusion.blend(
            observations,
            lat: lat,
            lon: lon,
            targetElevationM: omCurrent?.elevationM,
            upperCloudPct: omCurrent?.upperCloudPct,
            nowS: nowS,
            health: { catalog.health($0, nowS: nowS) }
        )
        // A close, fresh station "now" is the truth the local forecast bias is learned from.
        if let stations, stations.effectiveDistanceKm <= 25.0, stations.effectiveAgeS <= 45 * 60 {
            await store.learnLocalBias(key: place.key, observedTempC: stations.tempC, nowS: nowS)
        }
        if stations == nil && omCurrent == nil && aqi == nil {
            return nil
        }

        var snapshot = LiveStationSnapshot()
        snapshot.airQuality = aqi

        if let stations {
            // Distance- and freshness-aware fusion between the elevation-adjusted multi-station
            // observation and Open-Meteo's 90m-DEM downscaled surface analysis, driven by the
            // kernel-weighted effective distance and age of the station pool:
            // - At d = 0 km, α_obs ≈ 0.95 (physical stations dominate).
            // - At d = 25 km, α_obs ≈ 0.74.
            // - At d = 60 km, α_obs ≈ 0.40 (high-resolution DEM surface analysis prevents macro-scale smoothing).
            let distFactor = exp(-pow(stations.effectiveDistanceKm / 38.0, 2.0))
            let ageFactor = exp(-Double(max(0, stations.effectiveAgeS)) / 3600.0)
            let obsAlpha = max(0.35, min(0.95, 0.35 + 0.60 * distFactor * ageFactor))

            if let omTemp = omCurrent?.tempC, omTemp.isFinite {
                snapshot.tempC = obsAlpha * stations.tempC + (1.0 - obsAlpha) * omTemp
            } else {
                snapshot.tempC = stations.tempC
            }

            if let mHum = stations.humidityPct, let omHum = omCurrent?.humidityPct, omHum.isFinite {
                snapshot.humidityPct = max(0.0, min(100.0, obsAlpha * mHum + (1.0 - obsAlpha) * omHum))
            } else {
                snapshot.humidityPct = stations.humidityPct ?? omCurrent?.humidityPct
            }

            if let mWind = stations.windKmh, let omWind = omCurrent?.windKmh, omWind.isFinite {
                snapshot.windKmh = obsAlpha * mWind + (1.0 - obsAlpha) * omWind
            } else {
                snapshot.windKmh = stations.windKmh ?? omCurrent?.windKmh
            }

            snapshot.gustKmh = stations.gustKmh ?? omCurrent?.gustKmh
            snapshot.cloudPct = stations.cloudPct ?? omCurrent?.cloudPct
            snapshot.precipMmH = stations.precipMmH ?? omCurrent?.precipMmH
            snapshot.condition = stations.condition ?? omCurrent?.condition
            snapshot.stationID = stations.stationID
            snapshot.stationName = cleanStationName(stations.stationName)
            snapshot.stationDistanceKm = stations.stationDistanceKm
            snapshot.stationCount = stations.stationCount
            for o in observations where o.tempC.isFinite {
                let t = o.obsTimeS ?? nowS
                guard nowS - t <= WxStationFusion.maxAgeS else { continue }
                snapshot.networks[o.network] = max(snapshot.networks[o.network] ?? t, t)
            }
            if let t = snapshot.tempC {
                snapshot.feelsC = LiveStationSnapshot.computeFeelsLikeC(
                    tempC: t,
                    humidityPct: snapshot.humidityPct ?? 50.0,
                    windKmh: snapshot.windKmh ?? 0.0
                )
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

    // MARK: - NWS hourly sky

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

    /// Meteorologist-calibrated hourly sky cover of the NWS hourly forecast (US).
    private static func fetchNWSHourlySky(forecastHourlyURL: String?) async -> [Int64: Double] {
        guard let forecastHourlyURL,
              let data = await StationHTTP.shared.get(forecastHourlyURL, ttlS: 600, accept: "application/geo+json"),
              let decoded = try? JSONDecoder().decode(NWSHourlyForecastResponse.self, from: data)
        else {
            return [:]
        }
        var out: [Int64: Double] = [:]
        for period in (decoded.properties?.periods ?? []).prefix(48) {
            guard let tS = WxTime.parseISO8601(period.startTime) else {
                continue
            }
            var inferredCloud: Double? = nil
            _ = WxPresentWeather.condition(
                text: period.shortForecast,
                tempC: 20.0,
                wetBulbC: 15.0,
                cloudPct: &inferredCloud
            )
            if let inferredCloud {
                out[tS] = inferredCloud
            }
        }
        return out
    }

    /// Cleans station names like "MIAMI INTL, FL, US" -> "Miami Intl", "BERLIN-TEMPELHOF" ->
    /// "Berlin-Tempelhof", "MONTREAL INT'L AIRPORT" -> "Montreal Int'l Airport".
    static func cleanStationName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let firstPart = raw.split(separator: ",").first.map(String.init) ?? raw
        let trimmed = firstPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = trimmed
            .split(separator: " ")
            .map { word -> String in
                switch word.uppercased() {
                case "AP", "ARPT": return "Airport"
                case "INTL": return "Intl"
                case "EXEC": return "Executive"
                case "MUNI": return "Municipal"
                case "RGNL": return "Regional"
                default: return String(word)
                }
            }
            .joined(separator: " ")
        // Title-case only all-caps names; mixed-case names are already written as intended.
        guard expanded == expanded.uppercased() else { return expanded }
        var out = ""
        var startOfWord = true
        for ch in expanded {
            out.append(contentsOf: startOfWord ? String(ch).uppercased() : String(ch).lowercased())
            startOfWord = ch == " " || ch == "-" || ch == "/" || ch == "("
        }
        return out
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
            /// The period the aggregated values (precipitation) cover, s (900: the last 15 minutes).
            let interval: Int?
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
            format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,rain,showers,snowfall,weather_code,cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,wind_speed_10m,wind_gusts_10m&hourly=cloud_cover_low,cloud_cover_mid,cloud_cover_high,precipitation&minutely_15=precipitation&forecast_days=2&forecast_minutely_15=9&timeformat=unixtime",
            lat, lon
        )
        // Through StationHTTP like every live request: a bounded wait, a short cache, the app's
        // User-Agent, and a request that outlives the cancellation of the caller's task. The 300 s
        // TTL absorbs repeated triggers (units/config changes, focus rounds every >= 120 s) and stays
        // below the 540 s between periodic rounds (RefreshScheduler.periodicFreshUS), so a periodic
        // round never gets the previous periodic round's answer. A units or station-config change
        // (or a focus round) also starts a live fetch outside the periodic rounds, and a periodic
        // round within 300 s after it reuses that answer: a round's data is at most 300 s old.
        guard case .ok(let data) = await StationHTTP.shared.fetch(urlStr, ttlS: 300, timeoutS: 10) else {
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
            guard let cur = decoded.current else { return nil }
            // "current" precipitation is the sum over the last `interval` seconds: as a rate, mm/h.
            let precipMmH = cur.precipitation.map { $0 * 3600.0 / Double(max(cur.interval ?? 900, 1)) }

            let effectiveCloud: Double? = {
                if let low = cur.cloud_cover_low, let mid = cur.cloud_cover_mid, let high = cur.cloud_cover_high {
                    return altitudeWeightedCloud(
                        low: low,
                        mid: mid,
                        high: high,
                        precipMm: precipMmH ?? 0.0
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
                        precipMm: precipMmH ?? 0.0
                    )
                }
                return nil
            }()

            let precipRate = precipMmH ?? 0.0
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
                    // Each value is the sum over the 15 minutes BEFORE its time (as OpenMeteoParse
                    // maps it); a WxQuarter starts at tS. One more than the 8 nowcast slots is
                    // asked for, since the first one ends now.
                    let tS = times[i] - 900
                    guard tS >= WxLimits.timeMinS, tS < WxLimits.timeMaxS, tS % 900 == 0 else {
                        continue
                    }
                    let mm15 = precips[i] ?? 0.0
                    quarters.append(WxQuarter(tS: tS, precipMm: max(0.0, mm15)))
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
                precipMmH: precipMmH,
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

    // MARK: - 3. Air quality (nearest AirNow monitor as reported, else the CAMS forecast)

    /// The Air Quality card (WxAirQuality): the nearest AirNow monitor's latest reading and the
    /// same monitor's reading 24 hours earlier; else the CAMS forecast for the place. nil when
    /// neither answered (the card then shows the dash).
    private static func fetchAirQuality(
        lat: Double,
        lon: Double,
        units: WxUnits,
        zone: WxFormat.Zone
    ) async -> DetailViewModel.AirQualityCard? {
        let nowS = Int64(Date().timeIntervalSince1970)
        // AirNow's monitors are in the Americas (and at US embassies); Europe is the model's.
        let inEurope = WxGeo.inEurope(lat: lat, lon: lon)
        let dayAgo = WxAirQuality.dayAgoWindow(nowS: nowS)
        async let currentTask = airNowReadings(
            inEurope ? nil : WxAirQuality.airNowCurrentURL(lat: lat, lon: lon), lat: lat, lon: lon, ttlS: 600)
        async let historyTask = airNowReadings(
            inEurope ? nil : WxAirQuality.airNowHourlyURL(lat: lat, lon: lon, startS: dayAgo.startS, endS: dayAgo.endS),
            lat: lat, lon: lon, ttlS: 3600)
        async let modelTask = camsReading(lat: lat, lon: lon)

        var monitor = WxAirQuality.nearestMonitor(await currentTask, nowS: nowS)
        if monitor == nil, !inEurope {
            // The current layer had no fresh reading: the hourly layer's last hours.
            let recent = WxAirQuality.recentWindow(nowS: nowS)
            let readings = await airNowReadings(
                WxAirQuality.airNowHourlyURL(lat: lat, lon: lon, startS: recent.startS, endS: recent.endS),
                lat: lat, lon: lon, ttlS: 600)
            monitor = WxAirQuality.nearestMonitor(readings, nowS: nowS)
        }
        if let monitor {
            let dayAgoAQI = WxAirQuality.dayAgoAQI(of: monitor, in: await historyTask)
            return WxAirQuality.card(monitor: monitor, dayAgoAQI: dayAgoAQI, units: units, zone: zone)
        }
        if let model = await modelTask, abs(nowS - model.tS) <= WxAirQuality.maxAgeS {
            return WxAirQuality.card(model: model, inEurope: inEurope, zone: zone)
        }
        return nil
    }

    /// The readings of an AirNow layer query; empty without a URL or an answer.
    private static func airNowReadings(_ url: String?, lat: Double, lon: Double,
                                       ttlS: TimeInterval) async -> [WxAirQuality.MonitorReading] {
        guard let url, case .ok(let data) = await StationHTTP.shared.fetch(url, ttlS: ttlS, timeoutS: 10) else {
            return []
        }
        return WxAirQuality.parseAirNow(data, lat: lat, lon: lon) ?? []
    }

    private static func camsReading(lat: Double, lon: Double) async -> WxAirQuality.ModelReading? {
        guard case .ok(let data) = await StationHTTP.shared.fetch(
            WxAirQuality.openMeteoURL(lat: lat, lon: lon), ttlS: 900, timeoutS: 10)
        else {
            return nil
        }
        return WxAirQuality.parseOpenMeteo(data)
    }
}
