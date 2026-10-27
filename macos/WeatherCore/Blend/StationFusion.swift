// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationFusion.swift - multi-network surface-station assimilation for the
// "now" values: every nearby report from every observing network the app can
// reach goes into ONE pool and through ONE algorithm, whatever the country:
//
//   1. same-site merge: two reports closer than `sameSiteKm` are one site (an
//      airport METAR and its ASOS/SYNOP/SWOB twin); the freshest report wins
//      and the older one only fills the variables the fresh one lacks;
//   2. 3D anisotropic kernel: horizontal Gaussian x Cauchy (L_h = 22 km,
//      d_0 = 8 km) times a vertical Gaussian (L_z = 350 m), after reducing
//      temperature and dewpoint to the target elevation with a day/night
//      lapse rate; times the site's trust (network class, a prior) and its
//      health (its measured track record, WxStationCatalog);
//   3. pool: the `poolMaxStations` sites of largest expected weight within
//      `poolRadiusKm`;
//   4. Shepard (1968) directional de-clustering;
//   5. robust buddy check for gross errors (a sun-baked, indoor or failed sensor):
//      median / MAD (scaled by 1.4826 to a Gaussian sigma, floored at 1.5 °C) of the
//      elevation-reduced temperatures, soft (T/r)^2 penalty beyond 3 sigma, so a real
//      mesoscale contrast of up to 4.5 °C (sea breeze, urban heat) is never penalized;
//   6. per-variable freshness decay (temperature 45 min, wind 20 min, sky and
//      precipitation 15 min).
//
// `crossValidate` scores every site against its neighbours (leave-one-out), the
// input of the station health record.
//
// Pure: no I/O and no clock; `nowS` is an argument. The networking lives in
// the app target (LiveStationFetcher), the parsers in StationNetworks.swift.

import Foundation

extension WxCondition: Codable {}

/// The surface-observation network a report came from.
public enum WxStationNetwork: String, Sendable, CaseIterable, Codable {
    /// NOAA Aviation Weather Center METAR/SPECI, worldwide airports (hourly plus specials).
    case metar
    /// NWS api.weather.gov latest ASOS/AWOS report (US airports, as often as every 5 minutes).
    case nwsASOS
    /// Environment and Climate Change Canada SWOB-ML real-time reports (Canada, up to every minute).
    case ecccSWOB
    /// Iowa Environmental Mesonet current reports of US non-airport networks (state DOT road
    /// weather, NWS HADS hydro-met gauges, soil-climate and research sites).
    case iemMesonet
    /// DWD SYNOP reports via Bright Sky (Germany, every 10 minutes).
    case dwdSYNOP
    /// Danish Meteorological Institute metObs (Denmark, every 10 minutes).
    case dmi
    /// Finnish Meteorological Institute open data (Finland, every 10 minutes).
    case fmi
    /// Swedish Meteorological and Hydrological Institute open data (Sweden, hourly).
    case smhi
    /// GeoSphere Austria TAWES (Austria, every 10 minutes).
    case geosphere
    /// MeteoSwiss SwissMetNet (Switzerland, every 10 minutes).
    case meteoSwiss
    // The networks below need the user's own key (Settings > Stations).
    /// UK Met Office observations (United Kingdom).
    case metOffice
    /// KNMI 10-minute in-situ observations (Netherlands).
    case knmi
    /// MET Norway Frost observations (Norway).
    case frost
    /// Météo-France observations (France).
    case meteoFrance
    /// AEMET OpenData conventional observations (Spain).
    case aemet

    /// Whether the network codes present weather by default (a report without a weather group
    /// then means "no weather"). Networks that only code it at some sites set it per report.
    public var defaultReportsPresentWeather: Bool {
        switch self {
        case .metar, .nwsASOS, .dwdSYNOP: true
        default: false
        }
    }

    /// Cloud comes from a laser ceilometer that cannot see above ~12,000 ft (ASOS/AWOS and
    /// automatic METARs), so "clear" only means "clear below the ceilometer".
    public var defaultCloudIsCeilometerLimited: Bool { self == .metar || self == .nwsASOS }
}

