// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WeightedMedianTests.swift - port of the /blend/median/* cases of
// src/blend/test-blend.c (registered at src/blend/test-blend.c:5486-5492).
// Expected values are the C test literals, cited as test-blend.c:LINE.
// The fuzz cases keep the C oracles with SeededRNG instead of GLib's GRand
// (DECISIONS #16-#17): they are PROPERTY TESTS, not replays of the C cases.

import Testing
@testable import WeatherCore

@Suite struct WeightedMedianTests {
    /// ASSERT_NEAR's epsilon (test-blend.c:51).
    static let eps = 1e-9
    /// DBL_MAX.
    static let dblMax = Double.greatestFiniteMagnitude

    /// wm (test-blend.c:261-264).
    static func wm(_ v: [Double], _ w: [Double]) -> Double {
        WxWeightedMedian.median(values: v, weights: w)
    }

    // C: /blend/median/basic (test-blend.c:267-301)
    @Test("/blend/median/basic") func basic() {
        // odd, equal weights: the middle value, whatever the input order
        expectNear(Self.wm([3, 1, 2], [1, 1, 1]), 2.0, eps: Self.eps)  // test-blend.c:270-271
        // even, equal weights: mean of the two middle values
        expectNear(Self.wm([4, 1, 3, 2], [1, 1, 1, 1]), 2.5, eps: Self.eps)  // test-blend.c:273-274
        // one sample
        expectNear(Self.wm([7.5], [0.25]), 7.5, eps: Self.eps)  // test-blend.c:276-277
        // two samples, equal weights: exactly 50 % -> mean
        expectNear(Self.wm([1, 2], [1, 1]), 1.5, eps: Self.eps)  // test-blend.c:279-280
        // a weight above half wins
        expectNear(Self.wm([1, 2], [1, 2]), 2.0, eps: Self.eps)  // test-blend.c:282-283
        expectNear(Self.wm([1, 2], [2, 1]), 1.0, eps: Self.eps)  // test-blend.c:284-285
        // exactly 50 % in the middle of three: lower half {1,2} weighs 2 of 4
        expectNear(Self.wm([1, 2, 3], [1, 1, 2]), 2.5, eps: Self.eps)  // test-blend.c:287-288
        // just below 50 %: not a tie, the next value (c = 2 of 5)
        expectNear(Self.wm([1, 2, 3, 4], [2, 1, 1, 1]), 2.0, eps: Self.eps)  // test-blend.c:290-291
        // exactly 50 % at the first value: 3 of 6
        expectNear(Self.wm([1, 2, 3, 4], [3, 1, 1, 1]), 1.5, eps: Self.eps)  // test-blend.c:293-294
        // fractional weights that are multiples of 0.5 (table values): 1.5 of 3 is exactly half
        expectNear(Self.wm([10, 20, 30], [1.5, 1.0, 0.5]), 15.0, eps: Self.eps)  // test-blend.c:296-297
        // negative values and a mean of negatives
        expectNear(Self.wm([-3, -1], [1, 1]), -2.0, eps: Self.eps)  // test-blend.c:299-300
    }

    // C: /blend/median/ties-zeros-nan (test-blend.c:304-338)
    @Test("/blend/median/ties-zeros-nan") func tiesZerosNaN() {
        // equal values are interchangeable
        expectNear(Self.wm([5, 5, 5], [1, 2, 3]), 5.0, eps: Self.eps)  // test-blend.c:307-308
        expectNear(Self.wm([5, 7, 5, 7], [1, 1, 1, 1]), 6.0, eps: Self.eps)  // test-blend.c:309-310
        // weight 0, negative weight, NaN or infinite weight, NaN or infinite value: ignored
        let v3: [Double] = [100, 1, .nan, 200, .infinity, -.infinity, 2, 3]  // test-blend.c:312
        let w3: [Double] = [0, 1, 1, -5, 1, 1, 1, 1]  // test-blend.c:313
        expectNear(Self.wm(v3, w3), 2.0, eps: Self.eps)  // test-blend.c:314
        expectNaN(Self.wm([1, 2, 3], [.nan, .infinity, -.infinity]))  // test-blend.c:315-316
        // nothing usable
        expectNaN(Self.wm([.nan, .nan], [1, 1]))  // test-blend.c:318-319
        expectNaN(Self.wm([1, 2], [0, 0]))  // test-blend.c:320-321
        // empty input is valid (C: NULL arrays with n = 0)
        expectNaN(Self.wm([], []))  // test-blend.c:323
        // the arrays are not modified
        let v7: [Double] = [3, 1, 2], w7: [Double] = [1, 1, 1]  // test-blend.c:325
        _ = Self.wm(v7, w7)
        #expect(v7[0] == 3 && v7[1] == 1 && v7[2] == 2 && w7[2] == 1)  // test-blend.c:327-330
        // the full range of a member count: WX_BLEND_MAX_MEMBERS = 128 (src/blend/wx-blend.h:26)
        #expect(WxWeightedMedian.maxEntries == 128)
        let n = WxWeightedMedian.maxEntries
        let v8 = (0..<n).map { Double(n - $0) }  // test-blend.c:334
        let w8 = [Double](repeating: 1, count: n)  // test-blend.c:335
        expectNear(Self.wm(v8, w8), 64.5, eps: Self.eps)  // test-blend.c:337
    }

