// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// BlendTests.swift - the ported /blend/blend/* group of src/blend/test-blend.c
// (WxBlend.forecast). The /blend/now/* group is in BlendNowTests.swift, the
// determinism and fuzz groups in BlendFuzzTests.swift (all `BlendTests`).
// Expected values are the C tests' literals, cited as test-blend.c:LINE.
//
// Not ported (see the U21 debrief): /blend/blend/criticals (GLIB-INTERNAL:
// NULL place/results/statuses and a set GError are g_return_val_if_fail
// criticals with no Swift analogue); the hand-built (raw_member) inputs of
// /blend/blend/garbage-members, /blend/blend/region and /blend/blend/no-data
// that break WxMember's invariants (unrepresentable: WxMember validates and
// normalises by construction; their out-of-range numbers are ported through
// the builder, which turns them into NaN, the same "counts as missing"
// outcome), NULL results/members, and the hostile hand-built WxPlace and
// WxSourceStatus of /blend/blend/statuses-and-place (unrepresentable: both
// types are always valid).

import Foundation
import Testing

@testable import WeatherCore

// .serialized: the fuzz tests are CPU-bound for minutes at -Onone; running them one at a time keeps
// this suite from starving timing-sensitive suites that run in parallel (see the U21 debrief).
@Suite(.serialized) struct BlendTests {
    typealias F = BlendFixture
    static let t0 = BlendFixture.t0
    static let h = BlendFixture.h
    static let nowS = BlendFixture.nowS

