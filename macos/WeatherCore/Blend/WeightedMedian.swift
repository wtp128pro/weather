// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WeightedMedian.swift - the weighted median of the blend. Port of
// wx_weighted_median and mean_of_pair (src/blend/wx-blend.c:29-113,
// contract src/blend/wx-blend.h:35-71).
//
// Bit-for-bit with the C code (do not "simplify"): the power-of-two scaling
// of the weights (frexp/ldexp, one IEEE rounding per weight), the stable
// insertion sort by value in argument order, the left-to-right sum in sorted
// order, the walk while `cumulative * 2 < total`, and the exact 50 % tie that
// returns the in-range mean of the two neighbouring values.

/// The weighted median of the blend (wx_weighted_median).
public enum WxWeightedMedian {
    /// WX_BLEND_MAX_MEMBERS (src/blend/wx-blend.h:26): the most entries one
    /// call accepts.
    public static let maxEntries = 128

    /// wx_weighted_median (wx-blend.c:64-113).
    ///
    /// An entry takes part iff its value and weight are finite and the weight
    /// is > 0 (NaN, infinities, zero and negative weights are ignored). The
    /// weights are scaled by 2^-e, where e is the frexp exponent of the
    /// largest taking-part weight; a weight that underflows to 0 is dropped.
    /// The entries are sorted by value (stable); the result is the first
    /// value whose cumulative weight reaches more than half of the total, or,
    /// when the lower values carry exactly half, the mean of that value and
    /// the next one (always within the two).
    ///
    /// - Returns: the median, or NaN when no entry takes part, when the arrays
    ///   differ in length, or when they hold more than `maxEntries` entries
    ///   (the C code logs a critical and returns NAN for its count check).
    ///   The arguments are not modified.
    public static func median(values: [Double], weights: [Double]) -> Double {
        let n = values.count
        guard weights.count == n, n <= maxEntries else {
            return .nan
        }

        var maxWeight = 0.0
        for i in 0..<n {
            if values[i].isFinite && weights[i].isFinite && weights[i] > 0.0 {
                // fmax(max_weight, w): neither operand is NaN here.
                maxWeight = maxWeight < weights[i] ? weights[i] : maxWeight
            }
        }
        if maxWeight == 0.0 {
            return .nan
        }

        // Scaling by a power of two is exact, and keeps the sums below 128
        // whatever the magnitude of the weights (wx-blend.c:78-81).
        let exponent = frexpExponent(maxWeight)

        var sortedValue = [Double](repeating: 0.0, count: n)
        var sortedWeight = [Double](repeating: 0.0, count: n)
        var k = 0
        for i in 0..<n {
            if !values[i].isFinite || !weights[i].isFinite || weights[i] <= 0.0 {
                continue
            }
            let w = ldexp(weights[i], -exponent)
            if w <= 0.0 {  // underflow: negligible next to the largest weight
                continue
            }
            var j = k
            k += 1
            while j > 0 && sortedValue[j - 1] > values[i] {
                sortedValue[j] = sortedValue[j - 1]
                sortedWeight[j] = sortedWeight[j - 1]
                j -= 1
            }
            sortedValue[j] = values[i]
            sortedWeight[j] = w
        }

        var total = 0.0
        for i in 0..<k {
            total += sortedWeight[i]
        }

        // The last cumulative weight is exactly total (same summation order),
        // so the loop ends at the latest on the last entry (wx-blend.c:104-109).
        var i = 0
        var cumulative = sortedWeight[0]
        while cumulative * 2.0 < total {
            i += 1
            cumulative += sortedWeight[i]
        }
        if cumulative * 2.0 == total {  // the lower values carry exactly half, so i + 1 < k
            return meanOfPair(sortedValue[i], sortedValue[i + 1])
        }
        return sortedValue[i]
    }

    /// mean_of_pair (wx-blend.c:55-61): the mean of two ordered finite
    /// doubles a <= b that is always within [a, b]: (a + b) / 2 for values of
    /// opposite signs, a + (b - a) / 2 otherwise.
    private static func meanOfPair(_ a: Double, _ b: Double) -> Double {
        if a < 0.0 && b > 0.0 {
            return (a + b) / 2.0
        }
        return a + (b - a) / 2.0
    }

    /// The exponent C frexp() stores for a positive finite x (x = m * 2^e
    /// with m in [0.5, 1)). Swift's `exponent` is floor(log2(x)) (significand
    /// in [1, 2), subnormals included), one less than frexp's.
    private static func frexpExponent(_ x: Double) -> Int {
        Int(x.exponent) + 1
    }

    /// C ldexp(x, n) = x * 2^n with a single IEEE rounding, for the n this
    /// file uses: n = -e for the frexp exponent e of a positive finite double,
    /// so -1024 <= n <= 1073. For n <= 1023, 2^n is an exactly representable
    /// double (subnormal below -1022), so one multiplication is that single
    /// rounding. (Swift's `Double(sign:exponent:significand:)` multiplies
    /// twice for exponents below -1022 and can round twice, so it is not used
    /// with x as the significand.) Above 1023 the largest weight is subnormal,
    /// so every x is too: x * 2^1023 is then exact and only the last
    /// multiplication could round.
    private static func ldexp(_ x: Double, _ n: Int) -> Double {
        if n > 1023 {
            return ldexp(x * powerOfTwo(1023), n - 1023)
        }
        return x * powerOfTwo(n)
    }

    /// 2^n for -1074 <= n <= 1023, built from its bit pattern (exact).
    private static func powerOfTwo(_ n: Int) -> Double {
        if n >= -1022 {
            return Double(bitPattern: UInt64(n + 1023) << 52)
        }
        return Double(bitPattern: UInt64(1) << UInt64(n + 1074))
    }
}
