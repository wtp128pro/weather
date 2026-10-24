// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WxRain.swift - the rain headline state and the next-rain-period summary.
// Port of WxRainState and WxRainOutlook (src/core/wx-types.h:774-790).

/// State of the rain headline (WxRainState). `rawValue` is the C ordinal.
public enum WxRainState: Int, CaseIterable, Sendable {
    case dry = 0
    case now = 1
    case expected = 2
    case possible = 3
}

/// Summary of the next rain period (WxRainOutlook). A plain record: the
/// blend fills every field.
public struct WxRainOutlook: Equatable, Hashable, Sendable {
    public var state: WxRainState
    public var startS: Int64
    /// 0 if unknown / beyond the horizon.
    public var endS: Int64
    public var peakS: Int64
    public var peakMmH: Double
    public var peakProb: Double
    public var endsKnown: Bool

    /// Memberwise initialiser; the defaults are the zero-filled C struct.
    public init(
        state: WxRainState = .dry, startS: Int64 = 0, endS: Int64 = 0, peakS: Int64 = 0,
        peakMmH: Double = 0, peakProb: Double = 0, endsKnown: Bool = false
    ) {
        self.state = state
        self.startS = startS
        self.endS = endS
        self.peakS = peakS
        self.peakMmH = peakMmH
        self.peakProb = peakProb
        self.endsKnown = endsKnown
    }
}
