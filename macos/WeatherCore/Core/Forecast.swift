// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Forecast.swift - the blended hour, the daily summary and the immutable
// final forecast of one place. Port of WxBlendHour, WxDay and WxForecast
// (src/core/wx-types.h:648-666,798-999, src/core/wx-types.c:1024-1268).
//
// C reference-counts an immutable WxForecast; here it is an immutable value
// (every stored property is a `let`), safe to share across threads. The
// initialiser keeps the C contract: everything is copied, structure errors
// throw `.invalidArg` (the cache loader feeds disk data through it), and
// out-of-range or non-finite numbers are normalised to NaN rather than
// rejected. Things C must check at run time that Swift's types already
// guarantee: a NULL array with a count, a condition outside 0...14, an
// is_day other than 0/1, an invalid place (WxPlace is always valid) and an
// invalid source status (WxSourceStatus is always valid; it is still
// re-validated and re-sanitised through `copy()` as in C).

/// One blended hour of the final forecast (WxBlendHour). A plain record;
/// `WxForecast.init` normalises it.
public struct WxBlendHour: Equatable, Hashable, Sendable {
    public var tS: Int64
    public var tempC: Double
    public var feelsC: Double
    /// Weighted median over members.
    public var precipMm: Double
    /// Maximum over members.
    public var precipMmMax: Double
    public var precipProb: Double
    public var cloudPct: Double
    public var windKmh: Double
    public var gustKmh: Double
    public var humidityPct: Double
    /// max - min across members, NaN if fewer than 2.
    public var tempSpreadC: Double
    /// A C guint8.
    public var nMembers: UInt8
    public var condition: WxCondition
    public var isDay: Bool

    /// Memberwise initialiser; every number defaults to NaN.
    public init(
        tS: Int64, tempC: Double = .nan, feelsC: Double = .nan, precipMm: Double = .nan,
        precipMmMax: Double = .nan, precipProb: Double = .nan, cloudPct: Double = .nan,
        windKmh: Double = .nan, gustKmh: Double = .nan, humidityPct: Double = .nan,
        tempSpreadC: Double = .nan, nMembers: UInt8 = 0, condition: WxCondition = .unknown,
        isDay: Bool = false
    ) {
        self.tS = tS
        self.tempC = tempC
        self.feelsC = feelsC
        self.precipMm = precipMm
        self.precipMmMax = precipMmMax
        self.precipProb = precipProb
        self.cloudPct = cloudPct
        self.windKmh = windKmh
        self.gustKmh = gustKmh
        self.humidityPct = humidityPct
        self.tempSpreadC = tempSpreadC
        self.nMembers = nMembers
        self.condition = condition
        self.isDay = isDay
    }
}

/// One day of the daily summary (WxDay).
public struct WxDay: Equatable, Hashable, Sendable {
    /// Local midnight as UTC unix seconds.
    public var startS: Int64
    public var tempMaxC: Double
    public var tempMinC: Double
    public var precipMm: Double
    public var precipProbMax: Double
    public var cloudPct: Double
    public var condition: WxCondition

    /// Memberwise initialiser; every number defaults to NaN.
    public init(
        startS: Int64, tempMaxC: Double = .nan, tempMinC: Double = .nan, precipMm: Double = .nan,
        precipProbMax: Double = .nan, cloudPct: Double = .nan, condition: WxCondition = .unknown
    ) {
        self.startS = startS
        self.tempMaxC = tempMaxC
        self.tempMinC = tempMinC
        self.precipMm = precipMm
        self.precipProbMax = precipProbMax
        self.cloudPct = cloudPct
        self.condition = condition
    }
}

/// The final blended forecast for one place (WxForecast). Immutable.
public struct WxForecast: Equatable, Hashable, Sendable {
    public let place: WxPlace
    /// UTC unix seconds the blend was produced.
    public let generatedS: Int64
    /// Ascending, multiples of 3600, at most `WxLimits.forecastMaxHours`.
    public let hours: [WxBlendHour]
    /// Blended 15-minute nowcast, ascending, may be empty.
    public let quarters: [WxQuarter]
    /// Ascending startS, at most `WxLimits.forecastMaxDays`.
    public let days: [WxDay]
    /// At most `WxLimits.forecastMaxSources`.
    public let sources: [WxSourceStatus]

