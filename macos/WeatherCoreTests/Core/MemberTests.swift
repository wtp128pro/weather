// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// MemberTests.swift - port of the Hour/member cases of src/core/test-core.c
// (registered at src/core/test-core.c:3513-3521) plus the member and
// source-result lines of id-validation, time-range-edges and
// error-messages-no-echo. Expected values are the C test literals, cited as
// path:line. C string literals with escapes are written as byte arrays.

import Testing
@testable import WeatherCore

@Suite struct MemberTests {
    /// T0 (src/core/test-core.c:18).
    static let t0: Int64 = 1_791_676_800

    /// Expects an add to return `want` (a mutating call cannot run inside #expect).
    static func check(_ got: Bool, _ want: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(got == want, sourceLocation: sourceLocation)
    }

    /// make_member (src/core/test-core.c:80-88).
    static func makeMember() throws -> WxMember {
        try WxMember(sourceID: "open-meteo", modelID: "ecmwf_ifs025", fetchedS: t0)
    }

    /// good_hour (src/core/test-core.c:62-77).
    static func goodHour(_ t: Int64) -> WxHour {
        var h = WxHour()
        h.tS = t
        h.tempC = 25.0
        h.feelsC = 27.0
        h.precipMm = 0.5
        h.precipProb = 40.0
        h.cloudPct = 60.0
        h.windKmh = 12.0
        h.gustKmh = 25.0
        h.humidityPct = 80.0
        h.wmo = 61
        return h
    }

    // C: /core/types/hour-init (src/core/test-core.c:484-500)
    @Test("/core/types/hour-init") func hourInit() {
        let h = WxHour()
        #expect(h.tS == 0)
        expectNaN(h.tempC)
        expectNaN(h.feelsC)
        expectNaN(h.precipMm)
        expectNaN(h.precipProb)
        expectNaN(h.cloudPct)
        expectNaN(h.windKmh)
        expectNaN(h.gustKmh)
        expectNaN(h.humidityPct)
        #expect(h.wmo == -1)
        // The NULL-argument critical (:497-499) is GLIB-INTERNAL.
    }

    // C: /core/types/member-new (src/core/test-core.c:509-550)
    @Test("/core/types/member-new") func memberNew() throws {
        let m = try Self.makeMember()
        #expect(m.sourceID == "open-meteo")
        #expect(m.modelID == "ecmwf_ifs025")
        #expect(m.fetchedS == Self.t0)
        #expect(m.hours.isEmpty)
        #expect(m.quarters.isEmpty)

        // bad_ids (:521-522); "x\n" is written as bytes.
        let badIDs: [[UInt8]?] = [
            nil, [], Array("Upper".utf8), Array("has space".utf8), Array("a/b".utf8),
            [0x78, 0x0A], Array("abcdefghijklmnopqrstuvwxyz0123456".utf8),
        ]
        for bad in badIDs {
            do {
                _ = try WxMember(sourceIDBytes: bad, modelIDBytes: Array("model".utf8), fetchedS: Self.t0)
                Issue.record("source id \(String(describing: bad)) was accepted")
            } catch {
                #expect(error.code == .invalidArg)
            }
            do {
                _ = try WxMember(sourceIDBytes: Array("src".utf8), modelIDBytes: bad, fetchedS: Self.t0)
                Issue.record("model id \(String(describing: bad)) was accepted")
            } catch {
                #expect(error.code == .invalidArg)
            }
        }
        // fetch time (:533-541): [WX_TIME_MIN_S, WX_TIME_MAX_S)
        for t: Int64 in [0, -1, WxLimits.timeMinS - 1, WxLimits.timeMaxS, Int64.max] {
            #expect(throws: WxError.self, "fetch time \(t)") {
                _ = try WxMember(sourceID: "s", modelID: "m", fetchedS: t)
            }
        }
        _ = try WxMember(sourceID: "s", modelID: "m", fetchedS: WxLimits.timeMinS)
        _ = try WxMember(sourceID: "s", modelID: "m", fetchedS: WxLimits.timeMaxS - 1)

