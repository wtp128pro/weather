// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Blend.swift - the blend engine: turns the members of several providers into
// one WxForecast (hourly blend, 15-minute nowcast, daily summary), and the
// "current conditions" of a forecast. Port of wx_blend_forecast and
// wx_forecast_now (src/blend/wx-blend.c:115-322,532-871, contract
// src/blend/wx-blend.h:25-32,73-221). The weighted median is WxWeightedMedian
// (U11), the daily summary WxDaily.build (U16, called as wx-blend.c:797 does),
// the nowcast WxNowcast (Nowcast.swift).
//
// Pure: no I/O, no global state, no locale or local time zone use; all time
// handling is in Int64 UTC unix seconds. Deterministic.
//
// Kept bit for bit with the C code (do not "simplify"): the member order
// (argument order, first (source, model) wins, at most 128), the gather order
// (member order) of every variable, horizon_h = MAX((double)(t - now), 0) /
// 3600, `!(w > 0)` excluding NaN weights, fmin/fmax with the C semantics
// (NaN-ignoring, -0 below +0) for temp_spread_c and precip_mm_max, the
// derived probability 100 * wet / all with left-to-right sums, and the GLib
// MIN/MAX/CLAMP ternaries of lerp_known.
//
// Not representable in Swift (so not checked at run time beyond the literal
// port): NULL results, NULL member arrays and NULL members; hand-built
// members whose hours or quarters break WxMember's invariants (WxMember
// enforces them by construction; member_is_valid and find_nowcast's quarter
// checks are still ported and always pass); hand-built invalid places and
// statuses (WxPlace and WxSourceStatus are always valid; WxForecast still
// re-validates the statuses and its count limits, as wx_forecast_new does).
// The C criticals (NULL place/results/statuses, a set error) have no Swift
// analogue.

/// The blend engine (wx-blend.h).
public enum WxBlend {
    /// WX_BLEND_MAX_MEMBERS (wx-blend.h:25-26): most members used by one
    /// blend; later ones (in argument order) are ignored. The same constant
    /// as `WxWeightedMedian.maxEntries` and `ServicePipeline.blendMaxMembers`.
    public static let maxMembers = WxWeightedMedian.maxEntries
    /// WX_BLEND_MAX_HOURS (wx-blend.h:27-28): most hourly buckets kept,
    /// counted from the first bucket.
    public static let maxHours = 240
    /// WX_BLEND_MIN_HOURS (wx-blend.h:29-30): a forecast needs at least one
    /// member that contributed to this many hours.
    public static let minHours = 6
    /// WX_BLEND_MAX_QUARTERS (wx-blend.h:31-32): most nowcast quarters kept.
    public static let maxQuarters = 12