    // C: /blend/median/extreme-weights (test-blend.c:341-363)
    @Test("/blend/median/extreme-weights") func extremeWeights() {
        // sums of huge weights would overflow without the power-of-two scaling
        let v: [Double] = [1, 2, 3]  // test-blend.c:344
        expectNear(Self.wm(v, [1e308, 1e308, 1e308]), 2.0, eps: Self.eps)  // test-blend.c:345-346
        expectNear(Self.wm(v, [5e-324, 5e-324, 5e-324]), 2.0, eps: Self.eps)  // test-blend.c:347-348 (denormals)
        expectNear(Self.wm([1, 2], [1e308, 1e308]), 1.5, eps: Self.eps)  // test-blend.c:349-350
        // a weight far below the largest is absorbed by rounding or ignored, never an
        // error: the answer is the exact one (2) or the tie (2.5)
        let v3: [Double] = [1, 2, 3]  // test-blend.c:354
        let r3 = Self.wm(v3, [1e-320, 1, 1])  // test-blend.c:353
        #expect(r3 == 2.0 || r3 == 2.5, "got \(r3)")  // test-blend.c:355
        let r6 = Self.wm(v3, [1e-300, 1e308, 1e308])  // test-blend.c:356
        #expect(r6 == 2.0 || r6 == 2.5, "got \(r6)")  // test-blend.c:357
        // huge values: the mean of the two middle values must not overflow
        expectNear(Self.wm([1.7e308, 1.7e308], [1, 1]) / 1e308, 1.7, eps: Self.eps)  // test-blend.c:359-360
        #expect(Self.wm([1.7e308, -1.7e308], [1, 1]) == 0.0)  // test-blend.c:361-362
    }

    /// reference_median (test-blend.c:367-393): every sample repeated
    /// "weight" times (small integer weights), then the median of the
    /// expanded list. An independent oracle, not the code under test.
    static func referenceMedian(_ v: [Double], _ w: [Int]) -> Double {
        var list: [Double] = []
        for i in 0..<v.count {
            for _ in 0..<w[i] {
                list.append(v[i])
            }
        }
        if list.isEmpty {
            return .nan
        }
        // insertion sort
        for i in 1..<list.count {
            let x = list[i]
            var j = i
            while j > 0 && list[j - 1] > x {
                list[j] = list[j - 1]
                j -= 1
            }
            list[j] = x
        }
        let len = list.count
        return len % 2 == 1 ? list[len / 2] : (list[len / 2 - 1] + list[len / 2]) / 2
    }

    // C: /blend/median/fuzz-reference (test-blend.c:396-417)
    // PROPERTY TEST: seeded fuzz against the reference oracle (SeededRNG, not GRand).
    @Test("/blend/median/fuzz-reference (property test: seeded fuzz vs reference oracle)")
    func fuzzReference() {
        var rng = SeededRNG(seed: 12345)  // C seed: test-blend.c:398
        var failures = 0
        for iter in 0..<fuzzIterations(60000) {  // test-blend.c:399
            let n = Int.random(in: 0..<12, using: &rng)  // test-blend.c:400
            var v: [Double] = [], w: [Double] = [], wi: [Int] = []
            for _ in 0..<n {
                // few distinct values to produce many ties and exact 50 % splits
                v.append(Double(Int.random(in: -5..<6, using: &rng)) * 0.5)  // test-blend.c:405
                wi.append(Int.random(in: 0..<9, using: &rng))  // test-blend.c:406
                w.append(Double(wi[wi.count - 1]) * 0.5)  // test-blend.c:407
            }
            let got = Self.wm(v, w)
            let want = Self.referenceMedian(v, wi)
            let ok = want.isNaN ? got.isNaN : got == want  // test-blend.c:411-414
            if !ok {
                failures += 1
                if failures <= 5 {
                    Issue.record("iter \(iter): v \(v) w \(w): got \(got) want \(want)")
                }
            }
        }
        #expect(failures == 0)
    }

    // C: /blend/median/criticals (test-blend.c:420-429). The NULL-array cases
    // (:423-425) and the g_critical log are GLIB-INTERNAL; the NaN result of the
    // count check (wx-blend.c:67; contract wx-blend.h:60) is behavioural.
    @Test("/blend/median/criticals (count check returns NaN)") func criticals() {
        let big = [Double](repeating: 0, count: WxWeightedMedian.maxEntries + 1)  // test-blend.c:426
        expectNaN(Self.wm(big, big))  // test-blend.c:427-428
        // the same count with usable entries: still NaN (the check comes first, wx-blend.c:67)
        let ones = [Double](repeating: 1, count: WxWeightedMedian.maxEntries + 1)
        expectNaN(Self.wm(ones, ones))
        // Swift-only shape check (C has one count for both arrays): lengths differ -> NaN
        expectNaN(Self.wm([1, 2], [1]))
    }

