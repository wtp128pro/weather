// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// BlendNowTests.swift - the ported /blend/now/* group of src/blend/test-blend.c
// (WxBlend.now, wx_forecast_now). Part of the BlendTests suite.
//
// Not ported: the two NULL-argument criticals of /blend/now/interpolation
// (test-blend.c:2345-2346) and the NULL-hours critical of /blend/now/hostile
// (:4769-4771) are GLIB-INTERNAL; the "out untouched" sentinel checks become
// "returns nil" (Swift returns an optional instead of writing an out
// parameter); the hostile conditions WX_COND_COUNT and G_MAXINT (:4730-4731)
// are unrepresentable in the WxCondition enum and replaced by valid classes.

import Foundation
import Testing

@testable import WeatherCore

extension BlendTests {
    // C: /blend/now/interpolation (test-blend.c:2270-2360)
    @Test func nowInterpolation() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var hs = [
            F.bh(t0 + 10 * h, 10, 0.5, 30, 20, .clear, false, 3),
            F.bh(t0 + 11 * h, 20, 1.5, 60, 80, .rain, true, 4),
            F.bh(t0 + 12 * h, .nan, 2.5, 70, .nan, .overcast, true, 5),
            F.bh(t0 + 14 * h, 40, 3.5, 80, 40, .snow, true, 6),  // 13:00 is missing
        ]
        hs[0].windKmh = 10
        hs[1].windKmh = 20
        hs[0].gustKmh = 30
        hs[1].gustKmh = 40
        hs[0].humidityPct = 50
        hs[1].humidityPct = 90
        hs[0].feelsC = 5
        hs[1].feelsC = 15
        let fc = try F.makeForecast(p, hs)

        // at the start of a bucket: its own values (:2290-2293)
        var out = try #require(WxBlend.now(fc, nowS: t0 + 10 * h))
        expectNear(out.tempC, 10.0, eps: 1e-9)
        #expect(out.tS == t0 + 10 * h)
        // a quarter of the way: linear between 10:00 and 11:00 (:2294-2313)
        let now = t0 + 10 * h + 900
        out = try #require(WxBlend.now(fc, nowS: now))
        #expect(out.tS == now)
        expectNear(out.tempC, 12.5, eps: 1e-9)
        expectNear(out.feelsC, 7.5, eps: 1e-9)
        expectNear(out.windKmh, 12.5, eps: 1e-9)
        expectNear(out.gustKmh, 32.5, eps: 1e-9)
        expectNear(out.humidityPct, 60.0, eps: 1e-9)
        expectNear(out.cloudPct, 35.0, eps: 1e-9)
        expectNear(out.precipMm, 0.5, eps: 1e-9)
        expectNear(out.precipMmMax, 0.5, eps: 1e-9)
        expectNear(out.precipProb, 30.0, eps: 1e-9)
        #expect(out.nMembers == 3)
        #expect(out.condition == .mostlyClear)  // :2311
        #expect(out.condition == WxConditionRules.cloudCondition(out.cloudPct))
        #expect(out.isDay == WxGeo.sunIsUp(lat: 51.5074, lon: -0.1278, t: now))
        // one second before the end of the bucket: nearly the next value (:2314-2317)
        out = try #require(WxBlend.now(fc, nowS: t0 + 11 * h - 1))
        expectNear(out.tempC, 20.0, eps: 0.01)
        #expect(out.tempC <= 20.0)
        // a missing value on one side: the other side is used (:2318-2321)
        out = try #require(WxBlend.now(fc, nowS: t0 + 11 * h + 1800))
        expectNear(out.tempC, 20.0, eps: 1e-9)
        expectNear(out.windKmh, 20.0, eps: 1e-9)
        // 12:00 has no temperature and no contiguous next bucket (:2322-2325)
        out = try #require(WxBlend.now(fc, nowS: t0 + 12 * h + 1800))
        expectNaN(out.tempC)
        expectNaN(out.windKmh)
        // no bucket contains now (:2326-2335)
        for n in [t0 + 13 * h + 10, t0 + 9 * h + 3599, t0 + 15 * h, Int64.max, Int64.min] {
            #expect(WxBlend.now(fc, nowS: n) == nil, "now \(n)")
        }
        // the last bucket has no successor: its own values (:2336-2343)
        out = try #require(WxBlend.now(fc, nowS: t0 + 14 * h + 1800))
        expectNear(out.tempC, 40.0, eps: 1e-9)
        #expect(out.nMembers == 6)
        #expect(out.condition == .snow)
        #expect(WxBlend.now(fc, nowS: t0 + 15 * h - 1) != nil)
        #expect(WxBlend.now(fc, nowS: t0 + 15 * h) == nil)

        // an empty forecast has no current bucket (:2348-2350)
        #expect(WxBlend.now(try F.makeForecast(p, []), nowS: now) == nil)