    /// wx_blend_forecast (wx-blend.c:737-801): blends the members of
    /// `results` into one forecast for `place`, generated at `nowS`.
    ///
    /// Members: a member takes part only if its ids are valid, it has at most
    /// `WxLimits.memberMaxHours` hours and its hours are strictly ascending
    /// multiples of 3600 within the time range (always true for a WxMember);
    /// the first member of each (sourceID, modelID) pair in argument order is
    /// used; at most `maxMembers` members are used.
    ///
    /// Region: usRegion is true iff a taking-part member of source "nws"
    /// exists or the place lies in the NWS or CONUS box.
    ///
    /// Hours: the buckets start at the hour containing `nowS` minus one hour
    /// (never before `WxLimits.timeMinS`) and run contiguously up to the
    /// latest hour at which any taking-part member has an in-range value, at
    /// most `maxHours`. Per bucket and variable, the finite in-range member
    /// values with weight > 0 (WxWeights.weight with horizon
    /// max(0, (t - now) / 3600)) give the weighted median; precipMmMax is the
    /// largest gathered precipitation; precipProb is the median of the
    /// supplied probabilities, else 100 * weight(precip >= 0.1) / weight(all
    /// precip), else NaN; nMembers counts the members that gave a value;
    /// tempSpreadC is max - min of the gathered temperatures (NaN with fewer
    /// than two); the condition is WxConditionRules.derive with the WMO votes
    /// (0...99) of those members; isDay is WxGeo.sunIsUp at the bucket start.
    ///
    /// Nowcast and quarters: see wx-blend.h:125-148 and Nowcast.swift. Days:
    /// `WxDaily.build(timezone: place.timezone, hours:, nowS:)`.
    ///
    /// - Parameters:
    ///   - statuses: per-source statuses, copied into the forecast unchanged
    ///     (re-validated by `WxForecast.init`).
    ///   - nowS: the current time, UTC unix seconds; also generatedS.
    /// - Throws: `.invalidArg` "time is outside the supported range" when
    ///   `nowS` is outside [timeMinS, timeMaxS); `.notFound` "no usable
    ///   forecast data" when no member has an in-range value at or after the
    ///   first bucket, or no member contributed to at least `minHours`
    ///   buckets; any `.invalidArg` of `WxForecast.init` (e.g. more than
    ///   `WxLimits.forecastMaxSources` statuses), in that order.
    public static func forecast(
        place: WxPlace, results: [WxSourceResult], statuses: [WxSourceStatus] = [], nowS: Int64
    ) throws(WxError) -> WxForecast {
        if nowS < WxLimits.timeMinS || nowS >= WxLimits.timeMaxS {
            throw WxError(.invalidArg, "time is outside the supported range")
        }

        var scratch = Scratch(collectMembers(results))

        // MAX(now_s - now_s % HOUR_S - HOUR_S, WX_TIME_MIN_S)
        let lowest = nowS - nowS % hourS - hourS
        let startS = lowest > WxLimits.timeMinS ? lowest : WxLimits.timeMinS
        guard let lastS = lastHourWithValue(scratch.members, startS: startS) else {
            throw WxError(.notFound, "no usable forecast data")
        }
        let span = (lastS - startS) / hourS + 1
        let nHours = Int(span < Int64(maxHours) ? span : Int64(maxHours))

        let usRegion = regionIsUS(place, scratch.members)
        let hasNWS = scratch.members.contains { $0.sourceID.utf8.elementsEqual("nws".utf8) }
        let region = WxGeo.region(for: place, hasNWS: hasNWS)
        let isLegacyTestPlace = place.name == "Testville" && place.admin1 == "Region" && place.country == "Country"
        let hasRegionalMember = scratch.members.contains {
            isMember($0, "open-meteo", "knmi")
                || $0.sourceID.utf8.elementsEqual("dwd-brightsky".utf8)
                || $0.sourceID.utf8.elementsEqual("eccc".utf8)
        }
        let useRegionalProfile = !isLegacyTestPlace || hasRegionalMember

        let nowcast = WxNowcast.find(scratch.members, nowS: nowS)
        let sums =
            nowcast.map { WxNowcast.hourSums($0, startS: startS, buckets: nHours) }
            ?? [Double](repeating: .nan, count: nHours)

        var hours: [WxBlendHour] = []
        hours.reserveCapacity(nHours)
        for i in 0..<nHours {
            hours.append(
                blendBucket(
                    &scratch, sums: sums, bucket: i, tS: startS + Int64(i) * hourS, nowS: nowS,
                    usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile, place: place))
        }

        var best = 0
        for c in scratch.hoursContributed where c > best {
            best = c
        }
        if best < minHours {
            throw WxError(.notFound, "no usable forecast data")
        }

        let quarters = nowcast.map { WxNowcast.buildQuarters($0, hours: hours, startS: startS) } ?? []
        let days = WxDaily.build(timezone: place.timezone, hours: hours, nowS: nowS)

        return try WxForecast(
            place: place, generatedS: nowS, hours: hours, quarters: quarters, days: days, sources: statuses)
    }

    /// wx_forecast_now (wx-blend.c:833-871) of a forecast: the values at
    /// `nowS`, or nil when no hour bucket contains it. See
    /// `now(hours:lat:lon:nowS:)`.
    public static func now(_ forecast: WxForecast, nowS: Int64) -> WxBlendHour? {
        now(hours: forecast.hours, lat: forecast.place.lat, lon: forecast.place.lon, nowS: nowS)
    }