    // C: /blend/median/guard-page (test-blend.c:444-459). The guard page itself is
    // memory-safety plumbing (Swift arrays are bounds-checked); the values are ported.
    @Test("/blend/median/guard-page (values)") func guardPage() {
        for n in 1...5 {  // test-blend.c:446
            let v = (0..<n).map { Double($0) }  // test-blend.c:452
            let w = [Double](repeating: 1, count: n)  // test-blend.c:453
            expectNear(Self.wm(v, w), Double(n - 1) / 2.0, eps: Self.eps, "n \(n)")  // test-blend.c:455
        }
    }

    // C: /blend/median/tie-mean-in-range (test-blend.c:4212-4276)
    @Test("/blend/median/tie-mean-in-range") func tieMeanInRange() {
        let ds: [Double] = [0.0, 4.9e-324, 9.8e-324, 1.5e-323, 1e-310, 2.2250738585072014e-308,  // test-blend.c:4214
                            1e-300, 0.5, 1.0, 3.0, 1e300, 8.9e307, Self.dblMax / 2, Self.dblMax]  // test-blend.c:4215
        let w: [Double] = [1, 1]  // test-blend.c:4216
        for a in ds {
            for b in ds {
                for sa in [-1.0, 1.0] {
                    for sb in [-1.0, 1.0] {
                        let v = [sa * a, sb * b]  // test-blend.c:4221
                        let lo = Double.minimum(v[0], v[1]), hi = Double.maximum(v[0], v[1])  // test-blend.c:4222
                        let got = Self.wm(v, w)
                        #expect(got.isFinite, "v \(v)")  // test-blend.c:4224
                        #expect(got >= lo && got <= hi, "v \(v): got \(got)")  // test-blend.c:4225-4226
                        // the order of the inputs does not matter
                        #expect(Self.wm([v[1], v[0]], w).bitPattern == got.bitPattern, "v \(v)")  // test-blend.c:4228-4229
                        // correct to one unit in the last place against a wider type: C runs it only
                        // when long double is wider than double (test-blend.c:4202-4208, 4231), which
                        // is false on arm64; Float80 exists only on x86_64.
                        #if arch(x86_64)
                            let ref = (Float80(v[0]) + Float80(v[1])) / 2  // test-blend.c:4232
                            let ulp = abs(got.nextUp - got)  // test-blend.c:4233
                            if ulp.isFinite {
                                #expect(abs(Float80(got) - ref) <= Float80(ulp), "v \(v)")  // test-blend.c:4235
                            }
                        #endif
                    }
                }
            }
        }
        // the named cases
        #expect(Self.wm([4.9e-324, 4.9e-324], w) == 4.9e-324)  // test-blend.c:4242-4243
        #expect(Self.wm([-Self.dblMax, Self.dblMax], w) == 0.0)  // test-blend.c:4244-4245
        #expect(Self.wm([Self.dblMax, Self.dblMax], w) == Self.dblMax)  // test-blend.c:4246-4247
        #expect(Self.wm([0.0, Self.dblMax], w) == Self.dblMax / 2)  // test-blend.c:4248-4249
        let e = Self.wm([-4.9e-324, -9.8e-324], w)  // test-blend.c:4250
        #expect(e >= -9.8e-324 && e <= -4.9e-324)  // test-blend.c:4251-4252
        // three values where the tie is between the lower two, with unequal weights
        let r3 = Self.wm([4.9e-324, 4.9e-324, 1.0], [1, 1, 2])  // test-blend.c:4254-4255
        #expect(r3 >= 4.9e-324 && r3 <= 1.0)  // test-blend.c:4256-4257
        // random bit patterns (PROPERTY TEST: SeededRNG, not GRand)
        var rng = SeededRNG(seed: 5)  // C seed: test-blend.c:4259
        var failures = 0
        for iter in 0..<fuzzIterations(200000) {  // test-blend.c:4260
            var bits = [rng.next(), rng.next()]  // test-blend.c:4261-4262
            if iter % 2 == 0 {  // bias to subnormals (test-blend.c:4263-4266)
                bits[0] &= 0x800F_FFFF_FFFF_FFFF
                bits[1] &= 0x800F_FFFF_FFFF_FFFF
            }
            let v = [Double(bitPattern: bits[0]), Double(bitPattern: bits[1])]
            if !v[0].isFinite || !v[1].isFinite {  // test-blend.c:4269-4270
                continue
            }
            let got = Self.wm(v, w)
            if !(got >= Double.minimum(v[0], v[1]) && got <= Double.maximum(v[0], v[1])) {  // test-blend.c:4272-4273
                failures += 1
                if failures <= 5 {
                    Issue.record("v \(v): got \(got)")
                }
            }
        }
        #expect(failures == 0)
    }
}