    // C: /blend/blend/alignment (test-blend.c:992-1035)
    @Test func blendAlignment() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var v = F.Vals()
        v.temp = 15
        // hours 09:00 .. 38:00 (30 hours): the blend starts one hour before the hour containing now
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 30, v))
        let fc = try F.blend(fx, p, Self.nowS)
        try #require(fc.hours.count == 28)  // test-blend.c:1005
        #expect(fc.hours.first?.tS == t0 + 11 * h)  // :1006
        #expect(fc.hours.last?.tS == t0 + 38 * h)  // :1007
        for (i, x) in fc.hours.enumerated() {
            #expect(x.tS % h == 0)
            if i > 0 { #expect(x.tS - fc.hours[i - 1].tS == h) }
            expectNear(x.tempC, 15.0, eps: 1e-9)  // :1012
        }
        #expect(fc.generatedS == Self.nowS)  // :1014
        #expect(fc.place.timezone == "Europe/London")  // :1016 (a value copy: the C deep-copy check has no analogue)

        // the start depends only on the hour containing now (:1019-1028)
        for now in [t0 + 12 * h, t0 + 12 * h + 1, t0 + 13 * h - 1] {
            let c2 = try F.blend(fx, p, now)
            #expect(c2.hours.first?.tS == t0 + 11 * h)
            #expect(c2.generatedS == now)
        }
        let c3 = try F.blend(fx, p, t0 + 13 * h)
        #expect(c3.hours.first?.tS == t0 + 12 * h)  // :1032
        #expect(c3.hours.count == 27)  // :1033
    }

    // C: /blend/blend/leading-gap-and-cap (test-blend.c:1037-1107)
    @Test func blendLeadingGapAndCap() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var v = F.Vals()
        v.temp = 15

        // data starts at 12:00: the 11:00 bucket exists but is empty (:1044-1064)
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 12 * h, count: 10, v))
        let fc = try F.blend(fx, p, Self.nowS)
        try #require(fc.hours.count == 11)
        let b0 = fc.hours[0]
        #expect(b0.tS == t0 + 11 * h)
        for x in [b0.tempC, b0.feelsC, b0.precipMm, b0.precipMmMax, b0.precipProb, b0.cloudPct, b0.windKmh, b0.gustKmh,
                  b0.humidityPct, b0.tempSpreadC] {
            expectNaN(x)
        }
        #expect(b0.nMembers == 0)
        #expect(b0.condition == .unknown)
        expectNear(fc.hours[1].tempC, 15.0, eps: 1e-9)

        // a gap inside a member leaves empty buckets in the contiguous list (:1067-1084)
        var m = try F.newMember("open-meteo", "ecmwf")
        for i: Int64 in 12...14 { F.addHour(&m, t0 + i * h, v) }
        for i: Int64 in 17...22 { F.addHour(&m, t0 + i * h, v) }
        var f2 = F.Fx()
        try f2.add("open-meteo", m)
        let c2 = try F.blend(f2, p, Self.nowS)
        try #require(c2.hours.count == 12)  // 11:00 .. 22:00
        for i: Int64 in 11...22 {
            let has = (i >= 12 && i <= 14) || i >= 17
            let x = c2.hours[Int(i - 11)]
            #expect(x.tS == t0 + i * h)
            #expect(x.nMembers == (has ? 1 : 0))
            #expect(has ? x.tempC.isFinite : x.tempC.isNaN)
        }

        // at most WX_BLEND_MAX_HOURS buckets, counted from the first (:1086-1094)
        var f3 = F.Fx()
        try f3.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0, count: WxLimits.memberMaxHours, v))
        let c3 = try F.blend(f3, p, Self.nowS)
        #expect(c3.hours.count == WxBlend.maxHours)
        #expect(c3.hours.first?.tS == t0 + 11 * h)
        #expect(c3.hours.last?.tS == t0 + (11 + Int64(WxBlend.maxHours) - 1) * h)

        // exactly the cap, and one hour less (:1096-1106)
        var f4 = F.Fx()
        try f4.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 11 * h, count: WxBlend.maxHours, v))
        #expect(try F.blend(f4, p, Self.nowS).hours.count == WxBlend.maxHours)
        var f5 = F.Fx()
        try f5.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 11 * h, count: WxBlend.maxHours - 1, v))
        #expect(try F.blend(f5, p, Self.nowS).hours.count == WxBlend.maxHours - 1)
        // WX_BLEND_MAX_HOURS 240 (wx-blend.h:28)
        #expect(WxBlend.maxHours == 240)
    }

    // C: /blend/blend/time-edges (test-blend.c:1109-1146)
    @Test func blendTimeEdges() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var v = F.Vals()
        v.temp = 15
        // now at the very start of the supported range: no bucket before WX_TIME_MIN_S (:1115-1122)
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: WxLimits.timeMinS, count: 40, v))
        let fc = try F.blend(fx, p, WxLimits.timeMinS)
        #expect(fc.hours.first?.tS == WxLimits.timeMinS)
        #expect(fc.hours.count == 40)
        // the same one hour later: starts one hour before now (:1123-1128)
        #expect(try F.blend(fx, p, WxLimits.timeMinS + h).hours.first?.tS == WxLimits.timeMinS)
        // the end of the range: the last accepted bucket is WX_TIME_MAX_S - 3600 (:1129-1135)
        var f3 = F.Fx()
        try f3.add("open-meteo", F.member("open-meteo", "ecmwf", first: WxLimits.timeMaxS - 20 * h, count: 20, v))
        #expect(try F.blend(f3, p, WxLimits.timeMaxS - 10 * h).hours.last?.tS == WxLimits.timeMaxS - h)

        // out-of-range now is an error, not a critical (:1137-1145)
        var f4 = F.Fx()
        try f4.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0, count: 40, v))
        for now in [WxLimits.timeMinS - 1, WxLimits.timeMaxS, Int64.min, Int64.max, 0] {
            F.expectBlendFails(f4, p, now, .invalidArg)
            #expect(F.blendError(f4.results, p, now)?.message == "time is outside the supported range")  // wx-blend.c:748
        }
    }

    // C: /blend/blend/single-member (test-blend.c:1148-1188)
    @Test func blendSingleMember() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        let v = F.Vals(temp: 14.5, feels: 13.0, precip: 0.0, prob: 20.0, cloud: 50.0, wind: 12.0, gust: 25.0, hum: 77.0, wmo: 3)
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 30, v))
        let fc = try F.blend(fx, p, Self.nowS)
        for x in fc.hours {
            expectNear(x.tempC, 14.5, eps: 1e-9)
            expectNear(x.feelsC, 13.0, eps: 1e-9)
            expectNear(x.precipMm, 0.0, eps: 1e-9)
            expectNear(x.precipMmMax, 0.0, eps: 1e-9)
            expectNear(x.precipProb, 20.0, eps: 1e-9)
            expectNear(x.cloudPct, 50.0, eps: 1e-9)
            expectNear(x.windKmh, 12.0, eps: 1e-9)
            expectNear(x.gustKmh, 25.0, eps: 1e-9)
            expectNear(x.humidityPct, 77.0, eps: 1e-9)
            expectNaN(x.tempSpreadC)  // one member: no spread (:1169)
            #expect(x.nMembers == 1)
            #expect(x.condition == .partlyCloudy)  // :1171
            #expect(x.isDay == WxGeo.sunIsUp(lat: 51.5074, lon: -0.1278, t: x.tS))
        }
        // both day and night occur in a 28 hour list (:1174-1180)
        #expect(fc.hours.contains { $0.isDay } && fc.hours.contains { !$0.isDay })
        #expect(fc.quarters.isEmpty)  // :1182-1183
        #expect(!fc.days.isEmpty)  // :1184
        #expect(fc.sources.isEmpty)  // :1185-1186
    }

    // C: /blend/blend/median-and-horizon (test-blend.c:1190-1236)
    @Test func blendMedianAndHorizon() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.miami()
        var gem = F.Vals(), icon = F.Vals(), ecmwf = F.Vals()
        gem.temp = 10
        icon.temp = 20
        ecmwf.temp = 30
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "gem", first: t0 + 10 * h, count: 80, gem))
        try fx.add("open-meteo", F.member("open-meteo", "icon", first: t0 + 10 * h, count: 80, icon))
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 80, ecmwf))
        let fc = try F.blend(fx, p, Self.nowS)
        expectNear(try F.hourAt(fc, t0 + 13 * h).tempC, 25.0, eps: 1e-9)  // :1207
        expectNear(try F.hourAt(fc, t0 + 30 * h).tempC, 25.0, eps: 1e-9)  // :1209
        expectNear(try F.hourAt(fc, t0 + 31 * h).tempC, 30.0, eps: 1e-9)  // :1210
        expectNear(try F.hourAt(fc, t0 + 13 * h).tempSpreadC, 20.0, eps: 1e-9)  // :1212
        #expect(try F.hourAt(fc, t0 + 13 * h).nMembers == 3)  // :1213
        expectNear(try F.hourAt(fc, t0 + 11 * h).tempC, 25.0, eps: 1e-9)  // :1215

        // HRRR (3 / 3 / 0.5) against ECMWF (1 / 1.5 / 2); HRRR drops out after 48 h (:1218-1235)
        var hrrr = F.Vals(), ec = F.Vals()
        hrrr.temp = 20
        ec.temp = 10
        var f2 = F.Fx()
        try f2.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 10 * h, count: 80, hrrr))
        try f2.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 80, ec))
        let c2 = try F.blend(f2, p, Self.nowS)
        expectNear(try F.hourAt(c2, t0 + 13 * h).tempC, 20.0, eps: 1e-9)
        #expect(try F.hourAt(c2, t0 + 13 * h).nMembers == 2)
        expectNear(try F.hourAt(c2, t0 + 31 * h).tempC, 10.0, eps: 1e-9)
        #expect(try F.hourAt(c2, t0 + 60 * h).nMembers == 2)  // :1231
        #expect(try F.hourAt(c2, t0 + 61 * h).nMembers == 1)  // :1232
        expectNear(try F.hourAt(c2, t0 + 61 * h).tempC, 10.0, eps: 1e-9)
        expectNaN(try F.hourAt(c2, t0 + 61 * h).tempSpreadC)
    }

    // C: /blend/blend/region (test-blend.c:1238-1316)
    @Test func blendRegion() throws {
        let (t0, h) = (Self.t0, Self.h)
        var hrrr = F.Vals(), ec = F.Vals(), nws = F.Vals()
        hrrr.temp = 30
        ec.temp = 10
        nws.temp = 40
        let places: [(Double, Double, String, Bool)] = [  // :1250-1260
            (25.7617, -80.1918, "Miami", true), (43.65, -79.38, "Toronto", true), (61.2, -149.9, "Anchorage", true),
            (19.9, -155.6, "Hawaii", true), (51.5074, -0.1278, "London", false), (35.68, 139.69, "Tokyo", false),
            (-33.87, 151.21, "Sydney", false), (51.05, -114.07, "Calgary", true), (23.11, -82.37, "Havana", true),
        ]
        for (lat, lon, name, us) in places {
            let p = try F.place(lat, lon, "UTC")
            var fx = F.Fx()
            try fx.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 10 * h, count: 30, hrrr))
            try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, ec))
            let x = try F.hourAt(try F.blend(fx, p, Self.nowS), t0 + 13 * h)
            expectNear(x.tempC, us ? 30.0 : 10.0, eps: 1e-9, Comment(rawValue: name))
            #expect(x.nMembers == (us ? 2 : 1), "\(name)")
        }

        // an NWS member makes any place a US-region place (London here) (:1280-1290)
        let lon = try F.london()
        var f2 = F.Fx()
        try f2.add("nws", F.member("nws", "nws", first: t0 + 10 * h, count: 30, nws))
        try f2.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, ec))
        try f2.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 10 * h, count: 30, hrrr))
        let c2 = try F.blend(f2, lon, Self.nowS)
        expectNear(try F.hourAt(c2, t0 + 13 * h).tempC, 35.0, eps: 1e-9)  // :1288
        #expect(try F.hourAt(c2, t0 + 13 * h).nMembers == 3)

        // without NWS in London there is no region switch (:1292-1298)
        var f3 = F.Fx()
        try f3.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, ec))
        try f3.add("open-meteo", F.member("open-meteo", "nbm", first: t0 + 10 * h, count: 30, nws))
        expectNear(try F.hourAt(try F.blend(f3, lon, Self.nowS), t0 + 13 * h).tempC, 10.0, eps: 1e-9)  // :1297
        // :1300-1315 (a hand-built NWS member with descending hours) is unrepresentable: WxMember
        // refuses descending hours at addHour, so no such member can reach the blend.
    }

    // C: /blend/blend/precip-and-probability (test-blend.c:1318-1391)
    @Test func blendPrecipAndProbability() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var a = F.Vals(), b = F.Vals(), c = F.Vals()
        a.precip = 0.5  // ecmwf, weight 3
        b.precip = 0.0  // icon, weight 2.5
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, a))
        try fx.add("open-meteo", F.member("open-meteo", "icon", first: t0 + 10 * h, count: 30, b))
        var x = try F.hourAt(try F.blend(fx, p, Self.nowS), t0 + 13 * h)
        expectNear(x.precipMm, 0.5, eps: 1e-9)  // :1330
        expectNear(x.precipMmMax, 0.5, eps: 1e-9)  // :1331
        expectNear(x.precipProb, 100.0 * 3.0 / 5.5, eps: 1e-9)  // :1333

        // one member supplies a probability: it is used, not derived (:1336-1349)
        c.precip = 0.2
        c.prob = 20.0
        try fx.add("open-meteo", F.member("open-meteo", "gem", first: t0 + 10 * h, count: 30, c))
        x = try F.hourAt(try F.blend(fx, p, Self.nowS), t0 + 13 * h)
        expectNear(x.precipProb, 20.0, eps: 1e-9)
        expectNear(x.precipMm, 0.2, eps: 1e-9)
        expectNear(x.precipMmMax, 0.5, eps: 1e-9)

        // probabilities are a weighted median among those who supply one (:1351-1364)
        var p1 = F.Vals(), p2 = F.Vals(), p3 = F.Vals()
        p1.prob = 10
        p2.prob = 50
        p3.prob = 90
        var f3 = F.Fx()
        try f3.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, p1))
        try f3.add("open-meteo", F.member("open-meteo", "icon", first: t0 + 10 * h, count: 30, p2))
        try f3.add("open-meteo", F.member("open-meteo", "gem", first: t0 + 10 * h, count: 30, p3))
        x = try F.hourAt(try F.blend(f3, p, Self.nowS), t0 + 13 * h)
        expectNear(x.precipProb, 50.0, eps: 1e-9)
        expectNaN(x.precipMm)
        expectNaN(x.precipMmMax)

        // neither precipitation nor probability anywhere: both unknown (:1366-1374)
        var t = F.Vals()
        t.temp = 12
        var f4 = F.Fx()
        try f4.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, t))
        x = try F.hourAt(try F.blend(f4, p, Self.nowS), t0 + 13 * h)
        expectNaN(x.precipProb)
        expectNaN(x.precipMm)

        // the NWS probability (weight 5) outweighs three others (1 each) (:1376-1390)
        var np = F.Vals(), o = F.Vals()
        np.prob = 80
        o.prob = 10
        var f5 = F.Fx()
        try f5.add("nws", F.member("nws", "nws", first: t0 + 10 * h, count: 30, np))
        try f5.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, o))
        try f5.add("open-meteo", F.member("open-meteo", "icon", first: t0 + 10 * h, count: 30, o))
        try f5.add("open-meteo", F.member("open-meteo", "gfs", first: t0 + 10 * h, count: 30, o))
        expectNear(try F.hourAt(try F.blend(f5, try F.miami(), Self.nowS), t0 + 13 * h).precipProb, 80.0, eps: 1e-9)
    }

    // C: /blend/blend/member-counts (test-blend.c:1393-1435)
    @Test func blendMemberCountsAndMissing() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var onlyCloud = F.Vals(), full = F.Vals(), onlyTemp = F.Vals()
        onlyCloud.cloud = 100
        full.temp = 10
        full.cloud = 0
        onlyTemp.temp = 12
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, full))
        try fx.add("open-meteo", F.member("open-meteo", "icon", first: t0 + 10 * h, count: 30, onlyCloud))
        try fx.add("open-meteo", F.member("open-meteo", "gem", first: t0 + 10 * h, count: 30, onlyTemp))
        // an all-unknown member (wmo 61 only) and a weight-0 member (HRRR outside the US) never count (:1406-1410)
        var wmoOnly = F.Vals()
        wmoOnly.wmo = 61
        try fx.add("open-meteo", F.member("open-meteo", "gfs", first: t0 + 10 * h, count: 30, wmoOnly))
        var hv = F.Vals()
        hv.temp = 99
        try fx.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 10 * h, count: 30, hv))
        let x = try F.hourAt(try F.blend(fx, p, Self.nowS), t0 + 13 * h)
        #expect(x.nMembers == 3)  // :1413
        expectNear(x.tempC, 10.0, eps: 1e-9)  // :1415
        expectNear(x.tempSpreadC, 2.0, eps: 1e-9)  // :1416
        expectNear(x.cloudPct, 0.0, eps: 1e-9)  // :1418
        expectNaN(x.windKmh)
        expectNaN(x.gustKmh)
        expectNaN(x.humidityPct)
        expectNaN(x.feelsC)

        // only a temperature: the condition is unknown, everything else NAN (:1426-1434)
        var f2 = F.Fx()
        try f2.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, onlyTemp))
        let y = try F.hourAt(try F.blend(f2, p, Self.nowS), t0 + 13 * h)
        #expect(y.condition == .unknown)
        expectNaN(y.cloudPct)
        #expect(y.nMembers == 1)
    }

    // C: /blend/blend/conditions-from-wmo (test-blend.c:1437-1495)
    @Test func blendConditionsFromWMO() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var a = F.Vals(temp: 10, cloud: 100, wmo: 95), c = a
        c.wmo = 0
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, a))
        try fx.add("open-meteo", F.member("open-meteo", "icon", first: t0 + 10 * h, count: 30, a))
        try fx.add("open-meteo", F.member("open-meteo", "gem", first: t0 + 10 * h, count: 30, c))
        #expect(try F.hourAt(try F.blend(fx, p, Self.nowS), t0 + 13 * h).condition == .thunderstorm)  // :1452

        // snow needs a cold hour; the blended temperature decides (:1455-1467)
        a = F.Vals(temp: 1, wmo: 71)
        let warm = F.Vals(temp: 8, wmo: 71)
        var f2 = F.Fx()
        try f2.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, a))
        try f2.add("open-meteo", F.member("open-meteo", "icon", first: t0 + 10 * h, count: 30, warm))
        #expect(try F.hourAt(try F.blend(f2, p, Self.nowS), t0 + 13 * h).condition == .snow)  // :1466

        // no codes at all: derived from the blended cloud and rain (:1469-1479)
        let r = F.Vals(temp: 12, precip: 1.0, prob: 80, cloud: 100)
        var f3 = F.Fx()
        try f3.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, r))
        #expect(try F.hourAt(try F.blend(f3, p, Self.nowS), t0 + 13 * h).condition == .lightRain)  // :1478

        // only members that contribute vote: HRRR (weight 0 in London) saying 95 is ignored (:1481-1494)
        let t = F.Vals(temp: 10, cloud: 10, wmo: 0)
        let hv = F.Vals(temp: 10, wmo: 95)
        var f4 = F.Fx()
        try f4.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 30, t))
        try f4.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 10 * h, count: 30, hv))
        #expect(try F.hourAt(try F.blend(f4, p, Self.nowS), t0 + 13 * h).condition == .clear)  // :1493
    }

    // C: /blend/blend/no-data (test-blend.c:1501-1599)
    @Test func blendNoData() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        // no results at all (:1507-1513)
        let e0 = F.blendError([], p, Self.nowS)
        #expect(e0?.code == .notFound)
        #expect(e0?.message == "no usable forecast data")  // :1510
        // results without members (:1515-1519)
        #expect(F.blendError([try WxSourceResult(providerID: "open-meteo")], p, Self.nowS)?.code == .notFound)

        var v = F.Vals()
        v.temp = 10
        // fewer than WX_BLEND_MIN_HOURS contributing hours: an error; exactly that many: fine (:1524-1536)
        for n in 1...(WxBlend.minHours + 1) {
            var f = F.Fx()
            try f.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 12 * h, count: n, v))
            if n < WxBlend.minHours {
                F.expectBlendFails(f, p, Self.nowS, .notFound)
            } else {
                #expect(try F.blend(f, p, Self.nowS).hours.count == n + 1)  // :1533
            }
        }
        #expect(WxBlend.minHours == 6)  // WX_BLEND_MIN_HOURS (wx-blend.h:30)

        // six hours split over two members is not enough (:1538-1543)
        var f2 = F.Fx()
        try f2.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 12 * h, count: 3, v))
        try f2.add("open-meteo", F.member("open-meteo", "icon", first: t0 + 15 * h, count: 3, v))
        F.expectBlendFails(f2, p, Self.nowS, .notFound)

        // six hours but one of them without any value: five (:1545-1554)
        var m = try F.newMember("open-meteo", "ecmwf")
        for i: Int64 in 12..<18 { F.addHour(&m, t0 + i * h, i == 14 ? F.Vals() : v) }
        var f3 = F.Fx()
        try f3.add("open-meteo", m)
        F.expectBlendFails(f3, p, Self.nowS, .notFound)

        // only data from the past (before the first bucket) (:1556-1560)
        var f4 = F.Fx()
        try f4.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0, count: 11, v))
        F.expectBlendFails(f4, p, Self.nowS, .notFound)

        // the first bucket (11:00) counts; 11:00 .. 16:00 is six hours (:1562-1567)
        var f5 = F.Fx()
        try f5.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 5 * h, count: 12, v))
        _ = try F.blend(f5, p, Self.nowS)

        // only members whose weight is 0 (HRRR outside the US) contribute nothing (:1569-1573)
        var f6 = F.Fx()
        try f6.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 10 * h, count: 30, v))
        F.expectBlendFails(f6, p, Self.nowS, .notFound)

        // HRRR beyond 48 h only (:1575-1580)
        var f7 = F.Fx()
        try f7.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 61 * h, count: 10, v))
        F.expectBlendFails(f7, try F.miami(), Self.nowS, .notFound)

        // out-of-range numbers only (:1582-1598): in C a hand-built member; here the builder turns
        // them into NaN (the same "counts as missing"), so the member has no value at all
        let bad = try F.member("open-meteo", "ecmwf", first: t0 + 12 * h, count: 8) { x, _ in
            x.tempC = 1000.0
            x.humidityPct = -5.0
            x.windKmh = .infinity
            x.precipMm = -1.0
            x.cloudPct = 101.0
        }
        #expect(throws: WxError(.notFound, "no usable forecast data")) { try F.blendRaw(p, [bad]) }
    }

    // C: /blend/blend/garbage-members (test-blend.c:1601-1702), the representable part
    @Test func blendGarbageMembers() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var good = F.Vals()
        good.temp = 10
        let real = try F.member("open-meteo", "icon", first: t0 + 10 * h, count: 8, good)

        // a member whose numbers are out of range in one hour: they count as missing (:1674-1688)
        let pm = try F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 8) { x, i in
            x.tempC = i == 3 ? 500.0 : 60.0  // hour 13:00 is out of range
            x.cloudPct = 55.0
        }
        let c4 = try F.blendRaw(p, [pm, real])
        expectNear(try F.hourAt(c4, t0 + 13 * h).tempC, 10.0, eps: 1e-9)  // :1685
        expectNear(try F.hourAt(c4, t0 + 13 * h).cloudPct, 55.0, eps: 1e-9)  // :1686
        #expect(try F.hourAt(c4, t0 + 13 * h).nMembers == 2)  // :1687
        expectNear(try F.hourAt(c4, t0 + 14 * h).tempC, 60.0, eps: 1e-9)  // :1688

        // members the builder refuses (descending, unaligned, out of range time stamps, invalid ids,
        // :1626-1639) never exist as WxMember: the builder outcome is checked instead
        var desc = try F.newMember("open-meteo", "ecmwf")
        let added1 = desc.addHour(WxHour(tS: t0 + 20 * h, tempC: 60))
        #expect(added1)
        let added2 = desc.addHour(WxHour(tS: t0 + 19 * h, tempC: 60))
        #expect(!added2)
        let added3 = desc.addHour(WxHour(tS: t0 + 10 * h + 1800, tempC: 60))
        #expect(!added3)
        let added4 = desc.addHour(WxHour(tS: 0, tempC: 60))
        #expect(!added4)
        for (s, m) in [("Open-Meteo", "ecmwf"), ("open-meteo", ""), ("open-meteo", "../ecmwf")] {
            #expect(throws: WxError.self) { try WxMember(sourceID: s, modelID: m, fetchedS: Self.nowS) }
        }
        #expect(throws: WxError.self) { try WxMember(sourceID: nil, modelID: "ecmwf", fetchedS: Self.nowS) }
        #expect(throws: WxError.self) { try WxMember(sourceID: "open-meteo", modelID: nil, fetchedS: Self.nowS) }
        // and a result list with empty results before the good one still blends (:1690-1701)
        var empty = try WxSourceResult(providerID: "x")
        empty.members = []
        var withReal = try WxSourceResult(providerID: "open-meteo")
        withReal.members = [real]
        let c5 = try WxBlend.forecast(place: p, results: [empty, withReal], nowS: Self.nowS)
        expectNear(try F.hourAt(c5, t0 + 13 * h).tempC, 10.0, eps: 1e-9)  // :1699
    }

    // C: /blend/blend/duplicates-and-cap (test-blend.c:1704-1761)
    @Test func blendDuplicatesAndCap() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.london()
        var a = F.Vals(), b = F.Vals()
        a.temp = 10
        b.temp = 50

        // the same (source, model) twice, in one result or in two: the first one wins (:1712-1726)
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 20, a))
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 20, b))
        try fx.add("other", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 20, b))
        let fc = try F.blend(fx, p, Self.nowS)
        expectNear(try F.hourAt(fc, t0 + 13 * h).tempC, 10.0, eps: 1e-9)  // :1718
        #expect(try F.hourAt(fc, t0 + 13 * h).nMembers == 1)
        var f2 = F.Fx()
        try f2.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 20, b))
        try f2.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 20, a))
        expectNear(try F.hourAt(try F.blend(f2, p, Self.nowS), t0 + 13 * h).tempC, 50.0, eps: 1e-9)  // :1725

        // same model of another source is a different member (:1728-1736)
        var f3 = F.Fx()
        try f3.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 20, a))
        try f3.add("met-no", F.member("met-no", "ecmwf", first: t0 + 10 * h, count: 20, b))
        let c3 = try F.blend(f3, p, Self.nowS)
        #expect(try F.hourAt(c3, t0 + 13 * h).nMembers == 2)
        expectNear(try F.hourAt(c3, t0 + 13 * h).tempC, 10.0, eps: 1e-9)

        // more distinct members than WX_BLEND_MAX_MEMBERS: the first ones are used (:1738-1747)
        var f4 = F.Fx()
        for i in 0..<(WxBlend.maxMembers + 5) {
            let model = "m" + String(repeating: "0", count: 3 - String(i).count) + String(i)
            try f4.add("other", F.member("other", model, first: t0 + 10 * h, count: 10, i < WxBlend.maxMembers ? a : b))
        }
        let c4 = try F.blend(f4, p, Self.nowS)
        #expect(Int(try F.hourAt(c4, t0 + 13 * h).nMembers) == WxBlend.maxMembers)  // :1745
        expectNear(try F.hourAt(c4, t0 + 13 * h).tempC, 10.0, eps: 1e-9)  // :1746

        // 128 members with distinct values: the weighted median stays defined (:1749-1760)
        var f5 = F.Fx()
        for i in 0..<WxBlend.maxMembers {
            let model = "m" + String(repeating: "0", count: 3 - String(i).count) + String(i)
            var v = F.Vals()
            v.temp = Double(i) * 0.5
            try f5.add("other", F.member("other", model, first: t0 + 10 * h, count: 10, v))
        }
        let c5 = try F.blend(f5, p, Self.nowS)
        expectNear(try F.hourAt(c5, t0 + 13 * h).tempC, 31.75, eps: 1e-9)  // :1758
        expectNear(try F.hourAt(c5, t0 + 13 * h).tempSpreadC, 63.5, eps: 1e-9)  // :1759
        // WX_BLEND_MAX_MEMBERS (wx-blend.h:26) == the service's forwarding cap
        #expect(WxBlend.maxMembers == 128 && WxBlend.maxMembers == ServicePipeline.blendMaxMembers)
    }

    // C: /blend/blend/statuses-and-place (test-blend.c:1763-1835), the representable part
    @Test func blendStatusesAndPlace() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.miami()
        var v = F.Vals()
        v.temp = 10
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 10 * h, count: 20, v))
        let s1 = try WxSourceStatus(
            providerID: "open-meteo", name: "Open-Meteo", attribution: "Weather data by Open-Meteo.com",
            attributionURL: "https://open-meteo.com/", state: .ok, errorCode: nil, nMembers: 1)
        let s2 = try WxSourceStatus(
            providerID: "nws", name: "National Weather Service", attribution: "NOAA", attributionURL: "",
            state: .failed, errorCode: .timeout, nMembers: 0)
        // statuses are copied into the forecast (:1773-1793)
        let fc = try WxBlend.forecast(place: p, results: fx.results, statuses: [s1, s2], nowS: Self.nowS)
        try #require(fc.sources.count == 2)
        #expect(fc.sources[0].providerID == "open-meteo")  // :1790
        #expect(fc.sources[1].name == "National Weather Service")  // :1791
        #expect(fc.sources[1].errorCode == .timeout)  // :1792

        // more statuses than WX_FORECAST_MAX_SOURCES: an error, not a critical; exactly that many: fine (:1801-1809)
        let many = [WxSourceStatus](repeating: s1, count: WxLimits.forecastMaxSources + 1)
        #expect(throws: WxError(.invalidArg, "too many forecast entries")) {
            try WxBlend.forecast(place: p, results: fx.results, statuses: many, nowS: Self.nowS)
        }
        let c16 = try WxBlend.forecast(
            place: p, results: fx.results, statuses: Array(many.prefix(WxLimits.forecastMaxSources)), nowS: Self.nowS)
        #expect(c16.sources.count == WxLimits.forecastMaxSources)
        // the error order of wx_blend_forecast (wx-blend.c:747-800, contract wx-blend.h:165-169): an
        // out-of-range now first, then "no usable forecast data", then wx_forecast_new's refusals
        #expect(throws: WxError(.notFound, "no usable forecast data")) {
            try WxBlend.forecast(place: p, results: [], statuses: many, nowS: Self.nowS)
        }
        #expect(throws: WxError(.invalidArg, "time is outside the supported range")) {
            try WxBlend.forecast(place: p, results: [], statuses: many, nowS: 0)
        }

        // a place without a zone ("" is NULL's meaning for a place) is accepted: UTC days (:1817-1820)
        let noTZ = try F.place(25.7617, -80.1918, "")
        _ = try WxBlend.forecast(place: noTZ, results: fx.results, nowS: Self.nowS)
        // hostile places ("/etc/passwd", "" name, NaN latitude, :1811-1830) cannot be built
        #expect(throws: WxError.self) { try F.place(25.7617, -80.1918, "/etc/passwd") }
        #expect(throws: WxError.self) { try WxPlace(name: "", lat: 25.7617, lon: -80.1918, timezone: "America/New_York") }
        #expect(throws: WxError.self) { try F.place(.nan, -80.1918, "America/New_York") }
    }

    // C: /blend/blend/daily-places (test-blend.c:3646-3693)
    @Test(arguments: [
        ("America/New_York", 25.7617, -80.1918, 10, Int64(1_791_691_200)),  // :3678
        ("Europe/London", 51.5074, -0.1278, 10, Int64(1_791_673_200)),  // :3679
        ("Australia/Sydney", -33.8688, 151.2093, 10, Int64(1_791_637_200)),  // :3680
    ])
    func blendDailyPlaces(tz: String, lat: Double, lon: Double, wantDays: Int, firstStart: Int64) throws {
        // assert_blend_days (test-blend.c:3646-3667)
        let p = try F.place(lat, lon, tz)
        var v = F.Vals()
        v.temp = 20
        v.cloud = 30
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: Self.t0, count: WxLimits.memberMaxHours, v))
        let fc = try F.blend(fx, p, Self.nowS)
        #expect(fc.days.count == wantDays)
        for (i, d) in fc.days.enumerated() {
            #expect(d.startS == firstStart + Int64(i) * 86400)
            expectNear(d.tempMaxC, 20.0, eps: 1e-9)
            #expect(d.condition == .mostlyClear)
        }
    }

    // C: /blend/blend/daily-places (test-blend.c:3681-3692): a place without a zone has UTC days
    @Test func blendDailyPlacesWithoutZone() throws {
        let p = try F.place(10.0, 10.0, "")
        var v = F.Vals()
        v.temp = 20
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: Self.t0, count: WxLimits.memberMaxHours, v))
        let fc = try F.blend(fx, p, Self.nowS)
        #expect(fc.days.count == 10)  // :3690
        #expect(fc.days.first?.startS == Self.t0)  // :3691
    }

    // C: /blend/blend/today-until-midnight (test-blend.c:3724-3771)
    @Test func blendTodayUntilMidnight() throws {
        let h = Self.h
        let miamiM: Int64 = 1_791_777_600  // MIAMI_M (test-blend.c:3695-3696)
        let p = try F.miami()
        var fx = F.Fx()
        // fill_miami_temp (:3716-3722): 10 + (i % 24) + 2 * (i / 24)
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: miamiM - 2 * 86400, count: 14 * 24) { x, i in
            x.tempC = 10 + Double(i % 24) + 2.0 * Double(i / 24)
        })
        let cases: [(String, Int64, Int)] = [  // :3739-3746
            ("00:30", 30 * 60, 0), ("01:30", 90 * 60, 0), ("09:00", 9 * h, 8), ("10:00", 10 * h, 9),
            ("13:59", 13 * h + 59 * 60, 12), ("14:00", 14 * h, 13), ("14:01", 14 * h + 60, 13), ("18:00", 18 * h, 17),
            ("23:00", 23 * h, 22), ("23:30", 23 * h + 30 * 60, 22), ("23:59:59", 24 * h - 1, 22),
        ]
        for (what, off, firstLH) in cases {
            let fc = try F.blend(fx, p, miamiM + off)
            #expect(fc.hours.first?.tS == miamiM + off - off % h - h, "\(what)")  // :3752
            try #require(fc.days.count >= 2, "\(what)")
            #expect(fc.days[0].startS == miamiM, "\(what)")
            #expect(fc.days[1].startS == miamiM + 86400, "\(what)")
            expectNear(fc.days[0].tempMinC, 14.0 + Double(firstLH), eps: 1e-9, Comment(rawValue: what))  // :3757
            expectNear(fc.days[0].tempMaxC, 37.0, eps: 1e-9, Comment(rawValue: what))  // :3758
            // hour_extremes (:3698-3714): the same numbers from the forecast's own hours
            let today = fc.hours.filter { $0.tS >= miamiM && $0.tS < miamiM + 86400 }
            #expect(today.count == 24 - firstLH, "\(what)")  // :3763
            expectNear(fc.days[0].tempMinC, today.map(\.tempC).min() ?? .nan, eps: 1e-9)
            expectNear(fc.days[0].tempMaxC, today.map(\.tempC).max() ?? .nan, eps: 1e-9)
            expectNear(fc.days[1].tempMinC, 16.0, eps: 1e-9)  // :3767
            expectNear(fc.days[1].tempMaxC, 39.0, eps: 1e-9)  // :3768
        }
    }

    // C: /blend/blend/today-half-hour-zone (test-blend.c:3773-3796)
    @Test func blendTodayHalfHourZone() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.place(22.5726, 88.3639, "Asia/Kolkata")
        var v = F.Vals()
        v.temp = 20
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 - 2 * 86400, count: 14 * 24, v))
        let m = t0 + 18 * h + 30 * 60  // 2026-10-12 00:00 IST (:3784)
        for off: Int64 in [1, 15 * 60, 29 * 60, 31 * 60, 45 * 60, 75 * 60, 13 * h + 59 * 60, 23 * h + 45 * 60, 24 * h - 1] {
            let fc = try F.blend(fx, p, m + off)
            try #require(fc.days.count >= 2)
            #expect(fc.days[0].startS == m, "offset \(off)")  // :3792
            #expect(fc.days[1].startS == m + 86400, "offset \(off)")  // :3793
        }
    }
}
