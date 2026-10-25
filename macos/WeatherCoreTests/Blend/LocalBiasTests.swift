// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// LocalBiasTests.swift - the learned local temperature bias (LocalBias.swift):
// solar-hour bins, the sample gate, confidence, the cap, the stale fade, and the
// corrected forecast (hours shifted, days rebuilt).

import Foundation
import Testing
@testable import WeatherCore

@Suite struct LocalBiasTests {
    /// 2026-01-15T00:00Z.
    static let t0: Int64 = 1_768_435_200

    @Test func solarHourFollowsLongitude() {
        #expect(WxLocalBias.solarHour(Self.t0, lon: 0) == 0)
        #expect(WxLocalBias.solarHour(Self.t0, lon: 90) == 6)
        #expect(WxLocalBias.solarHour(Self.t0, lon: -80.2) == 18)  // Miami: 5 h 21 min behind
        #expect(WxLocalBias.solarHour(Self.t0 + 3599, lon: 0) == 0)
        #expect(WxLocalBias.solarHour(Self.t0 - 1, lon: 0) == 23)
    }

    @Test func nothingIsAppliedUntilEnoughSamples() {
        var b = WxLocalBias()
        let took1 = b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 8, nowS: Self.t0)
        #expect(took1)
        let took2 = b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 8, nowS: Self.t0 + 600)
        #expect(!took2)  // too soon
        #expect(b.correctionC(placeKey: "p", lon: 0, at: Self.t0, nowS: Self.t0) == 0)  // 1 sample
        // more nights at the same solar hour
        b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 8, nowS: Self.t0 + 86_400)
        b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 8, nowS: Self.t0 + 2 * 86_400)
        let three = b.correctionC(placeKey: "p", lon: 0, at: Self.t0, nowS: Self.t0 + 2 * 86_400)
        #expect(abs(three - (-1.0)) < 1e-9)  // 3 samples: half confidence of the -2 °C error
        for d in 3..<6 {
            b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 8, nowS: Self.t0 + Int64(d) * 86_400)
        }
        let six = b.correctionC(placeKey: "p", lon: 0, at: Self.t0 + 1800, nowS: Self.t0 + 5 * 86_400)
        #expect(abs(six - (-2.0)) < 1e-9)
        // the same hour of another day gets it; an hour far away does not
        #expect(abs(b.correctionC(placeKey: "p", lon: 0, at: Self.t0 + 9 * 86_400, nowS: Self.t0 + 5 * 86_400) + 2) < 1e-9)
        #expect(b.correctionC(placeKey: "p", lon: 0, at: Self.t0 + 12 * 3600, nowS: Self.t0 + 5 * 86_400) == 0)
        // the neighbouring hour shares it through the [1, 2, 1] smoothing (half the samples)
        let next = b.correctionC(placeKey: "p", lon: 0, at: Self.t0 + 3600, nowS: Self.t0 + 5 * 86_400)
        #expect(abs(next - (-2.0 * 0.5)) < 1e-9)
        #expect(b.correctionC(placeKey: "other", lon: 0, at: Self.t0, nowS: Self.t0) == 0)
    }

    @Test func implausibleSamplesAreNotLearnedAndCorrectionsAreCapped() {
        var b = WxLocalBias()
        let took3 = b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 25, nowS: Self.t0)
        #expect(!took3)
        let took4 = b.addSample(placeKey: "p", lon: 0, modelTempC: .nan, observedTempC: 8, nowS: Self.t0)
        #expect(!took4)
        #expect(b.places.isEmpty)
        for d in 0..<8 {
            b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 2, nowS: Self.t0 + Int64(d) * 86_400)
        }
        #expect(b.correctionC(placeKey: "p", lon: 0, at: Self.t0, nowS: Self.t0 + 7 * 86_400) == -WxLocalBias.maxCorrectionC)
    }

    @Test func staleRecordsFadeUntilNewSamples() {
        var b = WxLocalBias()
        for d in 0..<8 {
            b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 8, nowS: Self.t0 + Int64(d) * 86_400)
        }
        let last = Self.t0 + 7 * 86_400
        #expect(abs(b.correctionC(placeKey: "p", lon: 0, at: Self.t0, nowS: last + 20 * 86_400) + 2) < 1e-9)
        let faded = b.correctionC(placeKey: "p", lon: 0, at: Self.t0, nowS: last + 60 * 86_400)
        #expect(abs(faded - (-2.0 * exp(-1.0))) < 1e-9)  // a month past the stale point: e-folded once
        b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 8, nowS: last + 60 * 86_400)
        #expect(abs(b.correctionC(placeKey: "p", lon: 0, at: Self.t0, nowS: last + 60 * 86_400) + 2) < 1e-9)
    }

    static func forecast(_ place: WxPlace, startS: Int64, temps: [Double]) throws -> WxForecast {
        let hours = temps.enumerated().map { i, t -> WxBlendHour in
            var h = WxBlendHour(tS: startS + Int64(i) * 3600)
            h.tempC = t
            h.feelsC = t - 1
            h.cloudPct = 30
            h.precipMm = 0
            h.precipProb = 5
            h.nMembers = 3  // a day needs hours the models contributed to
            return h
        }
        let days = WxDaily.build(timezone: place.timezone, hours: hours, nowS: startS)
        return try WxForecast(place: place, generatedS: startS, hours: hours, days: days)
    }

    @Test func correctedForecastShiftsHoursAndRebuildsDays() throws {
        let place = try BlendFixture.place(45.0, 0.0, "UTC")
        let model = try Self.forecast(place, startS: Self.t0, temps: Array(repeating: 10, count: 48))
        var b = WxLocalBias()
        #expect(b.corrected(model, placeKey: "p", nowS: Self.t0) == model)  // nothing learned
        // the valley runs 3 °C colder than the model at 05:00 solar time
        let five = Self.t0 + 5 * 3600
        for d in 0..<8 {
            b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 7, nowS: five + Int64(d) * 86_400)
        }
        let fixed = b.corrected(model, placeKey: "p", nowS: Self.t0)
        #expect(fixed.hours.count == model.hours.count)
        #expect(fixed.hours[5].tempC == 7)
        #expect(fixed.hours[5].feelsC == 6)
        // the neighbouring hour: smoothed from half the samples (4 of the 6 for full confidence)
        #expect(abs(fixed.hours[4].tempC - (10 - 3.0 * 4.0 / 6.0)) < 1e-9)
        #expect(fixed.hours[12].tempC == 10)
        #expect(fixed.hours[29].tempC == 7)  // the next day's 05:00
        #expect(fixed.days.first?.tempMinC == 7)  // the daily low comes from the corrected hours
        #expect(fixed.days.first?.tempMaxC == 10)
        #expect(fixed.place == model.place && fixed.generatedS == model.generatedS)
    }

    @Test func summaryForDisplay() {
        var b = WxLocalBias()
        #expect(b.summary(placeKey: "p", nowS: Self.t0) == nil)
        b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 9, nowS: Self.t0 + 5 * 3600)
        for d in 0..<4 {
            b.addSample(placeKey: "p", lon: 0, modelTempC: 10, observedTempC: 9, nowS: Self.t0 + Int64(d) * 86_400)
        }
        let last = Self.t0 + 3 * 86_400
        let fresh = b.summary(placeKey: "p", nowS: last)
        #expect(fresh == WxLocalBias.Summary(samples: 5, hoursLearned: 2, lastUpdateS: last, strength: 1.0))
        #expect(b.samples(placeKey: "p", lon: 0, at: Self.t0 + 1800) == 4)
        #expect(b.samples(placeKey: "p", lon: 0, at: Self.t0 + 5 * 3600) == 1)
        #expect(b.samples(placeKey: "p", lon: 0, at: Self.t0 + 9 * 3600) == 0)
        #expect(b.samples(placeKey: "other", lon: 0, at: Self.t0) == 0)
        // a month past the stale point: e-folded once
        let faded = b.summary(placeKey: "p", nowS: last + 60 * 86_400)
        #expect(abs((faded?.strength ?? 0) - exp(-1.0)) < 1e-9)
    }

    @Test func retainAndRemove() {
        var b = WxLocalBias()
        b.addSample(placeKey: "a", lon: 0, modelTempC: 10, observedTempC: 9, nowS: Self.t0)
        b.addSample(placeKey: "b", lon: 0, modelTempC: 10, observedTempC: 9, nowS: Self.t0)
        b.retain(placeKeys: ["a"])
        #expect(b.places.keys.sorted() == ["a"])
        b.remove(placeKey: "a")
        #expect(b.places.isEmpty)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let dir = try TemporaryDirectory("local-bias")
        let path = WxLocalBias.defaultPath(configDirectory: dir.appending("config").path)
        var b = WxLocalBias()
        b.addSample(placeKey: "p", lon: 12.5, modelTempC: 10, observedTempC: 8.5, nowS: Self.t0)
        b.save(path: path)
        #expect(WxLocalBias.load(path: path) == b)
        #expect(WxLocalBias.load(path: "").places.isEmpty)
    }
}