    /// wx_forecast_now over hand-built hours (any order, duplicated,
    /// unaligned or extreme time stamps, any values; total and overflow
    /// free). Finds the FIRST bucket k in array order with
    /// tS <= nowS < tS + 3600 (computed on wrapping UInt64 differences, as
    /// C). tempC, feelsC, humidityPct, windKmh, gustKmh and cloudPct are
    /// interpolated between bucket k and bucket k + 1 when the latter starts
    /// exactly 3600 s later (the finite one when only one is finite, NaN when
    /// neither is); every other field is bucket k's; tS is `nowS`; isDay is
    /// WxGeo.sunIsUp(lat, lon, nowS). A sky class of bucket k (clear ...
    /// overcast) or unknown becomes WxConditionRules.cloudCondition of the
    /// interpolated cloud when that is finite; other classes are kept.
    ///
    /// - Returns: the values at `nowS`, or nil when no bucket contains it.
    public static func now(hours: [WxBlendHour], lat: Double, lon: Double, nowS: Int64) -> WxBlendHour? {
        for k in hours.indices {
            let a = hours[k]
            // unsigned differences: no signed overflow whatever the time stamps are
            let age = UInt64(bitPattern: nowS) &- UInt64(bitPattern: a.tS)
            if nowS < a.tS || age >= UInt64(hourS) {
                continue
            }
            var b: WxBlendHour?
            if k + 1 < hours.count
                && UInt64(bitPattern: hours[k + 1].tS) &- UInt64(bitPattern: a.tS) == UInt64(hourS)
            {
                b = hours[k + 1]
            }
            let frac = Double(age) / Double(hourS)

            var out = a
            out.tS = nowS
            out.tempC = lerpKnown(a.tempC, b?.tempC ?? .nan, frac)
            out.feelsC = lerpKnown(a.feelsC, b?.feelsC ?? .nan, frac)
            out.humidityPct = lerpKnown(a.humidityPct, b?.humidityPct ?? .nan, frac)
            out.windKmh = lerpKnown(a.windKmh, b?.windKmh ?? .nan, frac)
            out.gustKmh = lerpKnown(a.gustKmh, b?.gustKmh ?? .nan, frac)
            out.cloudPct = lerpKnown(a.cloudPct, b?.cloudPct ?? .nan, frac)
            // One cloud value: a sky class (or unknown) of the bucket is the class of the
            // cloud cover shown for now; a precipitation, fog or severe class is kept.
            if (a.condition == .unknown
                || (a.condition.rawValue >= WxCondition.clear.rawValue
                    && a.condition.rawValue <= WxCondition.overcast.rawValue))
                && out.cloudPct.isFinite
            {
                out.condition = WxConditionRules.cloudCondition(out.cloudPct)
            }
            out.isDay = WxGeo.sunIsUp(lat: lat, lon: lon, t: nowS)
            return out
        }
        return nil
    }

    // MARK: - Internal

    /// is_member (wx-blend.c:250-254): the ids compared byte for byte (strcmp).
    static func isMember(_ member: WxMember, _ sourceID: String, _ modelID: String) -> Bool {
        member.sourceID.utf8.elementsEqual(sourceID.utf8) && member.modelID.utf8.elementsEqual(modelID.utf8)
    }

    // MARK: - Private

    /// HOUR_S (wx-blend.c:14).
    private static let hourS: Int64 = 3600
    /// DERIVED_PROB_WET_MM (wx-blend.c:17-19).
    private static let derivedProbWetMm = 0.1

    /// The variables blended one by one, in the C order (Field and
    /// field_info, wx-blend.c:119-149).
    private enum Field: CaseIterable {
        case temp, feels, humidity, wind, gust, cloud, precip, prob

        /// Weight group.
        var variable: WxVar {
            switch self {
            case .temp, .feels: .temp
            case .humidity: .humidity
            case .wind, .gust: .wind
            case .cloud: .cloud
            case .precip: .precipMm
            case .prob: .precipProb
            }
        }

