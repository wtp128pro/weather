// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FormatCompassTests.swift - WxFormat.compassPoint / compassBearing: the 16
// centres both ways, the ±11.25 degree sector boundaries, wrap-around of
// negative and >= 360 bearings, non-finite input and invalid tokens.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct FormatCompassTests {
    /// The 16 points with their centre bearings, written out independently
    /// of WxFormat.compassPoints.
    static let centres: [(String, Double)] = [
        ("N", 0), ("NNE", 22.5), ("NE", 45), ("ENE", 67.5),
        ("E", 90), ("ESE", 112.5), ("SE", 135), ("SSE", 157.5),
        ("S", 180), ("SSW", 202.5), ("SW", 225), ("WSW", 247.5),
        ("W", 270), ("WNW", 292.5), ("NW", 315), ("NNW", 337.5),
    ]

    @Test func centresMapToTheirNames() {
        for (name, deg) in Self.centres {
            #expect(WxFormat.compassPoint(deg) == name, "\(deg)")
        }
    }

    @Test func namesMapToTheirCentres() {
        for (name, deg) in Self.centres {
            #expect(WxFormat.compassBearing(name) == deg, "\(name)")
        }
    }

    @Test func sectorBoundaries() {
        for (i, (name, deg)) in Self.centres.enumerated() {
            let next = Self.centres[(i + 1) % Self.centres.count].0
            // The lower boundary belongs to this sector, the upper to the next.
            #expect(WxFormat.compassPoint(deg - 11.25) == name, "\(deg) - 11.25")
            #expect(WxFormat.compassPoint(deg + 11.24) == name, "\(deg) + 11.24")
            #expect(WxFormat.compassPoint(deg + 11.25) == next, "\(deg) + 11.25")
        }
        #expect(WxFormat.compassPoint(31) == "NNE")
        #expect(WxFormat.compassPoint(33.75) == "NE")
        #expect(WxFormat.compassPoint(348.74) == "NNW")
        #expect(WxFormat.compassPoint(348.75) == "N")
        #expect(WxFormat.compassPoint(359.99) == "N")
        #expect(WxFormat.compassPoint(11.24) == "N")
        #expect(WxFormat.compassPoint(11.25) == "NNE")
    }

    @Test func wrapAround() {
        #expect(WxFormat.compassPoint(360) == "N")
        #expect(WxFormat.compassPoint(720) == "N")
        #expect(WxFormat.compassPoint(725) == "N")
        #expect(WxFormat.compassPoint(450) == "E")
        #expect(WxFormat.compassPoint(-0.0) == "N")
        #expect(WxFormat.compassPoint(-1e-12) == "N")
        #expect(WxFormat.compassPoint(-11.25) == "N")
        #expect(WxFormat.compassPoint(-11.26) == "NNW")
        #expect(WxFormat.compassPoint(-90) == "W")
        #expect(WxFormat.compassPoint(-270) == "E")
        #expect(WxFormat.compassPoint(-360) == "N")
        #expect(WxFormat.compassPoint(-1000) == "E")
        #expect(WxFormat.compassPoint(3.6e11 + 180) == "S")
    }

    @Test func nonFiniteBearingsAreNil() {
        #expect(WxFormat.compassPoint(.nan) == nil)
        #expect(WxFormat.compassPoint(.infinity) == nil)
        #expect(WxFormat.compassPoint(-.infinity) == nil)
    }

    @Test func namesAreCaseInsensitiveAndTrimmed() {
        #expect(WxFormat.compassBearing("nne") == 22.5)
        #expect(WxFormat.compassBearing("Wsw") == 247.5)
        #expect(WxFormat.compassBearing("  s ") == 180)
        #expect(WxFormat.compassBearing("\tNW\n") == 315)
    }

    @Test func invalidTokensAreNil() {
        for token in ["CALM", "VRB", "", "   ", "NORTH", "C", "NNNE", "N E", "X", "0", "nnw?"] {
            #expect(WxFormat.compassBearing(token) == nil, "\(token)")
        }
    }

    @Test func roundTrip() {
        for (name, _) in Self.centres {
            let deg = WxFormat.compassBearing(name)
            #expect(deg.flatMap(WxFormat.compassPoint) == name, "\(name)")
        }
    }
}