/// One surface observation, in °C, km/h, mm/h and percent.
public struct WxStationObservation: Sendable, Equatable, Codable {
    public var network: WxStationNetwork
    /// Station identifier, unique within its network (ICAO, WMO, national or provider id).
    public var id: String
    public var name: String?
    public var lat: Double
    public var lon: Double
    /// Station elevation above mean sea level, m.
    public var elevM: Double?
    /// Observation time, UTC unix seconds (nil: unknown, treated as 20 minutes old).
    public var obsTimeS: Int64?
    public var tempC: Double
    public var dewpC: Double?
    public var humidityPct: Double?
    public var windKmh: Double?
    public var gustKmh: Double?
    /// Observed cloud cover, %. For a ceilometer-limited report this is the cover below ~12,000 ft.
    public var cloudPct: Double?
    /// Precipitation rate, mm/h.
    public var precipMmH: Double?
    /// METAR present-weather groups (e.g. "-RA BR"); empty or nil means none reported.
    public var wxString: String?
    /// Present weather already decoded (NWS text, DWD condition, WMO 4677/4680 code).
    public var condition: WxCondition?
    /// The site codes present weather, so a report without weather means "no weather".
    public var reportsPresentWeather: Bool
    /// The cloud comes from a ceilometer that cannot see above ~12,000 ft.
    public var cloudIsCeilometerLimited: Bool
    /// Prior trust in the site's temperature and humidity (siting, maintenance, sensor class),
    /// 0...1: 1 for WMO-standard national networks, less for road-weather, hydrological and
    /// partner sites. The site's measured health (WxStationCatalog) multiplies it.
    public var trust: Double
    /// Prior trust in the site's wind (many non-standard sites measure below 10 m), 0...1.
    public var windTrust: Double

    /// The catalog key, "network:id".
    public var key: String { "\(network.rawValue):\(id)" }

    public init(
        network: WxStationNetwork, id: String, name: String? = nil, lat: Double, lon: Double,
        elevM: Double? = nil, obsTimeS: Int64? = nil, tempC: Double, dewpC: Double? = nil,
        humidityPct: Double? = nil, windKmh: Double? = nil, gustKmh: Double? = nil,
        cloudPct: Double? = nil, precipMmH: Double? = nil, wxString: String? = nil,
        condition: WxCondition? = nil, reportsPresentWeather: Bool? = nil,
        cloudIsCeilometerLimited: Bool? = nil, trust: Double = 1.0, windTrust: Double? = nil
    ) {
        self.network = network
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.elevM = elevM
        self.obsTimeS = obsTimeS
        self.tempC = tempC
        self.dewpC = dewpC
        self.humidityPct = humidityPct
        self.windKmh = windKmh
        self.gustKmh = gustKmh
        self.cloudPct = cloudPct
        self.precipMmH = precipMmH
        self.wxString = wxString
        self.condition = condition
        self.reportsPresentWeather = reportsPresentWeather ?? network.defaultReportsPresentWeather
        self.cloudIsCeilometerLimited = cloudIsCeilometerLimited ?? network.defaultCloudIsCeilometerLimited
        self.trust = max(0.0, min(1.0, trust))
        self.windTrust = max(0.0, min(1.0, windTrust ?? trust))
    }
}

/// The fused "now" values of the station pool.
public struct WxStationBlend: Sendable, Equatable {
    public var tempC: Double
    public var humidityPct: Double?
    public var windKmh: Double?
    public var gustKmh: Double?
    public var cloudPct: Double?
    public var precipMmH: Double?
    public var condition: WxCondition?
    /// The nearest site of the pool (the one named in the UI).
    public var stationID: String
    public var stationName: String?
    public var stationDistanceKm: Double
    /// Kernel-weighted mean distance of the pool, km: how far the fused value effectively comes from.
    public var effectiveDistanceKm: Double
    /// Kernel-weighted mean age of the pool, s.
    public var effectiveAgeS: Int64
    /// Number of distinct sites blended.
    public var stationCount: Int
}

/// Multi-network station assimilation (see the file header).
public enum WxStationFusion {
    /// Candidate search radius, km; the nearest usable site inside it is always used.
    public static let searchRadiusKm = 95.0
    /// Blending pool radius, km, and its size cap.
    public static let poolRadiusKm = 60.0
    public static let poolMaxStations = 12
    /// Reports closer than this are the same site, km.
    public static let sameSiteKm = 1.5
    /// Reports older than this are ignored, s.
    public static let maxAgeS: Int64 = 3 * 3600
    /// Present weather is taken from the nearest weather-reporting site within this distance, km,
    /// when its report is at most `presentWeatherMaxAgeS` old.
    public static let presentWeatherRadiusKm = 38.0
    public static let presentWeatherMaxAgeS: Int64 = 90 * 60
    /// Leave-one-out testing: neighbours within this distance, km, of reports at most this old, s.
    public static let crossValidationRadiusKm = 40.0
    public static let crossValidationMaxAgeS: Int64 = 90 * 60
    /// Age assumed for a report without a time, s.
    static let unknownAgeS: Int64 = 1200