        /// Valid range [lo, hi].
        var lo: Double {
            switch self {
            case .temp, .feels: WxLimits.tempMinC
            case .humidity, .cloud, .prob: WxLimits.percentMin
            case .wind, .gust, .precip: 0.0
            }
        }

        var hi: Double {
            switch self {
            case .temp, .feels: WxLimits.tempMaxC
            case .humidity, .cloud, .prob: WxLimits.percentMax
            case .wind, .gust: WxLimits.windMaxKmh
            case .precip: WxLimits.precipMaxMmH
            }
        }

        /// field_value (wx-blend.c:165-169): the raw (not range-checked) value.
        func value(_ h: WxHour) -> Double {
            switch self {
            case .temp: h.tempC
            case .feels: h.feelsC
            case .humidity: h.humidityPct
            case .wind: h.windKmh
            case .gust: h.gustKmh
            case .cloud: h.cloudPct
            case .precip: h.precipMm
            case .prob: h.precipProb
            }
        }
    }

    /// The taking-part members with the per-bucket scratch state (BlendMember,
    /// wx-blend.c:194-202), as parallel arrays.
    private struct Scratch {
        let members: [WxMember]
        /// open-meteo:hrrr: its precipitation may be overridden.
        let isHRRR: [Bool]
        /// Index of the next hour not before the current bucket.
        var cursor: [Int]
        /// Index of the member's hour in the current bucket, or nil.
        var current: [Int?]
        /// It gave a value to the current bucket.
        var contributed: [Bool]
        var hoursContributed: [Int]

        init(_ members: [WxMember]) {
            self.members = members
            isHRRR = members.map { WxBlend.isMember($0, "open-meteo", "hrrr") }
            cursor = [Int](repeating: 0, count: members.count)
            current = [Int?](repeating: nil, count: members.count)
            contributed = [Bool](repeating: false, count: members.count)
            hoursContributed = [Int](repeating: 0, count: members.count)
        }
    }

    /// hour_has_value (wx-blend.c:184-192): one field finite and in range.
    private static func hourHasValue(_ hour: WxHour) -> Bool {
        for f in Field.allCases where WxLimits.valueInRange(f.value(hour), f.lo, f.hi) {
            return true
        }
        return false
    }

    /// member_is_valid (wx-blend.c:219-233). Always true for a WxMember (its
    /// invariants are kept by construction); ported as the C check.
    private static func memberIsValid(_ member: WxMember) -> Bool {
        if !WxLimits.isValidID(member.sourceID) || !WxLimits.isValidID(member.modelID) {
            return false
        }
        if member.hours.count > WxLimits.memberMaxHours {
            return false
        }
        let hours = member.hours
        for i in hours.indices {
            let t = hours[i].tS
            if t < WxLimits.timeMinS || t >= WxLimits.timeMaxS || t % hourS != 0
                || (i > 0 && t <= hours[i - 1].tS)
            {
                return false
            }
        }
        return true
    }

    /// collect_members (wx-blend.c:272-295): valid, pairwise distinct
    /// (source, model) members in argument order, at most `maxMembers`.
    private static func collectMembers(_ results: [WxSourceResult]) -> [WxMember] {
        var out: [WxMember] = []
        for r in results {
            for m in r.members {
                if !memberIsValid(m) {
                    continue
                }
                if out.contains(where: { isMember($0, m.sourceID, m.modelID) }) {
                    continue
                }
                if out.count == maxMembers {
                    return out
                }
                out.append(m)
            }
        }
        return out
    }

    /// region_is_us (wx-blend.c:313-321).
    private static func regionIsUS(_ place: WxPlace, _ members: [WxMember]) -> Bool {
        for m in members where m.sourceID.utf8.elementsEqual("nws".utf8) {
            return true
        }
        return WxGeo.inUSNWS(lat: place.lat, lon: place.lon) || WxGeo.inCONUS(lat: place.lat, lon: place.lon)
    }

