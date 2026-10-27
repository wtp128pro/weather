// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U40AuditFixTests.swift - regression tests for the verified audit findings
// of slices P15 (core model types) and P16 (formatting):
//   U15-F1  WxPlace.withCustomLocation clear path stored the customised
//           street as both name and admin1 ("Oslo, Oslo, Norway").
//   U16-F1  WxConditionSymbol.effectiveHourlyCondition / effectiveDailyCondition
//           had no test pinning any of their icon-override gates.
// The place cases replay the location-name sheet: its street field is
// prefilled with the stored street address (or the name of a region-less
// place), and Clear Name sends an empty custom name with that street through
// AppModel.renamePlace, which passes a nil custom name.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct U40AuditFixTests {
    // MARK: - U15-F1: clearing a custom name must not duplicate the region

    /// Region-less place (Oslo, Norway): Save "Home" with the prefilled
    /// street "Oslo", then Clear Name. Before the fix admin1 kept the "Oslo"
    /// written by the customisation: "Oslo, Oslo, Norway" / "Oslo, Norway".
    @Test func clearingCustomNameOnRegionlessPlaceRestoresLabel() throws {
        let oslo = try WxPlace(
            name: "Oslo", country: "Norway", countryCode: "NO",
            lat: 59.9133, lon: 10.7389, timezone: "Europe/Oslo"
        )
        #expect(oslo.label == "Oslo, Norway")
        #expect(oslo.displayAddressSubtitle == "Norway")

        let home = try oslo.withCustomLocation(customName: "Home", streetAddress: oslo.name)
        #expect(home.name == "Home")
        #expect(home.admin1 == "Oslo")
        #expect(home.streetAddress == "Oslo")

        // Clear Name re-sends the prefilled stored street.
        let cleared = try home.withCustomLocation(customName: nil, streetAddress: home.streetAddress)
        #expect(cleared.customName.isEmpty)
        #expect(cleared.name == "Oslo")
        #expect(cleared.admin1 == "")
        #expect(cleared.label == "Oslo, Norway")
        #expect(cleared.label != "Oslo, Oslo, Norway")
        #expect(cleared.displayAddressSubtitle == "Norway")

        // An API caller passing no street falls back to the stored copy.
        let clearedAPI = try home.withCustomLocation(customName: nil)
        #expect(clearedAPI.label == "Oslo, Norway")
    }

    /// Region-bearing place (Miami, Florida) customised with a typed street
    /// that has no comma: before the fix the clear stored
    /// "123 Main St, 123 Main St, United States".
    @Test func clearingCustomNameWithCommalessStreetRestoresLabel() throws {
        let miami = try WxPlace(
            name: "Miami", admin1: "Florida", country: "United States", countryCode: "US",
            lat: 25.7743, lon: -80.1937, timezone: "America/New_York"
        )
        let home = try miami.withCustomLocation(customName: "Home", streetAddress: "123 Main St")
        #expect(home.admin1 == "123 Main St")

        let cleared = try home.withCustomLocation(customName: nil, streetAddress: home.streetAddress)
        #expect(cleared.name == "123 Main St")
        #expect(cleared.admin1 == "")
        #expect(cleared.label == "123 Main St, United States")
        #expect(cleared.label != "123 Main St, 123 Main St, United States")
        #expect(cleared.displayAddressSubtitle == "United States")
    }

    /// Control: a street with a comma takes the split branch, which the fix
    /// does not touch (the sheet's default prefill for a region-bearing place).
    @Test func clearingCustomNameWithCommaStreetKeepsRegion() throws {
        let miami = try WxPlace(
            name: "Miami", admin1: "Florida", country: "United States", countryCode: "US",
            lat: 25.7743, lon: -80.1937, timezone: "America/New_York"
        )
        let home = try miami.withCustomLocation(customName: "Home", streetAddress: "Miami, Florida")
        let cleared = try home.withCustomLocation(customName: nil, streetAddress: home.streetAddress)
        #expect(cleared.name == "Miami")
        #expect(cleared.admin1 == "Florida")
        #expect(cleared.label == "Miami, Florida, United States")
    }

    // MARK: - U16-F1: effectiveHourlyCondition gates

    static func hour(
        _ condition: WxCondition, tempC: Double = 10, precipMm: Double = 0,
        precipMmMax: Double = 0, precipProb: Double = 0, cloudPct: Double = 100
    ) -> WxBlendHour {
        WxBlendHour(
            tS: 1_781_474_400, tempC: tempC, precipMm: precipMm, precipMmMax: precipMmMax,
            precipProb: precipProb, cloudPct: cloudPct, condition: condition, isDay: true
        )
    }

    static func hourly(_ h: WxBlendHour) -> WxCondition {
        WxConditionSymbol.effectiveHourlyCondition(for: h)
    }

    /// Wet hours: snow at <= 0.5 degC, sleet at <= 1.8 degC (snow tested first),
    /// showers become rain at >= 2.5 mm; other classes pass through.
    @Test func hourlyWetHourTemperatureAndShowerGates() {
        #expect(Self.hourly(Self.hour(.lightRain, tempC: 0.5)) == .snow)
        #expect(Self.hourly(Self.hour(.heavyRain, tempC: -3)) == .snow)
        #expect(Self.hourly(Self.hour(.drizzle, tempC: 0.6)) == .sleet)
        #expect(Self.hourly(Self.hour(.rain, tempC: 1.8)) == .sleet)
        #expect(Self.hourly(Self.hour(.rain, tempC: 1.9)) == .rain)
        #expect(Self.hourly(Self.hour(.lightRain, tempC: .nan)) == .lightRain)
        #expect(Self.hourly(Self.hour(.showers, precipMm: 2.5)) == .rain)
        #expect(Self.hourly(Self.hour(.showers, precipMm: 2.4)) == .showers)
        #expect(Self.hourly(Self.hour(.showers, tempC: 0, precipMm: 2.5)) == .snow)
        #expect(Self.hourly(Self.hour(.thunderstorm, tempC: -5, precipMm: 5)) == .thunderstorm)
        #expect(Self.hourly(Self.hour(.fog, precipMm: 1, precipProb: 90)) == .fog)
        // Only showers turn rain at >= 2.5 mm: a warm heavy-rain hour stays heavy rain (U40
        // verifier handoff: the `base == .showers` condition).
        #expect(Self.hourly(Self.hour(.heavyRain, precipMm: 5)) == .heavyRain)
    }

    /// Dry-sky hours: overridden only from 30% with model precipitation
    /// (precipMm >= 0.05 or precipMmMax >= 0.1), or from 40% on probability alone.
    @Test func hourlyDrySkyProbabilityGates() {
        #expect(Self.hourly(Self.hour(.overcast, precipMm: 1, precipProb: 29.9)) == .overcast)
        #expect(Self.hourly(Self.hour(.overcast, precipMm: 0.05, precipProb: 30)) == .drizzle)
        #expect(Self.hourly(Self.hour(.overcast, precipMm: 0.04, precipMmMax: 0.09, precipProb: 30)) == .overcast)
        #expect(Self.hourly(Self.hour(.overcast, precipMmMax: 0.1, precipProb: 30)) == .drizzle)
        #expect(Self.hourly(Self.hour(.overcast, precipProb: 39.9)) == .overcast)
        #expect(Self.hourly(Self.hour(.overcast, precipProb: 40)) == .drizzle)
        #expect(Self.hourly(Self.hour(.mostlyCloudy, precipProb: 45)) == .drizzle)
        #expect(Self.hourly(Self.hour(.mostlyClear, precipProb: 45)) == .drizzle)  // a dry sky too
        #expect(Self.hourly(Self.hour(.overcast, precipProb: .nan)) == .overcast)
        // Rate is max(precipMm, precipMmMax / 2, 0.3) through the rain-class rule.
        #expect(Self.hourly(Self.hour(.overcast, precipMm: 1.0, precipProb: 50)) == .lightRain)
        #expect(Self.hourly(Self.hour(.overcast, precipMmMax: 6, precipProb: 50)) == .rain)
        // Half the maximum, not all of it: 4 mm max reads 2 mm/h (light rain), not 4 (rain).
        #expect(Self.hourly(Self.hour(.overcast, precipMmMax: 4, precipProb: 50)) == .lightRain)
        #expect(Self.hourly(Self.hour(.partlyCloudy, precipMm: 1.0, precipProb: 50, cloudPct: 40)) == .showers)
        #expect(Self.hourly(Self.hour(.clear, tempC: 0.5, precipProb: 60)) == .snow)
        #expect(Self.hourly(Self.hour(.clear, tempC: 1.8, precipProb: 60)) == .sleet)
    }

    // MARK: - U16-F1: effectiveDailyCondition gates

    static let oslo = WxFormat.Zone(timezone: "Europe/Oslo")
    /// Local midnights in Europe/Oslo (UTC unix seconds): a 24 h summer day,
    /// the 23 h spring-forward day and the 25 h fall-back day of 2026.
    static let june15: Int64 = 1_781_474_400
    static let march29: Int64 = 1_774_738_800
    static let october25: Int64 = 1_792_879_200

    static func daily(
        _ d: WxDay, hours: [WxBlendHour] = [], quarters: [WxQuarter] = []
    ) -> WxCondition {
        WxConditionSymbol.effectiveDailyCondition(for: d, hours: hours, quarters: quarters, zone: oslo)
    }

    static func wetHour(_ tS: Int64) -> WxBlendHour {
        WxBlendHour(tS: tS, tempC: 10, precipMm: 3, precipMmMax: 3, precipProb: 80,
                    cloudPct: 100, condition: .rain, isDay: true)
    }

    /// Wet days turn snow at max <= 1.0 degC, sleet at min <= 0 with max <= 2.5.
    @Test func dailyWetDayTemperatureGates() {
        #expect(Self.daily(WxDay(startS: Self.june15, tempMaxC: 1.0, tempMinC: -2, condition: .rain)) == .snow)
        #expect(Self.daily(WxDay(startS: Self.june15, tempMaxC: 2.5, tempMinC: 0, condition: .lightRain)) == .sleet)
        #expect(Self.daily(WxDay(startS: Self.june15, tempMaxC: 2.6, tempMinC: 0, condition: .rain)) == .rain)
        #expect(Self.daily(WxDay(startS: Self.june15, tempMaxC: 2.5, tempMinC: 0.1, condition: .rain)) == .rain)
        // Heavy rain is a wet day too (U40 verifier handoff).
        #expect(Self.daily(WxDay(startS: Self.june15, tempMaxC: 1.0, tempMinC: -2, condition: .heavyRain)) == .snow)
    }

    /// The wettest hour of the local day wins over a drier day condition;
    /// hours outside [day start, local day end) are ignored.
    @Test func dailyHourlyOverrideUsesLocalDayWindow() {
        let dry = WxDay(startS: Self.june15, tempMaxC: 20, tempMinC: 10, condition: .partlyCloudy)
        #expect(Self.daily(dry, hours: [Self.wetHour(Self.june15 + 12 * 3600)]) == .rain)
        #expect(Self.daily(dry, hours: [Self.wetHour(Self.june15)]) == .rain)  // the start is inside
        #expect(Self.daily(dry, hours: [Self.wetHour(Self.june15 - 3600)]) == .partlyCloudy)
        #expect(Self.daily(dry, hours: [Self.wetHour(Self.june15 + 24 * 3600)]) == .partlyCloudy)
        let drizzleDay = WxDay(startS: Self.june15, tempMaxC: 20, tempMinC: 10, condition: .drizzle)
        let snowHour = WxBlendHour(tS: Self.june15 + 3600, tempC: 0, precipMm: 1, condition: .lightRain)
        #expect(Self.daily(drizzleDay, hours: [Self.wetHour(Self.june15 + 3600), snowHour]) == .snow)
        let stormDay = WxDay(startS: Self.june15, tempMaxC: 20, tempMinC: 10, condition: .thunderstorm)
        #expect(Self.daily(stormDay, hours: [Self.wetHour(Self.june15 + 3600)]) == .thunderstorm)
    }

    /// DST days: the window ends at the next local midnight, not at start + 24 h.
    @Test func dailyHourlyWindowFollowsDSTDayLength() {
        // Spring forward: 23 h day, so start + 23 h is already the next day.
        let spring = WxDay(startS: Self.march29, tempMaxC: 10, tempMinC: 2, condition: .overcast)
        #expect(Self.daily(spring, hours: [Self.wetHour(Self.march29 + 22 * 3600)]) == .rain)
        #expect(Self.daily(spring, hours: [Self.wetHour(Self.march29 + 23 * 3600)]) == .overcast)
        // Fall back: 25 h day, so start + 24 h is still 23:00 on the same day.
        let fall = WxDay(startS: Self.october25, tempMaxC: 10, tempMinC: 2, condition: .overcast)
        #expect(Self.daily(fall, hours: [Self.wetHour(Self.october25 + 24 * 3600)]) == .rain)
        #expect(Self.daily(fall, hours: [Self.wetHour(Self.october25 + 25 * 3600)]) == .overcast)
    }

    /// A dry day with a nowcast quarter of >= 0.1 mm inside the day shows rain
    /// (snow at max <= 1.0 degC).
    @Test func dailyNowcastQuarterOverride() {
        let dry = WxDay(startS: Self.june15, tempMaxC: 20, tempMinC: 10, condition: .mostlyCloudy)
        #expect(Self.daily(dry, quarters: [WxQuarter(tS: Self.june15 + 900, precipMm: 0.1)]) == .rain)
        #expect(Self.daily(dry, quarters: [WxQuarter(tS: Self.june15 + 900, precipMm: 0.09)]) == .mostlyCloudy)
        #expect(Self.daily(dry, quarters: [WxQuarter(tS: Self.june15 - 900, precipMm: 5)]) == .mostlyCloudy)
        let cold = WxDay(startS: Self.june15, tempMaxC: 1.0, tempMinC: -3, condition: .overcast)
        #expect(Self.daily(cold, quarters: [WxQuarter(tS: Self.june15 + 900, precipMm: 0.5)]) == .snow)
        // The window is [day start, local day end) for quarters too, and a day that already
        // shows precipitation keeps it (U40 verifier handoff).
        #expect(Self.daily(dry, quarters: [WxQuarter(tS: Self.june15, precipMm: 0.5)]) == .rain)
        #expect(Self.daily(dry, quarters: [WxQuarter(tS: Self.june15 + 86_400, precipMm: 5)]) == .mostlyCloudy)
        let snowDay = WxDay(startS: Self.june15, tempMaxC: 10, tempMinC: 5, condition: .snow)
        #expect(Self.daily(snowDay, quarters: [WxQuarter(tS: Self.june15 + 900, precipMm: 0.5)]) == .snow)
    }

    /// Daily probability: from 30% with >= 0.1 mm, or from 35% on probability
    /// alone; the class follows the temperature gates, then the rain-class rule
    /// at max(precipMm / 4, 0.6) mm/h.
    @Test func dailyProbabilityGates() {
        func day(_ prob: Double, _ mm: Double, hi: Double = 15, lo: Double = 8) -> WxDay {
            WxDay(startS: Self.june15, tempMaxC: hi, tempMinC: lo, precipMm: mm,
                  precipProbMax: prob, cloudPct: 100, condition: .overcast)
        }
        #expect(Self.daily(day(29.9, 5)) == .overcast)
        #expect(Self.daily(day(30, 0.1)) == .lightRain)
        #expect(Self.daily(day(32, 0.09)) == .overcast)
        #expect(Self.daily(day(34.9, 0)) == .overcast)
        #expect(Self.daily(day(35, 0)) == .lightRain)
        #expect(Self.daily(day(60, 12)) == .rain)
        #expect(Self.daily(day(60, 2, hi: 1.0, lo: -4)) == .snow)
        #expect(Self.daily(day(60, 2, hi: 2.5, lo: 0)) == .sleet)
        #expect(Self.daily(day(.nan, 5)) == .overcast)
        // The rate is a quarter of the day's total: 8 mm reads 2 mm/h (light rain), not 4 (rain);
        // and a day that already shows precipitation keeps it (U40 verifier handoff).
        #expect(Self.daily(day(60, 8)) == .lightRain)
        #expect(Self.daily(WxDay(startS: Self.june15, tempMaxC: 10, tempMinC: 5, precipMm: 5, precipProbMax: 60,
                                 cloudPct: 100, condition: .snow)) == .snow)
    }
}