        // the ids are private copies (:544-548)
        var src = "abc"
        let c = try WxMember(sourceID: src, modelID: "m", fetchedS: Self.t0)
        src = "zbc"
        #expect(c.sourceID == "abc")
        #expect(src == "zbc")
    }

    // C: /core/types/member-add-hour-rules (src/core/test-core.c:552-603)
    @Test("/core/types/member-add-hour-rules") func memberAddHourRules() throws {
        var m = try Self.makeMember()
        let h = Self.goodHour(Self.t0)
        Self.check(m.addHour(h), true)
        #expect(m.hours.count == 1)

        // duplicate and descending
        Self.check(m.addHour(h), false)
        Self.check(m.addHour(Self.goodHour(Self.t0 - 3600)), false)
        #expect(m.hours.count == 1)

        // not a multiple of 3600
        Self.check(m.addHour(Self.goodHour(Self.t0 + 3601)), false)
        Self.check(m.addHour(Self.goodHour(Self.t0 + 1800)), false)
        Self.check(m.addHour(Self.goodHour(Self.t0 + 3599)), false)
        #expect(m.hours.count == 1)

        // gaps are allowed
        Self.check(m.addHour(Self.goodHour(Self.t0 + 5 * 3600)), true)
        Self.check(m.addHour(Self.goodHour(Self.t0 + 6 * 3600)), true)
        #expect(m.hours.count == 3)

        // out of the plausible time range
        var m2 = try Self.makeMember()
        Self.check(m2.addHour(Self.goodHour(-3600)), false)
        Self.check(m2.addHour(Self.goodHour(0)), false)
        Self.check(m2.addHour(Self.goodHour(WxLimits.timeMaxS)), false)
        Self.check(m2.addHour(Self.goodHour(Int64.max - (Int64.max % 3600))), false)
        Self.check(m2.addHour(Self.goodHour(WxLimits.timeMinS)), true)
        #expect(m2.hours.count == 1)

        #expect(m.hours.map(\.tS) == [Self.t0, Self.t0 + 5 * 3600, Self.t0 + 6 * 3600])
    }

    // C: /core/types/member-add-hour-normalises (src/core/test-core.c:605-680)
    @Test("/core/types/member-add-hour-normalises") func memberAddHourNormalises() throws {
        var m = try Self.makeMember()
        Self.check(m.addHour(Self.goodHour(Self.t0)), true)
        #expect(m.hours[0].tempC == 25.0)
        #expect(m.hours[0].feelsC == 27.0)
        #expect(m.hours[0].precipMm == 0.5)
        #expect(m.hours[0].precipProb == 40.0)
        #expect(m.hours[0].cloudPct == 60.0)
        #expect(m.hours[0].windKmh == 12.0)
        #expect(m.hours[0].gustKmh == 25.0)
        #expect(m.hours[0].humidityPct == 80.0)
        #expect(m.hours[0].wmo == 61)

        // every field out of range -> NAN / -1; the element itself is still added
        var bad = Self.goodHour(Self.t0 + 3600)
        bad.tempC = 70.5
        bad.feelsC = -100.5
        bad.precipMm = -0.1
        bad.precipProb = 100.1
        bad.cloudPct = -1.0
        bad.windKmh = 500.1
        bad.gustKmh = -5.0
        bad.humidityPct = 1e9
        bad.wmo = 100
        Self.check(m.addHour(bad), true)
        let o = m.hours[1]
        expectNaN(o.tempC)
        expectNaN(o.feelsC)
        expectNaN(o.precipMm)
        expectNaN(o.precipProb)
        expectNaN(o.cloudPct)
        expectNaN(o.windKmh)
        expectNaN(o.gustKmh)
        expectNaN(o.humidityPct)
        #expect(o.wmo == -1)

        var inf = Self.goodHour(Self.t0 + 2 * 3600)
        inf.tempC = .infinity
        inf.feelsC = -.infinity
        inf.precipMm = .nan
        inf.wmo = -7
        Self.check(m.addHour(inf), true)
        expectNaN(m.hours[2].tempC)
        expectNaN(m.hours[2].feelsC)
        expectNaN(m.hours[2].precipMm)
        #expect(m.hours[2].wmo == -1)

        // limits are inclusive; wmo 0 and 99 survive
        var edge = Self.goodHour(Self.t0 + 3 * 3600)
        edge.tempC = -100.0
        edge.feelsC = 70.0
        edge.precipMm = 500.0
        edge.precipProb = 0.0
        edge.cloudPct = 100.0
        edge.windKmh = 500.0
        edge.gustKmh = 0.0
        edge.humidityPct = 100.0
        edge.wmo = 99
        Self.check(m.addHour(edge), true)
        #expect(m.hours[3].tempC == -100.0)
        #expect(m.hours[3].feelsC == 70.0)
        #expect(m.hours[3].precipMm == 500.0)
        #expect(m.hours[3].windKmh == 500.0)
        #expect(m.hours[3].wmo == 99)
        var zeroWMO = Self.goodHour(Self.t0 + 4 * 3600)
        zeroWMO.wmo = 0
        Self.check(m.addHour(zeroWMO), true)
        #expect(m.hours[4].wmo == 0)

        // the caller's struct is untouched
        #expect(bad.tempC == 70.5)
        #expect(bad.wmo == 100)
    }

    // C: /core/types/member-hour-cap-growth (src/core/test-core.c:682-700)
    // The cap is behavioural; the reallocation growth is C memory mechanics.
    @Test("/core/types/member-hour-cap-growth") func memberHourCap() throws {
        #expect(WxLimits.memberMaxHours == 400)  // src/core/test-core.c:154
        var m = try Self.makeMember()
        for i in 0..<WxLimits.memberMaxHours {
            var h = Self.goodHour(Self.t0 + Int64(i) * 3600)
            h.tempC = Double(i) * 0.01
            Self.check(m.addHour(h), true)
        }
        #expect(m.hours.count == WxLimits.memberMaxHours)
        Self.check(m.addHour(Self.goodHour(Self.t0 + Int64(WxLimits.memberMaxHours) * 3600)), false)
        #expect(m.hours.count == WxLimits.memberMaxHours)
        for i in 0..<WxLimits.memberMaxHours {
            #expect(m.hours[i].tS == Self.t0 + Int64(i) * 3600)
            expectNear(m.hours[i].tempC, Double(i) * 0.01, eps: 1e-12)
        }
    }

    // C: /core/types/member-quarters (src/core/test-core.c:820-865)
    @Test("/core/types/member-quarters") func memberQuarters() throws {
        let t0 = Self.t0
        var m = try Self.makeMember()
        let q = WxQuarter(tS: t0, precipMm: 0.0)
        Self.check(m.addQuarter(q), true)
        Self.check(m.addQuarter(q), false)  // duplicate
        Self.check(m.addQuarter(WxQuarter(tS: t0 - 900, precipMm: 0.1)), false)
        Self.check(m.addQuarter(WxQuarter(tS: t0 + 901, precipMm: 0.1)), false)
        Self.check(m.addQuarter(WxQuarter(tS: t0 + 450, precipMm: 0.1)), false)
        Self.check(m.addQuarter(WxQuarter(tS: t0 + 900, precipMm: .nan)), false)
        Self.check(m.addQuarter(WxQuarter(tS: t0 + 900, precipMm: -0.1)), false)
        Self.check(m.addQuarter(WxQuarter(tS: t0 + 900, precipMm: 500.1)), false)
        Self.check(m.addQuarter(WxQuarter(tS: t0 + 900, precipMm: .infinity)), false)
        Self.check(m.addQuarter(WxQuarter(tS: 0, precipMm: 0.1)), false)
        Self.check(m.addQuarter(WxQuarter(tS: WxLimits.timeMaxS, precipMm: 0.1)), false)
        #expect(m.quarters.count == 1)

        Self.check(m.addQuarter(WxQuarter(tS: t0 + 1800, precipMm: 500.0)), true)  // gap allowed, max inclusive
        #expect(m.quarters.count == 2)
        #expect(m.quarters[1].tS == t0 + 1800)
        #expect(m.quarters[1].precipMm == 500.0)

        #expect(WxLimits.memberMaxQuarters == 1536)  // src/core/test-core.c:155
        var big = try Self.makeMember()
        for i in 0..<WxLimits.memberMaxQuarters {
            Self.check(big.addQuarter(WxQuarter(tS: t0 + Int64(i) * 900, precipMm: Double(i) * 0.001)), true)
        }
        Self.check(big.addQuarter(WxQuarter(tS: t0 + Int64(WxLimits.memberMaxQuarters) * 900, precipMm: 0.0)), false)
        #expect(big.quarters.count == WxLimits.memberMaxQuarters)
        #expect(big.quarters[WxLimits.memberMaxQuarters - 1].tS == t0 + Int64(WxLimits.memberMaxQuarters - 1) * 900)
    }

    // Swift analogue of C: /core/types/member-shared-immutable
    // (src/core/test-core.c:747-818, GLIB-INTERNAL in C): a member handed out
    // is a value, so a later add by the builder never changes the reader's copy.
    @Test("/core/types/member-shared-immutable (value semantics)") func memberSharedImmutable() throws {
        var builder = try Self.makeMember()
        Self.check(builder.addHour(Self.goodHour(Self.t0)), true)
        let shared = builder
        Self.check(builder.addHour(Self.goodHour(Self.t0 + 3600)), true)
        Self.check(builder.addQuarter(WxQuarter(tS: Self.t0, precipMm: 0.1)), true)
        #expect(shared.hours.count == 1)
        #expect(shared.quarters.isEmpty)
        #expect(builder.hours.count == 2)
    }

    // C: /core/types/source-result (src/core/test-core.c:905-933)
    @Test("/core/types/source-result") func sourceResult() throws {
        var r = try WxSourceResult(providerID: "open-meteo")
        #expect(r.providerID == "open-meteo")
        #expect(r.members.isEmpty)
        r.members.append(try Self.makeMember())
        #expect(r.members.count == 1)
        // The reference-count lines (:916-921) and free(NULL) are GLIB-INTERNAL.
        _ = try WxSourceResult(providerID: "met-no")

        let bad: [String?] = [nil, "", "Open", "a b", "abcdefghijklmnopqrstuvwxyz0123456"]
        for id in bad {
            do {
                _ = try WxSourceResult(providerID: id)
                Issue.record("provider id \(String(describing: id)) was accepted")
            } catch {
                #expect(error.code == .invalidArg)
            }
        }
    }

    // C: /core/types/id-validation, member and source-result lines
    // (src/core/test-core.c:235-238): the id rule applies wherever an id is accepted.
    @Test("/core/types/id-validation (member, source result)") func idValidationApplied() {
        #expect(throws: WxError.self) { _ = try WxMember(sourceID: "..", modelID: "m", fetchedS: Self.t0) }
        #expect(throws: WxError.self) { _ = try WxMember(sourceID: "s", modelID: ".", fetchedS: Self.t0) }
        #expect(throws: WxError.self) { _ = try WxMember(sourceID: "s", modelID: "-m", fetchedS: Self.t0) }
        #expect(throws: WxError.self) { _ = try WxSourceResult(providerID: "..") }
    }

    // C: /core/types/time-range-edges, member lines (src/core/test-core.c:2503-2525)
    @Test("/core/types/time-range-edges (members)") func timeRangeEdgesMembers() throws {
        #expect(WxLimits.timeMinS % 3600 == 0)
        #expect(WxLimits.timeMaxS % 3600 == 0)
        #expect(WxLimits.timeMaxS % 900 == 0)
        var lo = try WxMember(sourceID: "s", modelID: "m", fetchedS: WxLimits.timeMinS)
        var hi = try WxMember(sourceID: "s", modelID: "m", fetchedS: WxLimits.timeMaxS - 1)
        #expect(throws: WxError.self) { _ = try WxMember(sourceID: "s", modelID: "m", fetchedS: WxLimits.timeMinS - 1) }
        #expect(throws: WxError.self) { _ = try WxMember(sourceID: "s", modelID: "m", fetchedS: WxLimits.timeMaxS) }
        var h = Self.goodHour(WxLimits.timeMinS)
        Self.check(lo.addHour(h), true)
        h.tS = WxLimits.timeMinS - 3600
        var lo2 = try Self.makeMember()
        Self.check(lo2.addHour(h), false)
        h.tS = WxLimits.timeMaxS - 3600
        Self.check(hi.addHour(h), true)
        h.tS = WxLimits.timeMaxS
        var hi2 = try Self.makeMember()
        Self.check(hi2.addHour(h), false)
        Self.check(lo.addQuarter(WxQuarter(tS: WxLimits.timeMinS, precipMm: 0.0)), true)
        Self.check(lo2.addQuarter(WxQuarter(tS: WxLimits.timeMinS - 900, precipMm: 0.0)), false)
        Self.check(hi.addQuarter(WxQuarter(tS: WxLimits.timeMaxS - 900, precipMm: 0.0)), true)
        Self.check(hi2.addQuarter(WxQuarter(tS: WxLimits.timeMaxS, precipMm: 0.0)), false)
    }

    // C: /core/types/error-messages-no-echo, member and source-result lines
    // (src/core/test-core.c:2423-2431)
    @Test("/core/types/error-messages-no-echo (member, source result)") func errorMessagesNoEcho() {
        let secret = "SECRETZZ"  // src/core/test-core.c:2400
        let attempts: [() throws -> Void] = [
            { () throws in _ = try WxMember(sourceID: secret, modelID: "m", fetchedS: Self.t0) },
            { () throws in _ = try WxMember(sourceID: "s", modelID: secret, fetchedS: Self.t0) },
            { () throws in _ = try WxSourceResult(providerID: secret) },
        ]
        for attempt in attempts {
            do {
                try attempt()
                Issue.record("an id with upper-case letters was accepted")
            } catch {
                #expect(error is WxError)
                #expect(!String(describing: error).contains(secret))
            }
        }
    }
}
