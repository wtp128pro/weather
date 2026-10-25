// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// LocalBias.swift - learned local temperature bias of the blended forecast, per
// place and per solar hour of the day, from the fused station observations.
//
// Models are smooth: they miss the valley that runs 3 °C colder on clear nights,
// the downtown that stays warmer, the lake shore. Those errors are systematic and
// repeat with the hour of the day, so the app learns them: every time the station
// pool gives a trustworthy "now" (close, fresh stations), the difference
// observed - model at that solar hour updates an exponentially weighted mean
// (the decaying-average bias correction of NCEP's NAEFS / the NWS National Blend).
// The whole forecast - every hour, so also the daily highs and lows - is then
// shifted by the learned bias of its solar hour:
//
//   - 24 solar-hour bins (the sun, not the time zone, drives the diurnal cycle),
//     smoothed [1, 2, 1] over neighbouring hours when applied;
//   - at most one sample per bin every `minSpacingS`; |error| > `maxSampleErrorC`
//     is discarded as a bad sample, not learned;
//   - weight of a new sample max(alpha, 1 / (n + 1)) (memory of about 2 weeks);
//   - applied only from `minSamples` samples, at full strength from
//     `fullConfidenceSamples`, capped at ±`maxCorrectionC`;
//   - a record not updated for more than `staleAfterS` (the season has changed)
//     fades out with an e-folding time of `staleAfterS`, until new samples come.
//
// Time with the app closed pauses the learning; it does not erase it.

import Foundation

/// Learned local bias of the forecast temperature (see the file header).
public struct WxLocalBias: Sendable, Equatable, Codable {
    /// One place's record.
    public struct PlaceRecord: Sendable, Equatable, Codable {
        /// Observed minus model, °C, by solar hour 0...23.
        public var biasC: [Double]
        public var counts: [Int]
        public var lastSampleS: [Int64]
        public var lastUpdateS: Int64

        init() {
            biasC = Array(repeating: 0, count: 24)
            counts = Array(repeating: 0, count: 24)
            lastSampleS = Array(repeating: 0, count: 24)
            lastUpdateS = 0
        }
    }

    public static let alpha = 0.07
    public static let minSpacingS: Int64 = 20 * 60
    public static let maxSampleErrorC = 10.0
    public static let minSamples = 3
    public static let fullConfidenceSamples = 6
    public static let maxCorrectionC = 4.0
    public static let staleAfterS: Int64 = 30 * 86_400
    /// Corrections smaller than this are not applied, °C.
    static let negligibleC = 0.05

    public private(set) var places: [String: PlaceRecord] = [:]

    public init() {}

    /// The solar hour (0...23) of `tS` at longitude `lon` (mean solar time).
    public static func solarHour(_ tS: Int64, lon: Double) -> Int {
        let offset = Int64((lon / 15.0 * 3600.0).rounded())
        let secondsOfDay = ((tS + offset) % 86_400 + 86_400) % 86_400
        return Int(secondsOfDay / 3600)
    }

    /// Learns one sample (observed - model) for the place at `nowS`; false when it was not
    /// taken (too soon after the last one of its bin, or an implausible error).
    @discardableResult
    public mutating func addSample(
        placeKey: String, lon: Double, modelTempC: Double, observedTempC: Double, nowS: Int64
    ) -> Bool {
        let error = observedTempC - modelTempC
        guard error.isFinite, abs(error) <= Self.maxSampleErrorC, lon.isFinite else { return false }
        var r = places[placeKey] ?? PlaceRecord()
        let h = Self.solarHour(nowS, lon: lon)
        guard nowS - r.lastSampleS[h] >= Self.minSpacingS else { return false }
        let a = max(Self.alpha, 1.0 / Double(r.counts[h] + 1))
        r.biasC[h] += a * (error - r.biasC[h])
        r.counts[h] += 1
        r.lastSampleS[h] = nowS
        r.lastUpdateS = nowS
        places[placeKey] = r
        return true
    }