    // Kernel and QC constants (ALGORITHMS_AND_ARCHITECTURE.md §6).
    static let horizontalScaleKm = 22.0
    static let horizontalCoreKm = 8.0
    static let verticalScaleM = 350.0
    static let maxElevationDeltaM = 1800.0
    static let dayLapseRatePerM = -0.0068
    static let nightLapseRatePerM = -0.0042
    static let dewpointLapseRatePerM = -0.0019
    static let madToSigma = 1.4826
    static let qcSigmaFloorC = 1.5
    static let qcThresholdSigmas = 3.0
    static let tauTempS = 2700.0
    static let tauWindS = 1200.0
    static let tauSkyS = 900.0
    /// Gust excess (RMS over the pool) below this is not reported as a gust, km/h.
    static let minGustExcessKmh = 3.5

    // MARK: - Search geometry

    /// A latitude/longitude box that contains the circle of `radiusKm` around (lat, lon). The
    /// longitude half-width is the latitude half-width divided by cos(lat), so the box is not
    /// squeezed east-west at high latitudes (at 52°N a square-degree box reaches only 62% as far
    /// east-west as north-south). Clamped to the valid range; not wrapped across the antimeridian.
    public static func searchBox(
        lat: Double, lon: Double, radiusKm: Double
    ) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        // 1° of latitude is 111.19 km on the haversine sphere; 111.0 leaves a small margin
        let dLat = radiusKm / 111.0
        let cosLat = cos(lat * .pi / 180.0)
        let dLon = min(30.0, dLat / max(0.05, cosLat))
        return (
            max(-89.9, lat - dLat), max(-179.9, lon - dLon),
            min(89.9, lat + dLat), min(179.9, lon + dLon)
        )
    }

    // MARK: - Same-site merge

    /// Collapses reports of one site (closer than `sameSiteKm`) into one: the freshest report is
    /// kept and the older ones only fill the variables it lacks. Reports without a finite
    /// temperature or position are dropped. Order: freshest first. With `nowS`, an older report
    /// lends its present weather only while it is at most `presentWeatherMaxAgeS` old.
    public static func mergeSameSite(
        _ observations: [WxStationObservation], nowS: Int64? = nil
    ) -> [WxStationObservation] {
        let usable = observations.filter {
            $0.tempC.isFinite && $0.lat.isFinite && $0.lon.isFinite
                && WxGeo.isValid(lat: $0.lat, lon: $0.lon)
        }
        let byFreshness = usable.enumerated().sorted { a, b in
            let ta = a.element.obsTimeS ?? Int64.min
            let tb = b.element.obsTimeS ?? Int64.min
            return ta != tb ? ta > tb : a.offset < b.offset
        }.map(\.element)

        var merged: [WxStationObservation] = []
        for obs in byFreshness {
            guard let k = merged.firstIndex(where: {
                WxGeo.distanceKm(aLat: $0.lat, aLon: $0.lon, bLat: obs.lat, bLon: obs.lon) < sameSiteKm
            }) else {
                merged.append(obs)
                continue
            }
            var site = merged[k]
            site.name = site.name ?? obs.name
            site.elevM = site.elevM ?? obs.elevM
            if site.dewpC == nil && site.humidityPct == nil {
                // as a dew point: a humidity belongs to the older report's own temperature
                site.dewpC = obs.dewpC.flatMap { $0.isFinite ? $0 : nil }
                    ?? obs.humidityPct.flatMap { dewpointC(tempC: obs.tempC, humidityPct: $0) }
            }
            if site.windKmh == nil, let wind = obs.windKmh {
                site.windKmh = wind
                site.gustKmh = obs.gustKmh
                site.windTrust = obs.windTrust
            }
            site.precipMmH = site.precipMmH ?? obs.precipMmH
            if site.cloudPct == nil, let cloud = obs.cloudPct {
                site.cloudPct = cloud
                site.cloudIsCeilometerLimited = obs.cloudIsCeilometerLimited
            }
            // A fresher report that codes weather keeps its "no weather"; one that cannot code
            // weather (SWOB, most mesonets) takes the older report's weather while it is current.
            let weatherIsCurrent = nowS.map { now in
                (obs.obsTimeS.map { max(0, now - $0) } ?? unknownAgeS) <= presentWeatherMaxAgeS
            } ?? true
            if !site.reportsPresentWeather && obs.reportsPresentWeather && weatherIsCurrent {
                site.wxString = obs.wxString
                site.condition = obs.condition
                site.reportsPresentWeather = true
            }
            // the site is as trustworthy as the best sensor that reported it
            site.trust = max(site.trust, obs.trust)
            merged[k] = site
        }
        return merged
    }

    // MARK: - Fusion

    /// One site with its kernel factors relative to a target point.
    struct Candidate {
        let obs: WxStationObservation
        let distKm: Double
        let bearingRad: Double
        let ageS: Int64
        let adjustedTempC: Double
        let adjustedDewpC: Double?
        let horizWeight: Double
        let vertWeight: Double
        /// trust x health, 0...1.
        let quality: Double
        var shepardFactor = 1.0
        var qcPenalty = 1.0

        var priorWeight: Double { horizWeight * vertWeight * quality }
        var spatialWeight: Double { priorWeight * shepardFactor * qcPenalty }
    }

    /// The reports as candidates around (lat, lon): usable, within `radiusKm` and `maxAge`,
    /// temperature and dewpoint reduced to `targetElevationM`, sorted by distance.
    static func candidates(
        _ sites: [WxStationObservation], lat: Double, lon: Double, targetElevationM: Double?,
        nowS: Int64, radiusKm: Double, maxAge: Int64, health: (String) -> Double
    ) -> [Candidate] {
        let gammaTemp = WxGeo.sunIsUp(lat: lat, lon: lon, t: nowS) ? dayLapseRatePerM : nightLapseRatePerM
        return sites.compactMap { obs in
            guard obs.tempC >= -90, obs.tempC <= 65 else { return nil }
            let quality = obs.trust * max(0.0, min(1.0, health(obs.key)))
            guard quality > 0 else { return nil }
            let ageS = obs.obsTimeS.map { max(0, nowS - $0) } ?? unknownAgeS
            guard ageS <= maxAge else { return nil }
            let d = WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: obs.lat, bLon: obs.lon)
            guard d.isFinite, d <= radiusKm else { return nil }

            // Δz = z_target - z_station, clamped
            var dz = 0.0
            if let z0 = targetElevationM, let zs = obs.elevM, z0.isFinite, zs.isFinite {
                dz = max(-maxElevationDeltaM, min(maxElevationDeltaM, z0 - zs))
            }
            let adjTemp = obs.tempC + gammaTemp * dz
            let rawDewp: Double? = obs.dewpC.flatMap { $0.isFinite ? $0 : nil }
                ?? obs.humidityPct.flatMap { dewpointC(tempC: obs.tempC, humidityPct: $0) }
            let adjDewp: Double? = rawDewp.flatMap { td in
                guard td >= -95, td <= 50 else { return nil }
                return min(adjTemp, td + dewpointLapseRatePerM * dz)
            }
            let ls = horizontalScaleKm
            let wHoriz = exp(-(d * d) / (2.0 * ls * ls)) / (1.0 + (d / horizontalCoreKm) * (d / horizontalCoreKm))
            let wVert = exp(-(dz * dz) / (2.0 * verticalScaleM * verticalScaleM))
            return Candidate(
                obs: obs, distKm: d,
                bearingRad: initialBearingRadians(fromLat: lat, fromLon: lon, toLat: obs.lat, toLon: obs.lon),
                ageS: ageS, adjustedTempC: adjTemp, adjustedDewpC: adjDewp,
                horizWeight: wHoriz, vertWeight: wVert, quality: quality)
        }
        .sorted { $0.distKm < $1.distKm }
    }

    /// Shepard directional isolation (a tight cluster on one bearing must not outvote an isolated
    /// site on the other side) and the buddy check, in place.
    static func declusterAndCheck(_ pool: inout [Candidate]) {
        if pool.count >= 2 {
            for i in pool.indices {
                var shadow = 0.0
                for j in pool.indices where j != i {
                    let overlap = pow(max(0.0, (1.0 + cos(pool[i].bearingRad - pool[j].bearingRad)) * 0.5), 4.0)
                    let ratio = sqrt(max(1e-6, pool[j].priorWeight / max(pool[i].priorWeight, 1e-9)))
                    shadow += min(ratio, 3.0) * overlap
                }
                pool[i].shepardFactor = 1.0 / (1.0 + shadow)
            }
        }
        if pool.count >= 3 {
            let temps = pool.map(\.adjustedTempC)
            let center = median(temps)
            let sigma = max(qcSigmaFloorC, madToSigma * median(temps.map { abs($0 - center) }))
            let threshold = qcThresholdSigmas * sigma
            for i in pool.indices {
                let resid = abs(pool[i].adjustedTempC - center)
                if resid > threshold {
                    pool[i].qcPenalty = (threshold / resid) * (threshold / resid)
                }
            }
        }
    }

    /// Fuses the reports around (lat, lon) into one set of "now" values (see the file header), or
    /// nil when no usable report lies within `searchRadiusKm`.
    ///
    /// - Parameters:
    ///   - targetElevationM: elevation of the place, m (nil: no elevation reduction).
    ///   - upperCloudPct: NWP mid/high cloud cover, %, fused with a ceilometer-limited clear report.
    ///   - nowS: the current time, UTC unix seconds.
    ///   - health: the measured health of a site by catalog key, 0...1 (0 excludes it).
    public static func blend(
        _ observations: [WxStationObservation], lat: Double, lon: Double,
        targetElevationM: Double?, upperCloudPct: Double?, nowS: Int64,
        health: (String) -> Double = { _ in 1.0 }
    ) -> WxStationBlend? {
        guard WxGeo.isValid(lat: lat, lon: lon) else { return nil }
        // Reports that cannot be candidates are dropped before the merge, so an excluded or stale
        // report can neither absorb nor fill a usable twin.
        let usable = observations.filter {
            $0.tempC >= -90 && $0.tempC <= 65 && $0.trust * max(0.0, min(1.0, health($0.key))) > 0
                && ($0.obsTimeS.map { nowS - $0 } ?? unknownAgeS) <= maxAgeS
        }
        let ranked = candidates(
            mergeSameSite(usable, nowS: nowS), lat: lat, lon: lon, targetElevationM: targetElevationM,
            nowS: nowS, radiusKm: searchRadiusKm, maxAge: maxAgeS, health: health)
        guard let nearestUsable = ranked.first else { return nil }

        // The pool: the sites of largest expected weight (not merely the nearest, so a crowd of
        // low-trust gauges cannot push out a first-class station a little farther away).
        let inRadius = ranked.filter { $0.distKm <= poolRadiusKm }
        var pool = Array(inRadius.sorted { $0.priorWeight > $1.priorWeight }.prefix(poolMaxStations))
        if pool.isEmpty {
            pool = [nearestUsable]
        }
        declusterAndCheck(&pool)
        let nearest = pool.min { $0.distKm < $1.distKm } ?? nearestUsable

        var temp = Accumulator(), dewp = Accumulator(), wind = Accumulator()
        var gustExcessSq = Accumulator(), cloud = Accumulator(), precip = Accumulator()
        var dist = Accumulator(), age = Accumulator()
        for c in pool {
            let w = c.spatialWeight
            let wTemp = w * exp(-Double(c.ageS) / tauTempS)
            let wWind = w * c.obs.windTrust / max(c.obs.trust, 1e-9) * exp(-Double(c.ageS) / tauWindS)
            let wSky = w * exp(-Double(c.ageS) / tauSkyS)

            temp.add(c.adjustedTempC, wTemp)
            dist.add(c.distKm, wTemp)
            age.add(Double(c.ageS), wTemp)
            if let td = c.adjustedDewpC {
                dewp.add(td, wTemp)
            }
            if let v = c.obs.windKmh, v.isFinite, v >= 0 {
                wind.add(v, wWind)
                if let g = c.obs.gustKmh, g.isFinite, g > v {
                    gustExcessSq.add((g - v) * (g - v), wWind)
                }
            }
            if let raw = c.obs.cloudPct, raw.isFinite {
                let pct = max(0.0, min(100.0, raw))
                cloud.add(c.obs.cloudIsCeilometerLimited
                    ? fuseUpperCloud(stationCloudPct: pct, upperCloudPct: upperCloudPct) : pct, wSky)
            }
            if let p = c.obs.precipMmH, p.isFinite, p >= 0 {
                precip.add(p, wSky)
            }
        }

        guard let tempC = temp.mean else { return nil }
        let humidity = dewp.mean.map { relativeHumidity(tempC: tempC, dewpC: min(tempC, $0)) }
        let windKmh = wind.mean
        let gustKmh: Double? = {
            guard let u = windKmh, let sq = gustExcessSq.mean else { return nil }
            let excess = sqrt(sq)
            return excess >= minGustExcessKmh ? u + excess : nil
        }()
        let cloudPct = cloud.mean
        var precipMmH = precip.mean

        // Present weather: the nearest weather-reporting site close enough and fresh enough. Its
        // silence counts ("no weather"); sites that never code weather are skipped.
        var condition: WxCondition? = nil
        if let wx = ranked.first(where: {
            $0.obs.reportsPresentWeather && $0.distKm <= presentWeatherRadiusKm
                && $0.ageS <= presentWeatherMaxAgeS
        }) {
            if let decoded = wx.obs.condition, decoded != .unknown {
                condition = decoded
            } else if let text = wx.obs.wxString, !text.isEmpty {
                condition = parseMETARPresentWeather(
                    text, tempC: tempC, wetBulbC: wetBulbC(tempC: tempC, humidityPct: humidity ?? 55.0),
                    cloudPct: cloudPct ?? 50.0)
            }
        }
        if precipMmH == nil, let condition, WxConditionSymbol.precipitationRank(condition) > 0 {
            precipMmH = switch condition {
            case .heavyRain, .thunderstorm: 8.5
            case .rain, .snow, .sleet: 3.0
            case .lightRain, .showers: 1.0
            case .drizzle: 0.3
            default: 0.0
            }
        }
        // A dry-sky class is decided by the observed cloud, not by a coded "no weather".
        if let cloudPct, condition == nil || WxConditionSymbol.precipitationRank(condition!) == 0 && condition != .fog {
            condition = WxConditionRules.cloudCondition(cloudPct)
        }

        return WxStationBlend(
            tempC: tempC, humidityPct: humidity, windKmh: windKmh, gustKmh: gustKmh,
            cloudPct: cloudPct, precipMmH: precipMmH, condition: condition,
            stationID: nearest.obs.id, stationName: nearest.obs.name, stationDistanceKm: nearest.distKm,
            effectiveDistanceKm: dist.mean ?? nearest.distKm,
            effectiveAgeS: Int64((age.mean ?? Double(nearest.ageS)).rounded()),
            stationCount: pool.count)
    }

    // MARK: - Station testing

    /// Leave-one-out residuals: for every site with at least two usable neighbours within
    /// `crossValidationRadiusKm`, its elevation-reduced temperature minus the temperature its
    /// neighbours predict at its location (same kernel, trust, health, Shepard and buddy check).
    /// Positive: the site reads warmer than its neighbours say it should. Reports older than
    /// `crossValidationMaxAgeS` are neither tested nor used as neighbours.
    ///
    /// - Returns: residual °C by catalog key.
    public static func crossValidate(
        _ observations: [WxStationObservation], nowS: Int64, health: (String) -> Double = { _ in 1.0 }
    ) -> [String: Double] {
        let recent = observations.filter {
            ($0.obsTimeS.map { nowS - $0 } ?? unknownAgeS) <= crossValidationMaxAgeS
        }
        // An excluded report is still tested (so it can recover), but on its own: merged, it would
        // take a healthy twin's place under its key.
        let sites = mergeSameSite(recent.filter { health($0.key) > 0 }, nowS: nowS)
            + recent.filter { !(health($0.key) > 0) }.flatMap { mergeSameSite([$0]) }
        var out: [String: Double] = [:]
        for (i, site) in sites.enumerated() {
            // Neighbours keep their own health: a sick neighbour must not condemn a healthy site.
            var others = sites
            others.remove(at: i)
            var pool = candidates(
                others, lat: site.lat, lon: site.lon, targetElevationM: site.elevM, nowS: nowS,
                radiusKm: crossValidationRadiusKm, maxAge: crossValidationMaxAgeS, health: health)
            pool = Array(pool.sorted { $0.priorWeight > $1.priorWeight }.prefix(poolMaxStations))
            guard pool.count >= 2 else { continue }
            declusterAndCheck(&pool)
            var acc = Accumulator()
            for c in pool {
                acc.add(c.adjustedTempC, c.spatialWeight * exp(-Double(c.ageS) / tauTempS))
            }
            if let predicted = acc.mean {
                out[site.key] = site.tempC - predicted
            }
        }
        return out
    }

    // MARK: - Physics helpers

    /// A ceilometer-limited "mostly clear" report (< 25%) under substantial NWP cloud aloft (> 30%)
    /// is combined with the cloud aloft by random overlap; any other report is kept.
    public static func fuseUpperCloud(stationCloudPct: Double, upperCloudPct: Double?) -> Double {
        guard let upper = upperCloudPct, upper.isFinite, stationCloudPct < 25.0, upper > 30.0 else {
            return stationCloudPct
        }
        let lowT = 1.0 - stationCloudPct / 100.0
        let highT = 1.0 - min(100.0, upper) / 100.0
        return max(0.0, min(100.0, 100.0 * (1.0 - lowT * highT)))
    }

    /// Relative humidity (0...100%) from temperature and dewpoint, °C (Magnus form, Alduchov &
    /// Eskridge 1996: a = 17.625, b = 243.04 °C).
    public static func relativeHumidity(tempC: Double, dewpC: Double) -> Double {
        let a = 17.625, b = 243.04
        let rh = 100.0 * exp(a * dewpC / (b + dewpC) - a * tempC / (b + tempC))
        return max(0.0, min(100.0, rh))
    }

    /// Dewpoint, °C, from temperature and relative humidity (inverse Magnus); nil for RH outside (0, 100].
    public static func dewpointC(tempC: Double, humidityPct: Double) -> Double? {
        guard tempC.isFinite, humidityPct.isFinite, humidityPct > 0, humidityPct <= 100 else { return nil }
        let a = 17.625, b = 243.04
        let gamma = log(humidityPct / 100.0) + a * tempC / (b + tempC)
        return b * gamma / (a - gamma)
    }

    /// Psychrometric wet-bulb temperature, °C (Stull 2011), for rain / sleet / snow discrimination.
    public static func wetBulbC(tempC: Double, humidityPct: Double) -> Double {
        let rh = max(5.0, min(100.0, humidityPct))
        let t = tempC
        return t * atan(0.151977 * sqrt(rh + 8.313659)) + atan(t + rh) - atan(rh - 1.676331)
            + 0.00391838 * pow(rh, 1.5) * atan(0.023101 * rh) - 4.686035
    }

    /// Decodes METAR present-weather groups (WMO Code 4678 abbreviations) into a condition, using
    /// the wet-bulb temperature for the phase of reported snow / mixed precipitation.
    public static func parseMETARPresentWeather(
        _ wx: String, tempC: Double, wetBulbC: Double, cloudPct: Double
    ) -> WxCondition? {
        // Groups that fall nowhere at the station are skipped: lifted by the wind (BL blowing, DR
        // drifting: "BLSN" is not snowfall) and in the vicinity ("VCSH", "VCFG"), except thunder.
        let u = wx.uppercased().split(separator: " ").filter { group in
            let g = group.drop { $0 == "+" || $0 == "-" }
            return !(g.hasPrefix("BL") || g.hasPrefix("DR") || (g.hasPrefix("VC") && !g.contains("TS")))
        }.joined(separator: " ")
        if u.contains("TS") {
            return .thunderstorm
        }
        if u.contains("FZRA") || u.contains("FZDZ") || u.contains("PL") || u.contains("IC") {
            return .sleet
        }
        if u.contains("SN") || u.contains("SG") || u.contains("GS") || u.contains("GR") {
            return wetBulbC <= 0.8 ? .snow : (wetBulbC <= 2.0 ? .sleet : .rain)
        }
        if u.contains("SH") {
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

    /// Initial great-circle bearing, radians, from the first point to the second.
    static func initialBearingRadians(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> Double {
        let phi1 = fromLat * .pi / 180.0
        let phi2 = toLat * .pi / 180.0
        let dLon = (toLon - fromLon) * .pi / 180.0
        return atan2(sin(dLon) * cos(phi2), cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLon))
    }

    /// Median of a non-empty array (mean of the two middle values for an even count).
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2.0
    }

    /// A weighted mean that ignores non-positive weights.
    struct Accumulator {
        private var sum = 0.0
        private var weight = 0.0

        mutating func add(_ value: Double, _ w: Double) {
            guard value.isFinite, w.isFinite, w > 0 else { return }
            sum += value * w
            weight += w
        }

        var mean: Double? { weight > 0 ? sum / weight : nil }
    }
}
