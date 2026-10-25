// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WeightsTests.swift - port of the /blend/weights/* cases of
// src/blend/test-blend.c (registered at src/blend/test-blend.c:5494-5498).
// The US table below is the C test's own table (typed independently of
// wx-weights.c), cited as test-blend.c:LINE.

import Testing
@testable import WeatherCore

@Suite struct WeightsTests {
    /// Cell (test-blend.c:467-471): source, model, group, H0, H1, H2, H3 (US region).
    struct Cell {
        let src: String
        let model: String
        let variable: WxVar
        let b: [Double]
    }

    /// ALL4(x) (test-blend.c:473).
    static func all4(_ x: Double) -> [Double] { [x, x, x, x] }

    /// us_cells (test-blend.c:475-530).
    static let usCells: [Cell] = [
        // TEMP
        Cell(src: "nws", model: "nws", variable: .temp, b: [4, 4, 4.5, 5]),  // test-blend.c:477
        Cell(src: "open-meteo", model: "hrrr", variable: .temp, b: [3, 3, 0.5, 0]),  // test-blend.c:478
        Cell(src: "open-meteo", model: "nbm", variable: .temp, b: [2.5, 3, 3, 2]),  // test-blend.c:479
        Cell(src: "open-meteo", model: "ecmwf", variable: .temp, b: [1, 1.5, 2, 2]),  // test-blend.c:480
        Cell(src: "open-meteo", model: "gfs", variable: .temp, b: [0.5, 1, 1, 1]),  // test-blend.c:481
        Cell(src: "open-meteo", model: "icon", variable: .temp, b: [0.5, 1, 1, 1]),  // test-blend.c:482
        Cell(src: "open-meteo", model: "gem", variable: .temp, b: all4(0.5)),  // test-blend.c:483
        Cell(src: "met-no", model: "ecmwf", variable: .temp, b: all4(0.5)),  // test-blend.c:484
        // WIND
        Cell(src: "nws", model: "nws", variable: .wind, b: all4(3)),  // test-blend.c:486
        Cell(src: "open-meteo", model: "hrrr", variable: .wind, b: [3, 3, 0.5, 0]),  // test-blend.c:487
        Cell(src: "open-meteo", model: "nbm", variable: .wind, b: all4(2)),  // test-blend.c:488
        Cell(src: "open-meteo", model: "ecmwf", variable: .wind, b: all4(1.5)),  // test-blend.c:489
        Cell(src: "open-meteo", model: "gfs", variable: .wind, b: all4(1)),  // test-blend.c:490
        Cell(src: "open-meteo", model: "icon", variable: .wind, b: all4(1)),  // test-blend.c:491
        Cell(src: "open-meteo", model: "gem", variable: .wind, b: all4(1)),  // test-blend.c:492
        Cell(src: "met-no", model: "ecmwf", variable: .wind, b: all4(1)),  // test-blend.c:493
        // CLOUD
        Cell(src: "nws", model: "nws", variable: .cloud, b: all4(3)),  // test-blend.c:495
        Cell(src: "open-meteo", model: "hrrr", variable: .cloud, b: [2, 2, 0.5, 0]),  // test-blend.c:496
        Cell(src: "open-meteo", model: "nbm", variable: .cloud, b: all4(2)),  // test-blend.c:497
        Cell(src: "open-meteo", model: "ecmwf", variable: .cloud, b: all4(1.5)),  // test-blend.c:498
        Cell(src: "open-meteo", model: "icon", variable: .cloud, b: all4(1)),  // test-blend.c:499
        Cell(src: "open-meteo", model: "gem", variable: .cloud, b: all4(1)),  // test-blend.c:500
        Cell(src: "open-meteo", model: "gfs", variable: .cloud, b: all4(1)),  // test-blend.c:501
        Cell(src: "met-no", model: "ecmwf", variable: .cloud, b: all4(1)),  // test-blend.c:502
        // HUMIDITY: 1 for every member (hrrr only up to 48 h)
        Cell(src: "nws", model: "nws", variable: .humidity, b: all4(1)),  // test-blend.c:504
        Cell(src: "open-meteo", model: "hrrr", variable: .humidity, b: [1, 1, 1, 0]),  // test-blend.c:505
        Cell(src: "open-meteo", model: "nbm", variable: .humidity, b: all4(1)),  // test-blend.c:506
        Cell(src: "open-meteo", model: "ecmwf", variable: .humidity, b: all4(1)),  // test-blend.c:507
        Cell(src: "open-meteo", model: "gfs", variable: .humidity, b: all4(1)),  // test-blend.c:508
        Cell(src: "open-meteo", model: "icon", variable: .humidity, b: all4(1)),  // test-blend.c:509
        Cell(src: "open-meteo", model: "gem", variable: .humidity, b: all4(1)),  // test-blend.c:510
        Cell(src: "met-no", model: "ecmwf", variable: .humidity, b: all4(1)),  // test-blend.c:511
        // PRECIP_MM
        Cell(src: "open-meteo", model: "hrrr", variable: .precipMm, b: [4, 4, 1, 0]),  // test-blend.c:513
        Cell(src: "nws", model: "nws", variable: .precipMm, b: [2, 3, 4, 4]),  // test-blend.c:514
        Cell(src: "open-meteo", model: "nbm", variable: .precipMm, b: all4(2)),  // test-blend.c:515
        Cell(src: "open-meteo", model: "ecmwf", variable: .precipMm, b: [1, 2, 2.5, 2.5]),  // test-blend.c:516
        Cell(src: "open-meteo", model: "icon", variable: .precipMm, b: [1, 1, 1.5, 1.5]),  // test-blend.c:517
        Cell(src: "open-meteo", model: "gem", variable: .precipMm, b: all4(1)),  // test-blend.c:518
        Cell(src: "open-meteo", model: "gfs", variable: .precipMm, b: all4(1)),  // test-blend.c:519
        Cell(src: "met-no", model: "ecmwf", variable: .precipMm, b: all4(1)),  // test-blend.c:520
        // PRECIP_PROB: nws 5, nbm 2, every other member 1
        Cell(src: "nws", model: "nws", variable: .precipProb, b: all4(5)),  // test-blend.c:522
        Cell(src: "open-meteo", model: "nbm", variable: .precipProb, b: all4(2)),  // test-blend.c:523
        Cell(src: "open-meteo", model: "hrrr", variable: .precipProb, b: [1, 1, 1, 0]),  // test-blend.c:524
        Cell(src: "open-meteo", model: "ecmwf", variable: .precipProb, b: all4(1)),  // test-blend.c:525
        Cell(src: "open-meteo", model: "gfs", variable: .precipProb, b: all4(1)),  // test-blend.c:526
        Cell(src: "open-meteo", model: "icon", variable: .precipProb, b: all4(1)),  // test-blend.c:527
        Cell(src: "open-meteo", model: "gem", variable: .precipProb, b: all4(1)),  // test-blend.c:528
        Cell(src: "met-no", model: "ecmwf", variable: .precipProb, b: all4(1)),  // test-blend.c:529
    ]