    /// The correction (°C, to add to the model temperature) at `tS` for the place, 0 until
    /// enough samples are learned.
    public func correctionC(placeKey: String, lon: Double, at tS: Int64, nowS: Int64) -> Double {
        guard let r = places[placeKey] else { return 0 }
        let h = Self.solarHour(tS, lon: lon)
        // [1, 2, 1] smoothing over the learned neighbouring hours; nEff counts the samples
        // with the same weights (a neighbour's sample is half as informative)
        var sum = 0.0, weight = 0.0, nEff = 0.0
        for (dh, w) in [(-1, 0.5), (0, 1.0), (1, 0.5)] {
            let k = (h + dh + 24) % 24
            guard r.counts[k] > 0 else { continue }
            sum += w * r.biasC[k]
            weight += w
            nEff += w * Double(r.counts[k])
        }
        guard weight > 0, nEff >= Double(Self.minSamples) else { return 0 }
        let confidence = min(1.0, nEff / Double(Self.fullConfidenceSamples)) * Self.strength(r, nowS: nowS)
        let c = confidence * sum / weight
        return max(-Self.maxCorrectionC, min(Self.maxCorrectionC, c))
    }

    /// 1 while the record is fresh; then the stale fade, exp(-(idle - staleAfterS) / staleAfterS).
    static func strength(_ r: PlaceRecord, nowS: Int64) -> Double {
        let idle = nowS - r.lastUpdateS
        guard idle > Self.staleAfterS else { return 1.0 }
        return exp(-Double(idle - Self.staleAfterS) / Double(Self.staleAfterS))
    }

    // MARK: - Display

    /// What has been learned for one place.
    public struct Summary: Sendable, Equatable {
        /// Samples learned, all hours together.
        public let samples: Int
        /// Solar hours with at least one sample (of 24).
        public let hoursLearned: Int
        /// The newest sample, UTC unix seconds.
        public let lastUpdateS: Int64
        /// 1 while fresh, below 1 once the record fades (no sample for more than `staleAfterS`).
        public let strength: Double
    }

    /// The place's summary, nil when nothing is learned.
    public func summary(placeKey: String, nowS: Int64) -> Summary? {
        guard let r = places[placeKey] else { return nil }
        return Summary(
            samples: r.counts.reduce(0, +), hoursLearned: r.counts.filter { $0 > 0 }.count,
            lastUpdateS: r.lastUpdateS, strength: Self.strength(r, nowS: nowS))
    }

    /// The samples learned for the solar hour of `tS` (the bin its correction mostly comes from).
    public func samples(placeKey: String, lon: Double, at tS: Int64) -> Int {
        places[placeKey]?.counts[Self.solarHour(tS, lon: lon)] ?? 0
    }

    /// The forecast with every hour's temperature and apparent temperature shifted by the
    /// learned correction of its solar hour, and the days rebuilt from the shifted hours; the
    /// forecast itself when nothing is learned yet.
    public func corrected(_ forecast: WxForecast, placeKey: String, nowS: Int64) -> WxForecast {
        guard places[placeKey] != nil else { return forecast }
        let lon = forecast.place.lon
        var changed = false
        let hours = forecast.hours.map { h -> WxBlendHour in
            let c = correctionC(placeKey: placeKey, lon: lon, at: h.tS, nowS: nowS)
            guard abs(c) >= Self.negligibleC else { return h }
            var out = h
            if out.tempC.isFinite {
                out.tempC += c
                changed = true
            }
            if out.feelsC.isFinite {
                out.feelsC += c
            }
            return out
        }
        guard changed else { return forecast }
        let days = WxDaily.build(timezone: forecast.place.timezone, hours: hours, nowS: forecast.generatedS)
        return (try? WxForecast(
            place: forecast.place, generatedS: forecast.generatedS, hours: hours, quarters: forecast.quarters,
            days: days, sources: forecast.sources)) ?? forecast
    }

    /// Forgets a place.
    public mutating func remove(placeKey: String) {
        places[placeKey] = nil
    }

    /// Keeps only the given places.
    public mutating func retain(placeKeys: Set<String>) {
        places = places.filter { placeKeys.contains($0.key) }
    }

    // MARK: - Persistence

    /// The file, "<config>/weather/local-bias.json".
    public static func defaultPath(configDirectory: String) -> String {
        let base = configDirectory.hasSuffix("/") ? String(configDirectory.dropLast()) : configDirectory
        return "\(base)/weather/local-bias.json"
    }

    public static func load(path: String) -> WxLocalBias {
        guard !path.isEmpty,
              let data = try? FileIO.readBounded(path: path, maxBytes: 4 * 1024 * 1024),
              let value = try? JSONDecoder().decode(WxLocalBias.self, from: data)
        else {
            return WxLocalBias()
        }
        return value
    }

    public func save(path: String) {
        guard !path.isEmpty, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileIO.writeAtomic(path: path, data: data)
    }
}