    /// wx_forecast_new (src/core/wx-types.c:1079-1198).
    ///
    /// Rejected with `.invalidArg`, checked in the C order:
    /// "generation time out of range" (generatedS outside
    /// [timeMinS, timeMaxS)); "too many forecast entries" (more than
    /// 400 hours, 1536 quarters, 16 days or 16 sources); "invalid forecast
    /// hour" (tS not strictly ascending, not a multiple of 3600 or outside
    /// the time range); "invalid forecast quarter" (not strictly ascending
    /// or not `WxQuarter.isValid`); "invalid forecast day" (startS not
    /// strictly ascending or outside the time range); then any error of
    /// re-validating a source status.
    ///
    /// Normalised to NaN: hour tempC/feelsC outside [-100, 70]; precipMm and
    /// precipMmMax outside [0, 500]; precipProb, cloudPct, humidityPct
    /// outside [0, 100]; windKmh, gustKmh outside [0, 500]; tempSpreadC
    /// outside [0, 170]; day tempMaxC/tempMinC outside [-100, 70], precipMm
    /// outside [0, 12000], precipProbMax and cloudPct outside [0, 100] (and
    /// every non-finite value). Quarters, nMembers, condition and isDay are
    /// copied as given.
    public init(
        place: WxPlace, generatedS: Int64, hours: [WxBlendHour] = [],
        quarters: [WxQuarter] = [], days: [WxDay] = [], sources: [WxSourceStatus] = []
    ) throws(WxError) {
        guard WxHour.timeInRange(generatedS) else {
            throw WxError(.invalidArg, "generation time out of range")
        }
        if hours.count > WxLimits.forecastMaxHours || quarters.count > WxLimits.forecastMaxQuarters
            || days.count > WxLimits.forecastMaxDays || sources.count > WxLimits.forecastMaxSources
        {
            throw WxError(.invalidArg, "too many forecast entries")
        }
        for (i, h) in hours.enumerated()
        where !WxHour.timeInRange(h.tS) || h.tS % 3600 != 0 || (i > 0 && h.tS <= hours[i - 1].tS) {
            throw WxError(.invalidArg, "invalid forecast hour")
        }
        for (i, q) in quarters.enumerated()
        where !q.isValid || (i > 0 && q.tS <= quarters[i - 1].tS) {
            throw WxError(.invalidArg, "invalid forecast quarter")
        }
        for (i, d) in days.enumerated()
        where !WxHour.timeInRange(d.startS) || (i > 0 && d.startS <= days[i - 1].startS) {
            throw WxError(.invalidArg, "invalid forecast day")
        }
        var copiedSources: [WxSourceStatus] = []
        copiedSources.reserveCapacity(sources.count)
        for s in sources {
            copiedSources.append(try s.copy())
        }

        self.place = place
        self.generatedS = generatedS
        self.hours = hours.map { src in
            WxBlendHour(
                tS: src.tS, tempC: WxHour.normTemp(src.tempC), feelsC: WxHour.normTemp(src.feelsC),
                precipMm: WxHour.normPrecip(src.precipMm),
                precipMmMax: WxHour.normPrecip(src.precipMmMax),
                precipProb: WxHour.normPercent(src.precipProb),
                cloudPct: WxHour.normPercent(src.cloudPct), windKmh: WxHour.normWind(src.windKmh),
                gustKmh: WxHour.normWind(src.gustKmh),
                humidityPct: WxHour.normPercent(src.humidityPct),
                tempSpreadC: WxHour.norm(src.tempSpreadC, 0.0, WxLimits.tempSpreadMaxC),
                nMembers: src.nMembers, condition: src.condition, isDay: src.isDay)
        }
        self.quarters = quarters
        self.days = days.map { src in
            WxDay(
                startS: src.startS, tempMaxC: WxHour.normTemp(src.tempMaxC),
                tempMinC: WxHour.normTemp(src.tempMinC),
                precipMm: WxHour.norm(src.precipMm, 0.0, WxLimits.precipMaxMmDay),
                precipProbMax: WxHour.normPercent(src.precipProbMax),
                cloudPct: WxHour.normPercent(src.cloudPct), condition: src.condition)
        }
        self.sources = copiedSources
    }
}
