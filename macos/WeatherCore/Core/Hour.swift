// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Hour.swift - one hourly bucket and one 15-minute precipitation entry of a
// member. Port of WxHour, WxQuarter and wx_hour_init
// (src/core/wx-types.h:310-342, src/core/wx-types.c:30-158,408-446).
//
// The range rules shared by members and forecasts live here as internal
// statics of WxHour/WxQuarter: "drop, never clamp" (a value outside its
// inclusive range, or not finite, becomes NaN) and the half-open time range
// [WxLimits.timeMinS, WxLimits.timeMaxS).

/// One hourly bucket [tS, tS + 3600) of one member (WxHour). A plain record;
/// `WxMember.addHour(_:)` validates and normalises it.
public struct WxHour: Equatable, Hashable, Sendable {
    /// Bucket start, UTC unix seconds, multiple of 3600.
    public var tS: Int64
    /// Air temperature, degC.
    public var tempC: Double
    /// Apparent temperature, degC.
    public var feelsC: Double
    /// Precipitation over the hour, mm.
    public var precipMm: Double
    /// Probability of precipitation, 0..100.
    public var precipProb: Double
    /// Cloud cover, 0..100.
    public var cloudPct: Double
    /// 10 m wind speed, km/h.
    public var windKmh: Double
    /// Wind gust, km/h.
    public var gustKmh: Double
    /// Relative humidity, 0..100.
    public var humidityPct: Double
    /// WMO weather code 0..99, -1 unknown (a C int).
    public var wmo: Int

    /// The "all unknown" hour (wx_hour_init, src/core/wx-types.c:414-427):
    /// tS 0, every number NaN, wmo -1. Every argument defaults to that value.
    public init(
        tS: Int64 = 0, tempC: Double = .nan, feelsC: Double = .nan, precipMm: Double = .nan,
        precipProb: Double = .nan, cloudPct: Double = .nan, windKmh: Double = .nan,
        gustKmh: Double = .nan, humidityPct: Double = .nan, wmo: Int = -1
    ) {
        self.tS = tS
        self.tempC = tempC
        self.feelsC = feelsC
        self.precipMm = precipMm
        self.precipProb = precipProb
        self.cloudPct = cloudPct
        self.windKmh = windKmh
        self.gustKmh = gustKmh
        self.humidityPct = humidityPct
        self.wmo = wmo
    }

    /// `v` when `WxLimits.valueInRange(v, lo, hi)`, else NaN (norm,
    /// src/core/wx-types.c:69-73: the "drop, never clamp" rule).
    static func norm(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        WxLimits.valueInRange(v, lo, hi) ? v : .nan
    }

    /// norm_temp (src/core/wx-types.c:86-90): [tempMinC, tempMaxC].
    static func normTemp(_ v: Double) -> Double {
        norm(v, WxLimits.tempMinC, WxLimits.tempMaxC)
    }

    /// norm_percent (src/core/wx-types.c:103-107): [0, 100].
    static func normPercent(_ v: Double) -> Double {
        norm(v, WxLimits.percentMin, WxLimits.percentMax)
    }

    /// norm_wind (src/core/wx-types.c:120-124): [0, windMaxKmh].
    static func normWind(_ v: Double) -> Double {
        norm(v, 0.0, WxLimits.windMaxKmh)
    }

    /// norm_precip (src/core/wx-types.c:137-141): [0, precipMaxMmH].
    static func normPrecip(_ v: Double) -> Double {
        norm(v, 0.0, WxLimits.precipMaxMmH)
    }

    /// time_in_range (src/core/wx-types.c:154-158): timeMinS <= t < timeMaxS.
    static func timeInRange(_ t: Int64) -> Bool {
        t >= WxLimits.timeMinS && t < WxLimits.timeMaxS
    }

    /// The stored form of this hour (wx_member_add_hour's normalisation,
    /// src/core/wx-types.c:519-528): out-of-range or non-finite numbers
    /// become NaN, wmo outside 0...99 becomes -1; tS is kept.
    var normalised: WxHour {
        WxHour(
            tS: tS, tempC: Self.normTemp(tempC), feelsC: Self.normTemp(feelsC),
            precipMm: Self.normPrecip(precipMm), precipProb: Self.normPercent(precipProb),
            cloudPct: Self.normPercent(cloudPct), windKmh: Self.normWind(windKmh),
            gustKmh: Self.normWind(gustKmh), humidityPct: Self.normPercent(humidityPct),
            wmo: (wmo >= 0 && wmo <= 99) ? wmo : -1)
    }
}

/// Precipitation amount over [tS, tS + 900) (WxQuarter).
public struct WxQuarter: Equatable, Hashable, Sendable {
    /// Start, UTC unix seconds, multiple of 900.
    public var tS: Int64
    /// Amount over the 15 minutes, mm.
    public var precipMm: Double

    public init(tS: Int64, precipMm: Double) {
        self.tS = tS
        self.precipMm = precipMm
    }

    /// quarter_ok (src/core/wx-types.c:441-446): tS a multiple of 900 within
    /// the time range and precipMm finite within [0, precipMaxMmH].
    var isValid: Bool {
        WxHour.timeInRange(tS) && tS % 900 == 0
            && WxLimits.valueInRange(precipMm, 0.0, WxLimits.precipMaxMmH)
    }
}