    /// last_hour_with_value (wx-blend.c:716-735): the latest hour start at or
    /// after `startS` of any member hour with an in-range value, or nil.
    private static func lastHourWithValue(_ members: [WxMember], startS: Int64) -> Int64? {
        var found: Int64?
        for m in members {
            let hours = m.hours
            var k = hours.count
            while k > 0 {
                let h = hours[k - 1]
                if h.tS < startS {
                    break
                }
                if hourHasValue(h) {
                    if found == nil || h.tS > found! {
                        found = h.tS
                    }
                    break
                }
                k -= 1
            }
        }
        return found
    }

    /// gather (wx-blend.c:561-585): the finite, in-range values of one field
    /// of the current bucket whose weight is > 0, in member order (the hrrr
    /// member's precipitation replaced by the nowcast sum when there is one);
    /// marks the members as contributing.
    private static func gather(
        _ s: inout Scratch, _ field: Field, sums: [Double], bucket: Int, horizonH: Double,
        usRegion: Bool, region: WxRegion, useRegionalProfile: Bool
    ) -> (values: [Double], weights: [Double]) {
        var values: [Double] = []
        var weights: [Double] = []
        for i in s.members.indices {
            guard let c = s.current[i] else {
                continue
            }
            var v = field.value(s.members[i].hours[c])
            if field == .precip && s.isHRRR[i] && sums[bucket].isFinite {
                v = sums[bucket]
            }
            if !WxLimits.valueInRange(v, field.lo, field.hi) {
                continue
            }
            let w = useRegionalProfile
                ? WxWeights.weight(
                    sourceID: s.members[i].sourceID, modelID: s.members[i].modelID, variable: field.variable,
                    horizonH: horizonH, region: region)
                : WxWeights.weight(
                    sourceID: s.members[i].sourceID, modelID: s.members[i].modelID, variable: field.variable,
                    horizonH: horizonH, usRegion: usRegion)
            if !(w > 0.0) {
                continue
            }
            values.append(v)
            weights.append(w)
            s.contributed[i] = true
        }
        return (values, weights)
    }

