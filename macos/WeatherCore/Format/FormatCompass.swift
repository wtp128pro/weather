// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FormatCompass.swift - 16-point compass names for wind bearings (degrees
// the wind comes FROM): a bearing to its point name and a point name to its
// centre bearing. Swift-only; the C app has no equivalent.

import Foundation

public extension WxFormat {
    /// The 16 compass points clockwise from north; index i is centred on
    /// i * 22.5 degrees.
    static let compassPoints = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    ]

    /// The 16-point name of a bearing in degrees: any finite value is
    /// normalised into [0, 360), each sector spans ±11.25 degrees around its
    /// centre and a value on a boundary belongs to the clockwise sector
    /// (31 -> "NNE", 348.75 -> "N", 360 -> "N", -90 -> "W"); nil when the
    /// bearing is not finite.
    static func compassPoint(_ degrees: Double) -> String? {
        guard degrees.isFinite else {
            return nil
        }
        var d = degrees.truncatingRemainder(dividingBy: 360.0)
        if d < 0 {
            d += 360.0
        }
        let index = Int((d + 11.25) / 22.5) % compassPoints.count
        return compassPoints[index]
    }

    /// The centre bearing of a 16-point name ("N" -> 0, "NNE" -> 22.5 ...
    /// "NNW" -> 337.5), case-insensitive with surrounding whitespace
    /// ignored; nil for any other token ("CALM", "VRB", "", "NORTH").
    static func compassBearing(_ name: String) -> Double? {
        let token = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let index = compassPoints.firstIndex(of: token) else {
            return nil
        }
        return Double(index) * 22.5
    }
}