        // only the following bucket has a value: it is used (:2352-2359)
        let pair = [F.bh(t0 + 10 * h, .nan, 0.5, 30, 20, .clear, false, 1), F.bh(t0 + 11 * h, 20, 1.5, 60, 80, .rain, true, 1)]
        out = try #require(WxBlend.now(try F.makeForecast(p, pair), nowS: t0 + 10 * h + 1800))
        expectNear(out.tempC, 20.0, eps: 1e-9)
        expectNear(out.cloudPct, 50.0, eps: 1e-9)
    }

    // C: /blend/now/condition-follows-cloud (test-blend.c:2362-2421)
    @Test func nowConditionFollowsCloud() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.miami()
        var hs = [F.bh(t0 + 10 * h, 28.9, 0.0, 10, 55, .partlyCloudy, true, 2), F.bh(t0 + 11 * h, 29.4, 0.0, 10, 70, .mostlyCloudy, true, 2)]
        let fc = try F.makeForecast(p, hs)
        var out = try #require(WxBlend.now(fc, nowS: t0 + 10 * h + 36 * 60))
        expectNear(out.cloudPct, 55.0 + 15.0 * 0.6, eps: 1e-9)  // :2375
        #expect(out.condition == .mostlyCloudy)  // :2376
        #expect(WxConditionRules.label(out.condition) == WxConditionRules.cloudLabel(out.cloudPct))  // :2377
        expectNear(out.tempC, 28.9 + 0.5 * 0.6, eps: 1e-9)  // :2378
        out = try #require(WxBlend.now(fc, nowS: t0 + 10 * h + 24 * 60))
        #expect(out.condition == .partlyCloudy)  // :2380

        // every 37th second of the hour, for sky classes of the bucket and an unknown one (:2382-2400)
        let sky: [WxCondition] = [.unknown, .clear, .mostlyClear, .partlyCloudy, .mostlyCloudy, .overcast]
        let clouds: [(Double, Double)] = [(0, 100), (100, 0), (12, 13), (37, 38), (62, 63), (87, 88), (10, .nan), (.nan, 90),
                                          (50, 50), (0, 0), (100, 100)]
        for c in sky {
            for (c0, c1) in clouds {
                hs = [F.bh(t0 + 10 * h, 20, 0.0, 10, c0, c, true, 1), F.bh(t0 + 11 * h, 20, 0.0, 10, c1, .overcast, true, 1)]
                let f = try F.makeForecast(p, hs)
                for s in stride(from: Int64(0), to: h, by: 37) + [h - 1] {
                    let o = try #require(WxBlend.now(f, nowS: t0 + 10 * h + s))
                    #expect(o.condition == WxConditionRules.cloudCondition(o.cloudPct), "\(c) \(c0) \(c1) +\(s)")
                }
            }
        }

        // a precipitation, fog or severe class of the bucket is kept (:2402-2412)
        let kept: [WxCondition] = [.fog, .drizzle, .lightRain, .rain, .heavyRain, .showers, .thunderstorm, .snow, .sleet]
        for c in kept {
            hs = [F.bh(t0 + 10 * h, 20, 1.0, 80, 20, c, true, 1), F.bh(t0 + 11 * h, 20, 0.0, 10, 90, .overcast, true, 1)]
            #expect(try #require(WxBlend.now(try F.makeForecast(p, hs), nowS: t0 + 10 * h + 1800)).condition == c)
        }

        // no cloud value at all: the bucket's class stays (:2414-2420)
        hs = [F.bh(t0 + 10 * h, 20, 0.0, 10, .nan, .overcast, true, 1), F.bh(t0 + 11 * h, 20, 0.0, 10, .nan, .clear, true, 1)]
        out = try #require(WxBlend.now(try F.makeForecast(p, hs), nowS: t0 + 10 * h + 1800))
        expectNaN(out.cloudPct)
        #expect(out.condition == .overcast)
    }

    // C: /blend/now/hostile (test-blend.c:4715-4772)
    @Test func nowHostile() {
        let t0 = Self.t0
        let nows: [Int64] = [0, -1, .min, .max, .max - 1, .min + 1, WxLimits.timeMinS, WxLimits.timeMaxS, t0]  // :4721-4722
        let ts: [Int64] = [0, 1, -1, .min, .max, .max - 10, .min + 3589, t0, t0 + 1, t0 - 1, t0 + 3599, t0 + 3600]  // :4723-4724
        var hits = 0
        for a in ts {
            for b in ts {
                let hs = [
                    F.bh(a, 10, 1.0, 50, 20, .clear, true, 1),
                    F.bh(b, 30, 2.0, 60, 40, .rain, true, 2),
                    F.bh(a, .nan, .infinity, -1, 1e300, .sleet, true, 255),
                    F.bh(b, .greatestFiniteMagnitude, .nan, .nan, -0.0, .unknown, false, 0),
                ]
                for n in nows {
                    // the hand_forecast place is all zero: latitude and longitude 0 (:4566-4576)
                    let got = WxBlend.now(hours: hs, lat: 0, lon: 0, nowS: n)
                    // a bucket contains now iff 0 <= now - t < 3600, computed without overflow (:4740-4745)
                    let want = hs.contains { x in
                        let d = Int128(n) - Int128(x.tS)
                        return d >= 0 && d < 3600
                    }
                    #expect((got != nil) == want, "t \(a) \(b) now \(n)")
                    if let got {
                        hits += 1
                        #expect(got.tS == n)
                    }
                }
            }
        }
        #expect(hits > 20)  // :4756
        // now = INT64_MAX against a bucket at INT64_MIN (:4757-4761)
        #expect(WxBlend.now(hours: [F.bh(.min, 10, 1.0, 50, 20, .clear, true, 1)], lat: 0, lon: 0, nowS: .max) == nil)
        // a following bucket whose time stamp wraps around is not "3600 s later" (:4762-4768)
        let wrap = [F.bh(.max - 10, 10, 1.0, 50, 20, .clear, true, 1), F.bh(.min + 3589, 30, 2.0, 60, 40, .rain, true, 2)]
        let o = WxBlend.now(hours: wrap, lat: 0, lon: 0, nowS: .max)
        #expect(o != nil)
        #expect(o?.tempC.isFinite == true)
    }
}