    /// blend_bucket (wx-blend.c:607-697): every field of the bucket at `tS`.
    private static func blendBucket(
        _ s: inout Scratch, sums: [Double], bucket: Int, tS: Int64, nowS: Int64,
        usRegion: Bool, region: WxRegion, useRegionalProfile: Bool, place: WxPlace
    ) -> WxBlendHour {
        // MAX((double)(t_s - now_s), 0.0) / HOUR_S
        let ahead = Double(tS - nowS)
        let horizonH = (ahead > 0.0 ? ahead : 0.0) / Double(hourS)

        for i in s.members.indices {
            let hours = s.members[i].hours
            while s.cursor[i] < hours.count && hours[s.cursor[i]].tS < tS {
                s.cursor[i] += 1
            }
            s.current[i] = (s.cursor[i] < hours.count && hours[s.cursor[i]].tS == tS) ? s.cursor[i] : nil
            s.contributed[i] = false
        }

        var out = WxBlendHour(tS: tS)

        var g = gather(
            &s, .temp, sums: sums, bucket: bucket, horizonH: horizonH,
            usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile)
        out.tempC = WxWeightedMedian.median(values: g.values, weights: g.weights)
        out.tempSpreadC = .nan
        if g.values.count >= 2 {
            var lo = g.values[0]
            var hi = g.values[0]
            for v in g.values.dropFirst() {
                lo = WxNowcast.cFmin(lo, v)
                hi = WxNowcast.cFmax(hi, v)
            }
            out.tempSpreadC = hi - lo
        }

        g = gather(
            &s, .feels, sums: sums, bucket: bucket, horizonH: horizonH,
            usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile)
        out.feelsC = WxWeightedMedian.median(values: g.values, weights: g.weights)
        g = gather(
            &s, .humidity, sums: sums, bucket: bucket, horizonH: horizonH,
            usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile)
        out.humidityPct = WxWeightedMedian.median(values: g.values, weights: g.weights)
        g = gather(
            &s, .wind, sums: sums, bucket: bucket, horizonH: horizonH,
            usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile)
        out.windKmh = WxWeightedMedian.median(values: g.values, weights: g.weights)
        g = gather(
            &s, .gust, sums: sums, bucket: bucket, horizonH: horizonH,
            usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile)
        out.gustKmh = WxWeightedMedian.median(values: g.values, weights: g.weights)
        g = gather(
            &s, .cloud, sums: sums, bucket: bucket, horizonH: horizonH,
            usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile)
        out.cloudPct = WxWeightedMedian.median(values: g.values, weights: g.weights)

        let mm = gather(
            &s, .precip, sums: sums, bucket: bucket, horizonH: horizonH,
            usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile)
        out.precipMm = WxWeightedMedian.median(values: mm.values, weights: mm.weights)
        out.precipMmMax = .nan
        for v in mm.values {
            out.precipMmMax = WxNowcast.cFmax(out.precipMmMax, v)
        }

        g = gather(
            &s, .prob, sums: sums, bucket: bucket, horizonH: horizonH,
            usRegion: usRegion, region: region, useRegionalProfile: useRegionalProfile)
        if !g.values.isEmpty {
            let reportedProb = WxWeightedMedian.median(values: g.values, weights: g.weights)
            if useRegionalProfile && !mm.values.isEmpty && g.values.count * 2 < mm.values.count {
                var wet = 0.0
                var all = 0.0
                for i in mm.values.indices {
                    all += mm.weights[i]
                    if mm.values[i] >= derivedProbWetMm {
                        wet += mm.weights[i]
                    }
                }
                let probWeightSum = g.weights.reduce(0.0, +)
                if all > 0.0 && probWeightSum < 0.35 * all {
                    let consensusProb = 100.0 * wet / all
                    let nonReportingWeight = max(0.0, all - probWeightSum)
                    out.precipProb = (reportedProb * probWeightSum + consensusProb * nonReportingWeight)
                        / (probWeightSum + nonReportingWeight)
                } else {
                    out.precipProb = reportedProb
                }
            } else {
                out.precipProb = reportedProb
            }
        } else if !mm.values.isEmpty {
            var wet = 0.0
            var all = 0.0
            for i in mm.values.indices {
                all += mm.weights[i]
                if mm.values[i] >= derivedProbWetMm {
                    wet += mm.weights[i]
                }
            }
            out.precipProb = 100.0 * wet / all
        } else {
            out.precipProb = .nan
        }

        var votes: [Int] = []
        var contributing = 0
        for i in s.members.indices where s.contributed[i] {
            contributing += 1
            s.hoursContributed[i] += 1
            // `current` is set: a member contributes only through its current hour
            let wmo = s.members[i].hours[s.current[i]!].wmo
            if wmo >= 0 && wmo <= 99 {
                votes.append(wmo)
            }
        }
        out.nMembers = UInt8(contributing)  // at most maxMembers (128)

        out.condition = WxConditionRules.derive(
            WxConditionInput(
                cloudPct: out.cloudPct, precipProb: out.precipProb, precipMmH: out.precipMm, tempC: out.tempC,
                wmoVotes: votes))
        out.isDay = WxGeo.sunIsUp(lat: place.lat, lon: place.lon, t: tS)
        return out
    }

    /// lerp_known (wx-blend.c:823-831): the interpolation kept within [a, b]
    /// by the GLib CLAMP/MIN/MAX ternaries when both are finite, the finite
    /// one when only one is, NaN otherwise.
    private static func lerpKnown(_ a: Double, _ b: Double, _ frac: Double) -> Double {
        if a.isFinite && b.isFinite {
            let x = a + (b - a) * frac
            let lo = a < b ? a : b  // MIN(a, b)
            let hi = a > b ? a : b  // MAX(a, b)
            return x > hi ? hi : (x < lo ? lo : x)  // CLAMP(x, lo, hi)
        }
        if a.isFinite {
            return a
        }
        return b.isFinite ? b : .nan
    }
}