    /// band_horizon: a horizon inside each band (test-blend.c:533).
    static let bandHorizon: [Double] = [1.5, 10.0, 40.0, 100.0]

    static func w(_ src: String, _ model: String, _ v: WxVar, _ h: Double, _ us: Bool) -> Double {
        WxWeights.weight(sourceID: src, modelID: model, variable: v, horizonH: h, usRegion: us)
    }

    // C: /blend/weights/us-table (test-blend.c:536-547)
    @Test("/blend/weights/us-table") func usTable() {
        #expect(Self.usCells.count == 48)  // the C table has 48 cells (test-blend.c:477-529)
        for c in Self.usCells {
            for b in 0..<4 {
                let got = Self.w(c.src, c.model, c.variable, Self.bandHorizon[b], true)  // test-blend.c:540-541
                #expect(got == c.b[b], "US \(c.src):\(c.model) var \(c.variable) band \(b): got \(got) want \(c.b[b])")  // test-blend.c:542-544
                // every cell of the C table is a real row, never the fallback
                #expect(WxWeights.lookup(sourceID: c.src, modelID: c.model, variable: c.variable,
                                         horizonH: Self.bandHorizon[b], usRegion: true).origin == .tableRow)
            }
        }
    }

    // C: /blend/weights/world-table (test-blend.c:550-578)
    @Test("/blend/weights/world-table") func worldTable() {
        // ecmwf 3, icon 2.5, ukmo 2, meteofrance 2, gem 1.5, gfs 1.5, met-no:ecmwf 1.5 for
        // TEMP/WIND/CLOUD/PRECIP_MM; HUMIDITY 1; PRECIP_PROB 1
        let rows: [(src: String, model: String, main: Double)] = [
            ("open-meteo", "ecmwf", 3.0), ("open-meteo", "icon", 2.5), ("open-meteo", "ukmo", 2.0),  // test-blend.c:558
            ("open-meteo", "meteofrance", 2.0), ("open-meteo", "gem", 1.5), ("open-meteo", "gfs", 1.5),  // test-blend.c:559
            ("met-no", "ecmwf", 1.5),  // test-blend.c:560
        ]
        for r in rows {
            for h in Self.bandHorizon {
                #expect(Self.w(r.src, r.model, .temp, h, false) == r.main)  // test-blend.c:565
                #expect(Self.w(r.src, r.model, .wind, h, false) == r.main)  // test-blend.c:566
                #expect(Self.w(r.src, r.model, .cloud, h, false) == r.main)  // test-blend.c:567
                #expect(Self.w(r.src, r.model, .precipMm, h, false) == r.main)  // test-blend.c:568
                #expect(Self.w(r.src, r.model, .humidity, h, false) == 1.0)  // test-blend.c:569
                #expect(Self.w(r.src, r.model, .precipProb, h, false) == 1.0)  // test-blend.c:570
            }
        }
        // ukmo and meteofrance keep their weights in the US region (the design leaves them out)
        #expect(Self.w("open-meteo", "ukmo", .temp, 5, true) == 2.0)  // test-blend.c:574
        #expect(Self.w("open-meteo", "meteofrance", .precipMm, 5, true) == 2.0)  // test-blend.c:575
        #expect(Self.w("open-meteo", "ukmo", .humidity, 5, true) == 1.0)  // test-blend.c:576
        #expect(Self.w("open-meteo", "ukmo", .precipProb, 5, true) == 1.0)  // test-blend.c:577
    }

    // C: /blend/weights/invariants (test-blend.c:581-622). The `known` predicate of the C
    // test (:611-614) also checks the lookup's row-or-fallback report.
    @Test("/blend/weights/invariants") func invariants() {
        let srcs = ["nws", "open-meteo", "met-no", "other"]  // test-blend.c:583
        let models = ["nws", "hrrr", "hrrr15", "nbm", "ecmwf", "gfs", "icon",  // test-blend.c:584
                      "gem", "ukmo", "meteofrance", "newmodel", ""]  // test-blend.c:585
        let horizons: [Double] = [-1e9, -1, 0, 1, 2.999, 3, 17.999, 18, 47.9, 48, 48.001, 71.999,  // test-blend.c:586
                                  72, 100, 240, 1e9, .infinity, -.infinity]  // test-blend.c:587
        var failures = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            if !ok {
                failures += 1
                if failures <= 10 {
                    Issue.record(Comment(rawValue: what()))
                }
            }
        }
        for s in srcs {
            for m in models {
                for v in WxVar.allCases {
                    for h in horizons {
                        for us in [false, true] {
                            let ctx = "\(s):\(m) var \(v) h \(h) us \(us)"
                            let w = Self.w(s, m, v, h, us)  // test-blend.c:593
                            check(w.isFinite, "finite \(ctx)")  // test-blend.c:594
                            check(w >= 0.0, ">= 0 \(ctx)")  // test-blend.c:595
                            check(w <= 5.0, "<= 5 \(ctx)")  // test-blend.c:596
                            // purity: the same arguments, the same weight
                            check(w == Self.w(s, m, v, h, us), "pure \(ctx)")  // test-blend.c:598
                            let hrrr = s == "open-meteo" && (m == "hrrr" || m == "hrrr15")  // test-blend.c:599-600
                            if hrrr && (h > 48.0 || !us) {  // test-blend.c:601
                                check(w == 0.0, "hrrr zero \(ctx)")  // test-blend.c:602
                            }
                            if hrrr && us && h <= 48.0 && h >= 0.0 {  // test-blend.c:603
                                check(w > 0.0, "hrrr weighted \(ctx)")  // test-blend.c:604
                            }
                            if s == "nws" && !us {  // test-blend.c:605
                                check(w == 0.0, "nws outside US \(ctx)")  // test-blend.c:606
                            }
                            if s == "nws" && us {  // test-blend.c:607
                                check(w > 0.0, "nws in US \(ctx)")  // test-blend.c:608
                            }
                            if s == "open-meteo" && m == "nbm" && !us {  // test-blend.c:609
                                check(w == 0.0, "nbm outside US \(ctx)")  // test-blend.c:610
                            }
                            let known = s == "nws"  // test-blend.c:611
                                || (s == "open-meteo" && m != "newmodel" && m != "nws" && m != "")  // test-blend.c:612-613
                                || (s == "met-no" && m == "ecmwf")  // test-blend.c:614
                            if !known {  // test-blend.c:615
                                check(w == WxWeights.unknownWeight, "unknown \(ctx)")  // test-blend.c:616
                            }
                            // the lookup reports a real row exactly for the C test's known pairs
                            let lookup = WxWeights.lookup(sourceID: s, modelID: m, variable: v, horizonH: h, usRegion: us)
                            check(lookup.origin == (known ? .tableRow : .fallback), "origin \(ctx)")
                            check(lookup.weight == w, "lookup weight \(ctx)")
                            check(WxWeights.hasTableRow(sourceID: s, modelID: m) == known, "hasTableRow \(ctx)")
                        }
                    }
                }
            }
        }
        #expect(failures == 0)
        #expect(WxWeights.unknownWeight == 1.0)  // WX_WEIGHT_UNKNOWN (src/blend/wx-weights.h:35)
        #expect(WxWeights.hrrrMaxHorizonH == 48.0)  // WX_WEIGHT_HRRR_MAX_HORIZON_H (src/blend/wx-weights.h:38)
        #expect(WxVar.count == 6 && WxVar.allCases.count == WxVar.count)  // WX_VAR_COUNT (src/blend/wx-weights.h:31)
    }

    // C: /blend/weights/edges (test-blend.c:625-655)
    @Test("/blend/weights/edges") func edges() {
        // band edges: [0,3) [3,18) [18,72) [72,...)
        #expect(Self.w("open-meteo", "ecmwf", .temp, 2.999, true) == 1.0)  // test-blend.c:628
        #expect(Self.w("open-meteo", "ecmwf", .temp, 3.0, true) == 1.5)  // test-blend.c:629
        #expect(Self.w("open-meteo", "ecmwf", .temp, 17.999, true) == 1.5)  // test-blend.c:630
        #expect(Self.w("open-meteo", "ecmwf", .temp, 18.0, true) == 2.0)  // test-blend.c:631
        #expect(Self.w("nws", "nws", .temp, 71.999, true) == 4.5)  // test-blend.c:632
        #expect(Self.w("nws", "nws", .temp, 72.0, true) == 5.0)  // test-blend.c:633
        // negative horizon is band 0, infinity the last band
        #expect(Self.w("nws", "nws", .temp, -5.0, true) == 4.0)  // test-blend.c:635
        #expect(Self.w("nws", "nws", .temp, -.infinity, true) == 4.0)  // test-blend.c:636
        #expect(Self.w("nws", "nws", .temp, .infinity, true) == 5.0)  // test-blend.c:637
        // HRRR: exactly 48 h is still weighted, beyond it is not
        #expect(Self.w("open-meteo", "hrrr", .temp, 48.0, true) == 0.5)  // test-blend.c:639
        #expect(Self.w("open-meteo", "hrrr", .temp, 48.0001, true) == 0.0)  // test-blend.c:640
        #expect(Self.w("open-meteo", "hrrr15", .precipMm, 20.0, true) == 1.0)  // test-blend.c:641
        #expect(Self.w("open-meteo", "hrrr15", .precipMm, 49.0, true) == 0.0)  // test-blend.c:642
        // unknown horizon: excluded
        #expect(Self.w("nws", "nws", .temp, .nan, true) == 0.0)  // test-blend.c:644
        #expect(Self.w("other", "x", .temp, .nan, false) == 0.0)  // test-blend.c:645
        // NWS: any model id of the source "nws" is the NWS row; the id match is exact and case sensitive
        #expect(Self.w("nws", "gridpoint", .temp, 1.0, true) == 4.0)  // test-blend.c:647
        #expect(Self.w("NWS", "nws", .temp, 1.0, true) == WxWeights.unknownWeight)  // test-blend.c:648
        #expect(Self.w("open-meteo", "ECMWF", .temp, 1.0, true) == WxWeights.unknownWeight)  // test-blend.c:649
        #expect(Self.w("other-source", "ecmwf", .temp, 1.0, true) == WxWeights.unknownWeight)  // test-blend.c:650
        #expect(Self.w("open-meteo", "ecmwf_ifs025", .temp, 1.0, true) == WxWeights.unknownWeight)  // test-blend.c:651
        #expect(Self.w("met-no", "gfs", .temp, 1.0, false) == WxWeights.unknownWeight)  // test-blend.c:652
        // unknown ids weigh the same everywhere
        #expect(Self.w("brand-new", "model", .precipProb, 500, false) == 1.0)  // test-blend.c:654
        // the lookup's report on the same pairs: hrrr15 aliases the hrrr row, nws matches any
        // model, case and spelling variants fall back (Swift-only API; rules wx-weights.h:63-71)
        #expect(WxWeights.hasTableRow(sourceID: "open-meteo", modelID: "hrrr15"))
        #expect(WxWeights.hasTableRow(sourceID: "nws", modelID: "gridpoint"))
        #expect(!WxWeights.hasTableRow(sourceID: "NWS", modelID: "nws"))
        #expect(!WxWeights.hasTableRow(sourceID: "open-meteo", modelID: "ecmwf_ifs025"))
        #expect(!WxWeights.hasTableRow(sourceID: "met-no", modelID: "hrrr15"))
        let nanLookup = WxWeights.lookup(sourceID: "nws", modelID: "nws", variable: .temp, horizonH: .nan, usRegion: true)
        #expect(nanLookup.weight == 0.0 && nanLookup.origin == .tableRow)
        // C strcmp reads ids up to their NUL (wx-weights.h:52-54): bytes after a NUL are not compared
        #expect(Self.w("nws\u{0}x", "nws", .temp, 1.0, true) == 4.0)  // nws TEMP H0: test-blend.c:477
        #expect(Self.w("open-meteo", "hrrr15\u{0}y", .temp, 1.0, true) == 3.0)  // hrrr TEMP H0: test-blend.c:478
    }

    @Test("/blend/weights/multipliers-and-descriptors") func multipliersAndDescriptors() throws {
        var mults = WxWeightMultipliers()
        #expect(mults.isDefault)
        mults.setSourceMultiplier(1.5, for: "nws")
        mults.setModelMultiplier(2.0, sourceID: "open-meteo", modelID: "hrrr15")
        #expect(!mults.isDefault)
        #expect(mults.sourceMultiplier(for: "nws") == 1.5)
        #expect(mults.modelMultiplier(sourceID: "open-meteo", modelID: "hrrr") == 2.0)
        #expect(mults.combinedMultiplier(sourceID: "nws", modelID: "grid") == 1.5)
        #expect(mults.combinedMultiplier(sourceID: "open-meteo", modelID: "hrrr15") == 2.0)
        mults.setSourceMultiplier(1.0, for: "nws")
        mults.setModelMultiplier(1.0, sourceID: "open-meteo", modelID: "hrrr")
        #expect(mults.isDefault)
        #expect(WxWeights.modelDescriptors.count == 13)
    }

    @Test("/blend/weights/regional-profiles-uk-nl-de-ca") func regionalProfilesUKNLDECA() throws {
        // UK & Ireland: UKMO leads short-range (0-18h) and hands off to ECMWF at 72h+
        let ukShortUKMO = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "ukmo", variable: .temp, horizonH: 2.0, region: .ukIreland)
        let ukShortECMWF = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "ecmwf", variable: .temp, horizonH: 2.0, region: .ukIreland)
        let ukLongUKMO = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "ukmo", variable: .temp, horizonH: 96.0, region: .ukIreland)
        let ukLongECMWF = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "ecmwf", variable: .temp, horizonH: 96.0, region: .ukIreland)
        #expect(ukShortUKMO > ukShortECMWF)
        #expect(ukLongECMWF > ukLongUKMO)

        // Netherlands / Benelux: KNMI HARMONIE leads short-range (0-18h) and drops to 0 at 72h+
        let nlShortKNMI = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "knmi", variable: .precipMm, horizonH: 2.0, region: .beneluxNorthSea)
        let nlLongKNMI = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "knmi", variable: .precipMm, horizonH: 96.0, region: .beneluxNorthSea)
        let nlBrightSky = WxWeights.baseWeight(sourceID: "dwd-brightsky", modelID: "mosmix", variable: .temp, horizonH: 6.0, region: .beneluxNorthSea)
        #expect(nlShortKNMI == 4.0)
        #expect(nlLongKNMI == 0.0)
        #expect(nlBrightSky > 2.5)

        // Germany / Central Europe: DWD ICON + BrightSky MOSMIX lead short-range
        let deShortICON = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "icon", variable: .temp, horizonH: 2.0, region: .centralEurope)
        let deShortMOSMIX = WxWeights.baseWeight(sourceID: "dwd-brightsky", modelID: "mosmix", variable: .temp, horizonH: 2.0, region: .centralEurope)
        #expect(deShortICON == 4.0)
        #expect(deShortMOSMIX == 3.5)

        // Canada: ECCC GeoMet HRDPS + Open-Meteo GEM lead short-range; HRRR contributes up to 48h
        let caShortECCC = WxWeights.baseWeight(sourceID: "eccc", modelID: "hrdps", variable: .temp, horizonH: 2.0, region: .canada)
        let caShortGEM = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "gem", variable: .temp, horizonH: 2.0, region: .canada)
        let caShortHRRR = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "hrrr", variable: .precipMm, horizonH: 2.0, region: .canada)
        let caPost48HRRR = WxWeights.baseWeight(sourceID: "open-meteo", modelID: "hrrr", variable: .precipMm, horizonH: 50.0, region: .canada)
        #expect(caShortECCC == 4.0)
        #expect(caShortGEM == 4.0)
        #expect(caShortHRRR == 4.0)
        #expect(caPost48HRRR == 0.0)

        let london = try WxPlace(name: "London", admin1: "England", country: "United Kingdom", countryCode: "GB",
                                 lat: 51.5072, lon: -0.1276, timezone: "Europe/London")
        let amsterdam = try WxPlace(name: "Amsterdam", admin1: "North Holland", country: "Netherlands", countryCode: "NL",
                                    lat: 52.3676, lon: 4.9041, timezone: "Europe/Amsterdam")
        let berlin = try WxPlace(name: "Berlin", admin1: "Berlin", country: "Germany", countryCode: "DE",
                                 lat: 52.5200, lon: 13.4050, timezone: "Europe/Berlin")
        let calgary = try WxPlace(name: "Calgary", admin1: "Alberta", country: "Canada", countryCode: "CA",
                                  lat: 51.0447, lon: -114.0719, timezone: "America/Edmonton")
        let toronto = try WxPlace(name: "Toronto", admin1: "Ontario", country: "Canada", countryCode: "CA",
                                  lat: 43.6532, lon: -79.3832, timezone: "America/Toronto")

        #expect(OpenMeteoShared.models(for: london).nowcastPath?.contains("minutely_15=precipitation") == true)
        #expect(OpenMeteoShared.models(for: amsterdam).models.contains(.knmiSeamless))
        #expect(OpenMeteoShared.models(for: amsterdam).nowcastPath?.contains("models=knmi_seamless") == true)
        #expect(OpenMeteoShared.models(for: berlin).nowcastPath?.contains("models=icon_seamless") == true)
        #expect(OpenMeteoShared.models(for: calgary).models.contains(.ncepHrrrConus))
        #expect(OpenMeteoShared.models(for: calgary).nowcastPath?.contains("models=ncep_hrrr_conus") == true)
        #expect(!WxGeo.inUSNWS(place: toronto))
    }
}
