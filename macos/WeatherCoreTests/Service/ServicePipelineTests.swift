// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ServicePipelineTests.swift - port of the member-selection and
// error-precedence cases of src/service/test-service.c onto the pure
// ServicePipeline. Every test names its C g_test_add path; expected values are
// the C test's literals (test-service.c:LINE) or come from the C test's own
// oracle of the share rule (plan_forwarding, test-service.c:2868-2905), which
// is ported here and shares nothing with the code under test.
//
// The C tests run the whole service with fake providers and the blend. Here
// each provider's answer is handed to the pipeline as a Slot outcome, and
// what C reads off the blended forecast (n_members of an hour, a mark hour)
// is read off `Selection.results`, the blend's input. Where a C case needs
// the blend's own failure, the test passes the blend's documented error
// (WX_ERROR_NOT_FOUND "no usable forecast data", test-service.c:1108) to
// `failure(blendError:)`, exactly when the C case's blend gets members of
// fewer than WX_BLEND_MIN_HOURS (6, src/blend/wx-blend.h:30) hours.
//
// Not representable in Swift (see the U15 debrief): hand-built garbage
// members other than "no data" (WxMember is valid by construction), NULL
// member entries, a result together with an error, WX_ERROR codes outside
// the enum. The orchestration (timing, arrival order, cancellation, the
// blend's hours) is U26's.

import Foundation
import Testing
@testable import WeatherCore

@Suite(.timeLimit(.minutes(1)))
struct ServicePipelineTests {
    // MARK: - Helpers

    /// A fixed "now" (the C tests use the wall clock; the pipeline reads no time).
    private static let now: Int64 = 1_791_676_800
    private static let hourS: Int64 = 3600

    /// all_codes (test-service.c:978-980).
    private static let allCodes: [WxError.Code] = [
        .network, .timeout, .http, .rateLimited, .parse, .notFound, .invalidArg, .unsupported,
    ]

    /// code_rank (test-service.c:983-987): the documented ranking.
    private static func codeRank(_ code: WxError.Code) -> Int {
        switch code {
        case .network, .timeout: return 0
        case .rateLimited: return 1
        case .http: return 2
        case .parse: return 3
        case .notFound: return 4
        case .unsupported: return 5
        case .invalidArg: return 6
        }
    }

    /// FLOOR_TEXT and CAP_TEXT (test-service.c:1122-1123).
    private static let floorText = "a request for this place was sent less than 10 minutes ago"
    private static let capText = "too many outstanding requests (limit 16)"

    /// The blend's own error when no forwarded member has enough hours
    /// (test-service.c:1108).
    private static let blendNotFound = WxError(.notFound, "no usable forecast data")

    /// A serial that makes every member made here unique (in fetchedS), so a
    /// forwarded member can be told from another with the same ids.
    private final class Serial: @unchecked Sendable {
        private var value: Int64 = 0
        func next() -> Int64 {
            value += 1
            return value
        }
    }

    private let serial = Serial()

    /// make_member_n (test-service.c:91-111): `nHours` hours from an hour
    /// before now, every variable set, temperature `tempC`.
    private func member(_ source: String, _ model: String, _ tempC: Double, _ nHours: Int) throws -> WxMember {
        var member = try WxMember(sourceID: source, modelID: model, fetchedS: Self.now + serial.next())
        for i in 0..<nHours {
            let hour = WxHour(
                tS: Self.now / Self.hourS * Self.hourS - Self.hourS + Int64(i) * Self.hourS, tempC: tempC,
                feelsC: tempC, precipMm: 0.0, precipProb: 10.0, cloudPct: 40.0, windKmh: 10.0, gustKmh: 15.0,
                humidityPct: 50.0, wmo: 1)
            let added = member.addHour(hour)
        #expect(added)
        }
        return member
    }

    /// A member of one quarter and no hour (spec_add_quarters, test-service.c:2780-2788).
    private func quarterMember(_ source: String, _ model: String) throws -> WxMember {
        var member = try WxMember(sourceID: source, modelID: model, fetchedS: Self.now + serial.next())
        let added = member.addQuarter(WxQuarter(tS: Self.now / 900 * 900, precipMm: 0.5))
        #expect(added)
        return member
    }

    /// A member without hours or quarters (GB_NO_DATA, test-service.c:2660,2719;
    /// test-service.c:1355): valid for the blend, nothing to use.
    private func emptyMember(_ source: String, _ model: String) throws -> WxMember {
        try WxMember(sourceID: source, modelID: model, fetchedS: Self.now + serial.next())
    }

    /// A member with one hour at `tS` (spec_add_mark, test-service.c:2795-2808).
    private func markMember(_ source: String, _ model: String, _ tS: Int64) throws -> WxMember {
        var member = try WxMember(sourceID: source, modelID: model, fetchedS: Self.now + serial.next())
        let added = member.addHour(WxHour(tS: tS, tempC: 20.0, humidityPct: 50.0))
        #expect(added)
        return member
    }

    /// The initial status of a fake provider (FakeProvider's name, attribution and URL).
    private static func status(_ id: String) throws -> WxSourceStatus {
        try #require(
            ServicePipeline.initialStatus(
                providerID: id, name: "Fake \(id)", attribution: "Fake data (\(id))",
                attributionURL: "https://example.invalid/"))
    }

    /// A provider that answered `members`.
    private static func ok(_ id: String, _ members: [WxMember]) throws -> ServicePipeline.Slot {
        var result = try WxSourceResult(providerID: id)
        result.members = members
        return ServicePipeline.Slot(status: try status(id), outcome: .answered(result))
    }

    /// A provider that failed with `error`.
    private static func failed(_ id: String, _ error: any Error) throws -> ServicePipeline.Slot {
        ServicePipeline.Slot(status: try status(id), outcome: .failed(error))
    }

    /// wx_fake_provider_fail_with: WxError(code, "scripted failure").
    private static func scripted(_ id: String, _ code: WxError.Code) throws -> ServicePipeline.Slot {
        try failed(id, WxError(code, "scripted failure"))
    }

    private static func select(_ slots: [ServicePipeline.Slot]) -> ServicePipeline.Selection {
        ServicePipeline.select(slots, deadlineMs: 30000)
    }

    /// assert_status (state, error code or -1, n_members) of `selection.statuses[index]`.
    private static func expectStatus(
        _ selection: ServicePipeline.Selection, _ index: Int, _ id: String, _ state: WxSourceState,
        _ code: WxError.Code?, _ nMembers: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard index < selection.statuses.count else {
            Issue.record("no status \(index)", sourceLocation: sourceLocation)
            return
        }
        let s = selection.statuses[index]
        #expect(s.providerID == id, sourceLocation: sourceLocation)
        #expect(s.state == state, "\(id) state", sourceLocation: sourceLocation)
        #expect(s.errorCode == code, "\(id) error code", sourceLocation: sourceLocation)
        #expect(s.nMembers == UInt32(nMembers), "\(id) n_members", sourceLocation: sourceLocation)
    }

    /// The identity of a member made here: ids and the unique fetchedS.
    private struct Identity: Hashable {
        let source: String
        let model: String
        let fetchedS: Int64

        init(_ m: WxMember) {
            source = m.sourceID
            model = m.modelID
            fetchedS = m.fetchedS
        }
    }

    private static func forwarded(_ selection: ServicePipeline.Selection) -> [Identity] {
        selection.results.flatMap { $0.members.map(Identity.init) }
    }

    // MARK: - Refresh: duplicates, failures, error selection

    // C: /service/refresh/duplicate-members (test-service.c:930-972)
    @Test func refreshDuplicateMembers() throws {
        for swap in [false, true] {
            let low = try member("shared", "m", 10.0, 48)
            let high = try member("shared", "m", 60.0, 48)
            let sel = Self.select([try Self.ok("fake-a", [swap ? high : low]), try Self.ok("fake-b", [swap ? low : high])])
            Self.expectStatus(sel, 0, "fake-a", .ok, nil, 1)  // test-service.c:946
            Self.expectStatus(sel, 1, "fake-b", .ok, nil, 0)  // test-service.c:948
            #expect(sel.results.map(\.providerID) == ["fake-a"])
            #expect(sel.results.first?.members.first?.hours.first?.tempC == (swap ? 60.0 : 10.0))  // :951
        }
        // one provider returning the same pair twice (test-service.c:958-970)
        let low = try member("shared", "m", 10.0, 48)
        let high = try member("shared", "m", 60.0, 48)
        let sel = Self.select([try Self.ok("fake-a", [low, high])])
        Self.expectStatus(sel, 0, "fake-a", .ok, nil, 1)
        #expect(sel.results.first?.members.map(\.hours.first?.tempC) == [10.0])
    }

    // C: /service/refresh/one-fails (test-service.c:990-1018)
    @Test func refreshOneFails() throws {
        let sel = Self.select([
            try Self.ok("fake-a", [try member("fake-a", "m", 10.0, 48)]),
            try Self.scripted("fake-b", .network),
            try Self.ok("fake-c", [try member("fake-c", "m", 30.0, 48)]),
        ])
        #expect(sel.statuses.count == 3)
        Self.expectStatus(sel, 0, "fake-a", .ok, nil, 1)
        Self.expectStatus(sel, 1, "fake-b", .failed, .network, 0)
        Self.expectStatus(sel, 2, "fake-c", .ok, nil, 1)
        #expect(sel.results.map(\.providerID) == ["fake-a", "fake-c"])  // test-service.c:1014-1015
    }

    // C: /service/refresh/each-error-code (test-service.c:1022-1046)
    @Test(arguments: allCodes) func refreshEachErrorCode(code: WxError.Code) throws {
        let sel = Self.select([try Self.ok("fake-a", [try member("fake-a", "m", 10.0, 48)]), try Self.scripted("fake-b", code)])
        #expect(sel.statuses.count == 2)
        Self.expectStatus(sel, 0, "fake-a", .ok, nil, 1)
        if code == .unsupported {
            Self.expectStatus(sel, 1, "fake-b", .skipped, nil, 0)
        } else {
            Self.expectStatus(sel, 1, "fake-b", .failed, code, 0)
        }
        #expect(sel.results.map(\.providerID) == ["fake-a"])
    }

    // C: /service/refresh/all-fail-single (test-service.c:1050-1064)
    @Test(arguments: allCodes) func refreshAllFailSingle(code: WxError.Code) throws {
        let sel = Self.select([try Self.scripted("fake-a", code)])
        #expect(sel.results.isEmpty)
        #expect(sel.failure(blendError: nil) == .error(WxError(code, "fake-a: scripted failure")))
    }

    // C: /service/refresh/error-ranking (test-service.c:1068-1086)
    @Test func refreshErrorRanking() throws {
        for first in Self.allCodes {
            for second in Self.allCodes {
                let sel = Self.select([try Self.scripted("fake-a", first), try Self.scripted("fake-b", second)])
                let want = Self.codeRank(first) <= Self.codeRank(second)
                    ? WxError(first, "fake-a: scripted failure") : WxError(second, "fake-b: scripted failure")
                #expect(sel.failure(blendError: nil) == .error(want), "\(first) vs \(second)")
            }
        }
        // the rank function itself is the documented table (code_rank, test-service.c:983-987)
        for code in Self.allCodes {
            #expect(ServicePipeline.errorRank(code) == Self.codeRank(code), "\(code)")
        }
    }

    // C: /service/refresh/error-ranking-blend (test-service.c:1094-1111)
    @Test(arguments: allCodes) func refreshErrorRankingBlend(code: WxError.Code) throws {
        let sel = Self.select([try Self.ok("fake-a", [try member("fake-a", "m", 10.0, 5)]), try Self.scripted("fake-b", code)])
        Self.expectStatus(sel, 0, "fake-a", .ok, nil, 1)  // forwarded: the blend gets it and fails
        #expect(sel.results.map(\.providerID) == ["fake-a"])
        let want = Self.codeRank(code) <= Self.codeRank(.notFound)
            ? WxError(code, "fake-b: scripted failure") : Self.blendNotFound
        #expect(sel.failure(blendError: Self.blendNotFound) == .error(want))
    }

    // C: /service/refresh/local-refusal-ranks-last (test-service.c:1132-1186)
    @Test func refreshLocalRefusalRanksLast() throws {
        for text in [Self.floorText, Self.capText] {
            for code in Self.allCodes {
                // the refusing provider is registered FIRST (test-service.c:1139)
                let sel = Self.select([
                    try Self.failed("met-no", WxError(.rateLimited, text)), try Self.scripted("fake-b", code),
                ])
                #expect(sel.failure(blendError: nil) == .error(WxError(code, "fake-b: scripted failure")), "\(code)")
            }
            // all that remains: NOT_FOUND with the provider's message (test-service.c:1150-1159)
            let alone = Self.select([try Self.failed("met-no", WxError(.rateLimited, text))])
            #expect(alone.failure(blendError: nil) == .error(WxError(.notFound, "met-no: " + text)))
            Self.expectStatus(alone, 0, "met-no", .failed, .rateLimited, 0)
        }
        // next to a provider whose members the blend cannot use: the blend's error (:1163-1173)
        let short = Self.select([
            try Self.failed("met-no", WxError(.rateLimited, Self.floorText)),
            try Self.ok("fake-b", [try member("fake-b", "m", 10.0, 5)]),
        ])
        #expect(short.results.map(\.providerID) == ["fake-b"])
        #expect(short.failure(blendError: Self.blendNotFound) == .error(Self.blendNotFound))
        // next to a good provider: success, the refusal keeps its code (:1174-1185)
        let good = Self.select([
            try Self.failed("met-no", WxError(.rateLimited, Self.floorText)),
            try Self.ok("fake-b", [try member("fake-b", "m", 20.0, 48)]),
        ])
        Self.expectStatus(good, 0, "met-no", .failed, .rateLimited, 0)
        Self.expectStatus(good, 1, "fake-b", .ok, nil, 1)
        #expect(good.results.map(\.providerID) == ["fake-b"])
    }

    // C: /service/refresh/genuine-rate-limit-keeps-rank (test-service.c:1194-1220)
    @Test func refreshGenuineRateLimitKeepsRank() throws {
        let genuine = [
            "HTTP 429: rate limited", "requests are paused after HTTP 429",
            "NWS asked for fewer requests; waiting 5 seconds", "x " + Self.floorText, "the " + Self.capText, "",
        ]
        for text in genuine {
            let sel = Self.select([try Self.failed("met-no", WxError(.rateLimited, text)), try Self.scripted("fake-b", .http)])
            #expect(sel.failure(blendError: nil) == .error(WxError(.rateLimited, "met-no: " + text)), "\(text)")
        }
        // the refusal text under another code is an ordinary error of that code (:1210-1219)
        let sel = Self.select([try Self.failed("met-no", WxError(.http, Self.floorText)), try Self.scripted("fake-b", .parse)])
        #expect(sel.failure(blendError: nil) == .error(WxError(.http, "met-no: " + Self.floorText)))
    }

    // C: /service/refresh/blend-not-found (test-service.c:1224-1246)
    @Test func refreshBlendNotFound() throws {
        let a = try member("fake-a", "m", 10.0, 5)
        let b = try member("fake-b", "m", 20.0, 1)
        let sel = Self.select([try Self.ok("fake-a", [a]), try Self.ok("fake-b", [b])])
        #expect(sel.results.map(\.providerID) == ["fake-a", "fake-b"])  // both are forwarded
        #expect(sel.failure(blendError: Self.blendNotFound) == .error(WxError(.notFound, "no usable forecast data")))
        let withGood = Self.select([
            try Self.ok("fake-a", [a]), try Self.ok("fake-b", [b]), try Self.ok("fake-c", [try member("fake-c", "m", 30.0, 48)]),
        ])
        #expect(withGood.statuses.count == 3)
        Self.expectStatus(withGood, 0, "fake-a", .ok, nil, 1)
        Self.expectStatus(withGood, 1, "fake-b", .ok, nil, 1)
        Self.expectStatus(withGood, 2, "fake-c", .ok, nil, 1)
    }

    // C: /service/refresh/no-members (test-service.c:1250-1269)
    @Test func refreshNoMembers() throws {
        let bare = Self.select([try Self.ok("fake-b", [])])
        #expect(bare.results.isEmpty)
        #expect(bare.failure(blendError: nil) == .error(WxError(.notFound, "fake-b: the provider returned no forecast data")))
        let sel = Self.select([try Self.ok("fake-b", []), try Self.ok("fake-c", [try member("fake-c", "m", 20.0, 48)])])
        #expect(sel.statuses.count == 2)
        Self.expectStatus(sel, 0, "fake-b", .failed, .notFound, 0)
        Self.expectStatus(sel, 1, "fake-c", .ok, nil, 1)
    }

    /// check_bad_provider (test-service.c:1284-1317): `bad` ("bad-x") next to a
    /// good provider, then alone. `alone` nil = a forecast; `blendFails` = the
    /// alone blend gets only members it cannot use.
    private func checkBadProvider(
        _ bad: ServicePipeline.Slot, _ state: WxSourceState, _ code: WxError.Code?, _ nMembers: Int,
        alone: ServicePipeline.Failure?, blendFails: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let sel = Self.select([try Self.ok("fake-a", [try member("fake-a", "m", 20.0, 48)]), bad])
        #expect(sel.statuses.count == 2, sourceLocation: sourceLocation)
        Self.expectStatus(sel, 0, "fake-a", .ok, nil, 1, sourceLocation: sourceLocation)
        Self.expectStatus(sel, 1, "bad-x", state, code, nMembers, sourceLocation: sourceLocation)
        #expect(sel.results.map(\.providerID) == (state == .ok ? ["fake-a", "bad-x"] : ["fake-a"]),
                sourceLocation: sourceLocation)
        let lone = Self.select([bad])
        if let alone {
            let blendError = blendFails && !lone.results.isEmpty ? Self.blendNotFound : nil
            #expect(lone.failure(blendError: blendError) == alone, sourceLocation: sourceLocation)
        } else {
            #expect(!lone.results.isEmpty, "a forecast is blended", sourceLocation: sourceLocation)
        }
    }

    // C: /service/refresh/garbage-results (test-service.c:1326-1368)
    @Test func refreshGarbageResults() throws {
        // NULL without an error (:1328-1332)
        try checkBadProvider(
            ServicePipeline.Slot(status: try Self.status("bad-x"), outcome: .answered(nil)), .failed, .notFound, 0,
            alone: .error(WxError(.notFound, "bad-x: the provider returned no result")))
        // a result without members (:1334-1344: no members array / NULL entries only)
        try checkBadProvider(
            try Self.ok("bad-x", []), .failed, .notFound, 0,
            alone: .error(WxError(.notFound, "bad-x: the provider returned no forecast data")))
        // a real member (:1346-1351)
        try checkBadProvider(try Self.ok("bad-x", [try member("bad-x", "m", 30.0, 48)]), .ok, nil, 1, alone: nil)
        // a member without any hour or quarter does not count (:1353-1358)
        try checkBadProvider(
            try Self.ok("bad-x", [try emptyMember("bad-x", "m")]), .failed, .notFound, 0,
            alone: .error(WxError(.notFound, "bad-x: the provider returned no forecast data")))
        // quarters only count, but a lone one cannot make a forecast (:1360-1367)
        try checkBadProvider(
            try Self.ok("bad-x", [try quarterMember("bad-x", "m")]), .ok, nil, 1,
            alone: .error(WxError(.notFound, "no usable forecast data")), blendFails: true)
    }

    /// A foreign error with a fixed message (a GError of another domain).
    private struct ForeignError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    // C: /service/refresh/foreign-errors (test-service.c:1372-1413)
    @Test func refreshForeignErrors() throws {
        // another domain (:1374-1378)
        try checkBadProvider(
            try Self.failed("bad-x", ForeignError(text: "no such thing")), .failed, .network, 0,
            alone: .error(WxError(.network, "bad-x: no such thing")))
        // an error that is not a cancellation (:1380-1384)
        try checkBadProvider(
            try Self.failed("bad-x", ForeignError(text: "gio timeout")), .failed, .network, 0,
            alone: .error(WxError(.network, "bad-x: gio timeout")))
        // the platform's own timeout is not a cancellation either: NETWORK (its text is localised)
        let urlTimeout = Self.select([try Self.failed("bad-x", URLError(.timedOut))])
        guard case .error(let error) = urlTimeout.failure(blendError: nil) else {
            Issue.record("URLError(.timedOut) is not a WX_ERROR failure")
            return
        }
        #expect(error.code == .network)
        #expect(error.message.hasPrefix("bad-x: "))
        // a cancellation the provider reports itself (:1396-1400)
        try checkBadProvider(try Self.failed("bad-x", CancellationError()), .failed, nil, 0, alone: .cancelled)
        // control characters, a bidi override and invalid UTF-8 removed or replaced, cut at 200 bytes
        // (:1402-1412): the C bytes "ba" E2 80 AE "d" 07 FF + 300 x, decoded the only way a Swift
        // String can hold them (FF becomes U+FFFD)
        let hostile = String(decoding: [0x62, 0x61, 0xE2, 0x80, 0xAE, 0x64, 0x07, 0xFF] + [UInt8](repeating: 0x78, count: 300), as: UTF8.self)
        let want = String(decoding: Array("bad-x: bad".utf8) + [0xEF, 0xBF, 0xBD] + [UInt8](repeating: 0x78, count: 194), as: UTF8.self)
        try checkBadProvider(
            try Self.failed("bad-x", ForeignError(text: hostile)), .failed, .network, 0,
            alone: .error(WxError(.network, want)))
        // the same message inside a WxError is sanitised the same way (normalize_error, wx-service.c:181)
        let wx = Self.select([try Self.failed("bad-x", WxError(.parse, hostile))])
        #expect(wx.failure(blendError: nil) == .error(WxError(.parse, want)))
        #expect(Array(want.utf8).count == "bad-x: ".utf8.count + 200)
    }

    // C: /service/refresh/cancelled-providers (test-service.c:1441-1469)
    @Test func refreshCancelledProviders() throws {
        let cancelA = try Self.failed("cancel-a", CancellationError())
        let cancelB = try Self.failed("cancel-b", CancellationError())
        #expect(Self.select([cancelA, cancelB]).failure(blendError: nil) == .cancelled)
        #expect(ServicePipeline.Failure.cancelled.thrownError is CancellationError)
        let failing = Self.select([cancelA, cancelB, try Self.scripted("fake-c", .rateLimited)])
        #expect(failing.failure(blendError: nil) == .error(WxError(.rateLimited, "fake-c: scripted failure")))
        let sel = Self.select([cancelA, cancelB, try Self.ok("fake-c", [try member("fake-c", "m", 10.0, 48)])])
        Self.expectStatus(sel, 0, "cancel-a", .failed, nil, 0)
        Self.expectStatus(sel, 1, "cancel-b", .failed, nil, 0)
        Self.expectStatus(sel, 2, "fake-c", .ok, nil, 1)
    }

    // C: /service/refresh/source-fields (test-service.c:1473-1524): the status part (status_for)
    @Test func refreshSourceFields() throws {
        let nice = try #require(ServicePipeline.initialStatus(
            providerID: "prov-nice", name: "Nice Name", attribution: "Nice credit",
            attributionURL: "https://example.invalid/path?x=1"))
        #expect(nice.name == "Nice Name")
        #expect(nice.attribution == "Nice credit")
        #expect(nice.attributionURL == "https://example.invalid/path?x=1")
        // "A\x01" "B\xE2\x80\xAE" "C" (test-service.c:1485), as bytes
        let oddName = String(decoding: [0x41, 0x01, 0x42, 0xE2, 0x80, 0xAE, 0x43] as [UInt8], as: UTF8.self)
        let odd = try #require(ServicePipeline.initialStatus(
            providerID: "prov-odd", name: oddName, attribution: "", attributionURL: "http://insecure.invalid/"))
        #expect(odd.name == "ABC")
        #expect(odd.attribution == "")
        #expect(odd.attributionURL == "")  // rejected: replaced, the status is kept (:1519)
        #expect(odd.providerID == "prov-odd")
        // a provider whose id is not valid is neither fetched nor listed (:1500-1511)
        #expect(ServicePipeline.initialStatus(providerID: "BAD ID", name: "", attribution: "", attributionURL: "") == nil)
        let bare = try #require(ServicePipeline.initialStatus(providerID: "prov-bare", name: "", attribution: "", attributionURL: ""))
        #expect(bare.name == "")
        #expect(bare.attributionURL == "")
        for s in [nice, odd, bare] {
            #expect(s.state == .skipped && s.errorCode == nil && s.nMembers == 0)
        }
        // statuses keep their fields through the pipeline (:1512-1522)
        var result = try WxSourceResult(providerID: "prov-odd")
        result.members = [try member("prov-odd", "m", 11.0, 48)]
        let sel = Self.select([ServicePipeline.Slot(status: odd, outcome: .answered(result))])
        #expect(sel.statuses.first?.name == "ABC")
        #expect(sel.statuses.first?.attributionURL == "")
        Self.expectStatus(sel, 0, "prov-odd", .ok, nil, 1)
    }

    // A slot that was not fetched stays SKIPPED, -1, 0 (settle_slot, wx-service.c:616-617;
    // wx-service.h:94-95); a fetch without an answer is the deadline's TIMEOUT (wx-service.c:618-620).
    // C: /service/refresh/skipped (test-service.c:1527), status part
    @Test func refreshSkippedAndTimedOut() throws {
        let sel = ServicePipeline.select(
            [ServicePipeline.Slot(status: try Self.status("fake-a")),
             ServicePipeline.Slot(status: try Self.status("fake-b"), outcome: .noAnswer)],
            deadlineMs: 250)
        Self.expectStatus(sel, 0, "fake-a", .skipped, nil, 0)
        Self.expectStatus(sel, 1, "fake-b", .failed, .timeout, 0)
        #expect(sel.failure(blendError: nil) == .error(WxError(.timeout, "fake-b: no answer within 250 ms")))
    }

    // C: /service/refresh/limits (test-service.c:2597-2637), the member part
    @Test func refreshLimits() throws {
        var slots: [ServicePipeline.Slot] = []
        for i in 0..<WxRegistry.maxProviders {
            let id = String(format: "fake-%02d", i)
            slots.append(try Self.ok(id, [try member(id, "m", 10.0 + Double(i), 48)]))
        }
        let sel = Self.select(slots)
        #expect(sel.statuses.count == 16)
        for i in 0..<16 {
            Self.expectStatus(sel, i, String(format: "fake-%02d", i), .ok, nil, 1)
        }
        // one provider returning 200 members: 128 are forwarded and counted (:2623-2635)
        var big: [WxMember] = []
        for i in 0..<200 {
            big.append(try member("fake-big", "m\(i)", 10.0 + Double(i % 20), 48))
        }
        let many = Self.select([try Self.ok("fake-big", big)])
        Self.expectStatus(many, 0, "fake-big", .ok, nil, 128)
        #expect(many.results.first?.members.map(Identity.init) == big.prefix(128).map(Identity.init))
    }

    // Local refusal after normalisation: the prefix is matched on the sanitised message
    // (normalize_error then is_local_refusal, wx-service.c:181,258-261; wx-service.h:132-141)
    @Test func localRefusalMatchesNormalisedMessage() throws {
        let sel = Self.select([try Self.failed("met-no", WxError(.rateLimited, "\u{07}too many outstanding requests"))])
        #expect(sel.failure(blendError: nil) == .error(WxError(.notFound, "met-no: too many outstanding requests")))
        Self.expectStatus(sel, 0, "met-no", .failed, .rateLimited, 0)
        #expect(ServicePipeline.isLocalRefusal(WxError(.rateLimited, "too many outstanding requests")))
        #expect(!ServicePipeline.isLocalRefusal(WxError(.rateLimited, "too many outstanding request")))
        #expect(!ServicePipeline.isLocalRefusal(WxError(.notFound, Self.capText)))
        // a local refusal never outranks INVALID_ARG or UNSUPPORTED, the blend's error included
        let blend = Self.select([try Self.failed("met-no", WxError(.rateLimited, Self.capText))])
        #expect(blend.failure(blendError: WxError(.invalidArg, "x")) == .error(WxError(.invalidArg, "x")))
    }

    // MARK: - Share: usable, distinct, fair share (test-service.c:2639-3563)

    /// SpecMember (test-service.c:2737-2743), without the blend-only fields.
    private struct Spec {
        let member: WxMember
        let usable: Bool
        let longEnough: Bool
        let markT: Int64
    }

    private func hours(_ source: String, _ model: Int, _ tempC: Double, _ nHours: Int) throws -> Spec {
        // spec_add_hours (test-service.c:2771-2776); WX_BLEND_MIN_HOURS = 6 (src/blend/wx-blend.h:30)
        Spec(member: try member(source, String(format: "m%03d", model), tempC, nHours), usable: true,
             longEnough: nHours >= 6, markT: 0)
    }

    private func quarters(_ source: String, _ model: Int) throws -> Spec {
        Spec(member: try quarterMember(source, String(format: "m%03d", model)), usable: true, longEnough: false, markT: 0)
    }

    private func mark(_ source: String, _ model: Int, _ tS: Int64) throws -> Spec {
        Spec(member: try markMember(source, String(format: "m%03d", model), tS), usable: true, longEnough: false, markT: tS)
    }

    /// spec_add_garbage (test-service.c:2812-2816). GB_NO_DATA is the only
    /// kind a Swift WxMember can be.
    private func garbage(_ source: String, _ model: Int) throws -> Spec {
        Spec(member: try emptyMember(source, String(format: "m%03d", model)), usable: false, longEnough: false, markT: 0)
    }

    /// plan_forwarding (test-service.c:2868-2905): the documented rule in closed
    /// form. Returns per provider the number of usable members and the chosen ones.
    private static func plan(_ specs: [[Spec]]) -> [(nUsable: Int, chosen: [Identity], long: [Bool])] {
        func same(_ a: WxMember, _ b: WxMember) -> Bool { a.sourceID == b.sourceID && a.modelID == b.modelID }
        var distinct: [[Spec]] = Array(repeating: [], count: specs.count)
        var nUsable = [Int](repeating: 0, count: specs.count)
        for i in specs.indices {
            for entry in specs[i] where entry.usable {
                nUsable[i] += 1
                let listed = (0...i).contains { j in distinct[j].contains { same($0.member, entry.member) } }
                if !listed {
                    distinct[i].append(entry)
                }
            }
        }
        func cappedSum(_ cap: Int) -> Int { distinct.reduce(0) { $0 + min($1.count, cap) } }
        let longest = distinct.map(\.count).max() ?? 0
        var r = 0
        while r < longest && cappedSum(r + 1) <= 128 {
            r += 1
        }
        var used = cappedSum(r)
        return specs.indices.map { i in
            var share = min(distinct[i].count, r)
            if used < 128 && distinct[i].count > r {
                share += 1
                used += 1
            }
            let chosen = distinct[i].prefix(share)
            return (nUsable[i], chosen.map { Identity($0.member) }, chosen.map(\.longEnough))
        }
    }

    /// run_share + check_share (test-service.c:3015-3082): providers fake-00,
    /// fake-01, ... answering `specs`, checked against the plan.
    @discardableResult
    private static func runShare(_ specs: [[Spec]], sourceLocation: SourceLocation = #_sourceLocation) throws
        -> ServicePipeline.Selection
    {
        let ids = specs.indices.map { String(format: "fake-%02d", $0) }
        let sel = select(try specs.indices.map { try ok(ids[$0], specs[$0].map(\.member)) })
        let plans = plan(specs)
        #expect(sel.statuses.count == specs.count, sourceLocation: sourceLocation)
        for i in specs.indices {
            if plans[i].nUsable > 0 {
                expectStatus(sel, i, ids[i], .ok, nil, plans[i].chosen.count, sourceLocation: sourceLocation)
            } else {
                expectStatus(sel, i, ids[i], .failed, .notFound, 0, sourceLocation: sourceLocation)
            }
        }
        // the blend's input is exactly the chosen members, provider by provider (chosen_results, :2917-2933)
        let want = specs.indices.filter { !plans[$0].chosen.isEmpty }
        #expect(sel.results.map(\.providerID) == want.map { ids[$0] }, sourceLocation: sourceLocation)
        #expect(forwarded(sel) == want.flatMap { plans[$0].chosen }, sourceLocation: sourceLocation)
        // no long member forwarded: the refresh fails, a provider's NOT_FOUND beats the blend's (:3032-3037)
        if !plans.contains(where: { $0.long.contains(true) }) {
            let firstFailed = plans.firstIndex { $0.nUsable == 0 }
            let message = firstFailed.map { "\(ids[$0]): the provider returned no forecast data" }
                ?? "no usable forecast data"
            let blendError = sel.results.isEmpty ? nil : blendNotFound
            #expect(sel.failure(blendError: blendError) == .error(WxError(.notFound, message)),
                    sourceLocation: sourceLocation)
        }
        return sel
    }

    // C: /service/share/big-provider-first (test-service.c:3089-3110)
    @Test func shareBigProviderFirst() throws {
        let a = try (0..<128).map { try hours("fake-a", $0, 10.0, 1) }
        let b = [try hours("fake-b", 0, 30.0, 48)]
        let sel = try Self.runShare([a, b])
        Self.expectStatus(sel, 0, "fake-00", .ok, nil, 127)
        Self.expectStatus(sel, 1, "fake-01", .ok, nil, 1)
        #expect(Self.forwarded(sel).count == 128)  // n_members of the first hour (:3104)
    }

    // C: /service/share/unusable-members (test-service.c:3118-3145), kind GB_NO_DATA
    @Test(arguments: [127, 128, 129, 400]) func shareUnusableMembers(count: Int) throws {
        var a = try (0..<count).map { try garbage("fake-a", $0) }
        a.append(try hours("fake-a", 900, 10.0, 48))  // the real one, last
        let b = [try hours("fake-b", 0, 30.0, 48)]
        let d = try (0..<3).map { try garbage("fake-d", $0) }
        let sel = try Self.runShare([a, b, d])
        Self.expectStatus(sel, 0, "fake-00", .ok, nil, 1)
        Self.expectStatus(sel, 1, "fake-01", .ok, nil, 1)
        Self.expectStatus(sel, 2, "fake-02", .failed, .notFound, 0)
        #expect(Self.forwarded(sel) == [Identity(a[count].member), Identity(b[0].member)])  // both blended (:3140)
    }

    // C: /service/share/quarters-only (test-service.c:3149-3163)
    @Test func shareQuartersOnly() throws {
        let a = try (0..<200).map { try quarters("fake-a", $0) }
        let sel = try Self.runShare([a, [try hours("fake-b", 0, 30.0, 48)]])
        Self.expectStatus(sel, 0, "fake-00", .ok, nil, 127)
        Self.expectStatus(sel, 1, "fake-01", .ok, nil, 1)
    }

    // C: /service/share/many-providers (test-service.c:3173-3217); rows :3175-3193
    @Test func shareManyProviders() throws {
        let rows: [(lens: [Int], want: [Int])] = [
            ([200, 1], [127, 1]),
            ([1, 200], [1, 127]),
            ([128, 128], [64, 64]),
            ([129, 1], [127, 1]),
            ([128, 1], [127, 1]),
            ([127, 1], [127, 1]),
            ([5, 300, 5], [5, 118, 5]),
            ([0, 50, 0, 200], [0, 50, 0, 78]),
            ([10, 20, 30, 40, 50, 60, 70, 80], [10, 17, 17, 17, 17, 17, 17, 16]),
            (Array(repeating: 8, count: 16), Array(repeating: 8, count: 16)),
            (Array(repeating: 9, count: 16), Array(repeating: 8, count: 16)),
            (Array(repeating: 200, count: 16), Array(repeating: 8, count: 16)),
            (Array(1...16), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13, 12, 12]),
        ]
        for row in rows {
            let specs = try row.lens.indices.map { i in
                try (0..<row.lens[i]).map { m in
                    try hours(String(format: "fake-%02d", i), m, 5.0 + 0.05 * Double(m) + 0.5 * Double(i), 48)
                }
            }
            let sel = try Self.runShare(specs)
            for i in row.lens.indices {
                #expect(sel.statuses[i].nMembers == UInt32(row.want[i]), "row \(row.lens) provider \(i)")
                #expect(sel.statuses[i].state == (row.lens[i] > 0 ? .ok : .failed))
            }
            #expect(Self.forwarded(sel).count == row.want.reduce(0, +), "row \(row.lens)")  // max_members (:3213)
        }
    }

    // C: /service/share/duplicates (test-service.c:3221-3307)
    @Test func shareDuplicates() throws {
        // fake-b repeats all of fake-a's 128 pairs, then answers one of its own (:3223-3240)
        do {
            let a = try (0..<128).map { try hours("shared", $0, 10.0 + 0.05 * Double($0), 48) }
            var b = try (0..<128).map { try hours("shared", $0, 50.0, 48) }
            b.append(try hours("own", 0, 30.0, 48))
            let sel = try Self.runShare([a, b])
            Self.expectStatus(sel, 0, "fake-00", .ok, nil, 127)
            Self.expectStatus(sel, 1, "fake-01", .ok, nil, 1)
            #expect(Self.forwarded(sel).count == 128)
            #expect(sel.results.last?.members.map(\.sourceID) == ["own"])
        }
        // a duplicate stays dropped when the member it duplicates is cut by the share (:3242-3256)
        do {
            let a = try (0..<200).map { try hours("shared", $0, 10.0 + 0.05 * Double($0), 48) }
            let sel = try Self.runShare([a, [try hours("shared", 199, 50.0, 48)]])
            Self.expectStatus(sel, 0, "fake-00", .ok, nil, 128)
            Self.expectStatus(sel, 1, "fake-01", .ok, nil, 0)
            #expect(sel.results.map(\.providerID) == ["fake-00"])
        }
        // copies inside one provider (:3258-3275)
        do {
            var a = try (0..<127).map { try hours("shared", $0, 10.0 + 0.05 * Double($0), 48) }
            a += try (0..<5).map { _ in try hours("shared", 0, 60.0, 48) }
            let sel = try Self.runShare([a, [try hours("own", 0, 30.0, 48)]])
            Self.expectStatus(sel, 0, "fake-00", .ok, nil, 127)
            Self.expectStatus(sel, 1, "fake-01", .ok, nil, 1)
            #expect(Self.forwarded(sel).count == 128)
        }
        // a member dropped as unusable shadows nothing (:3277-3306), kind GB_NO_DATA
        do {
            let a = [try garbage("shared", 0), try hours("fake-a", 0, 10.0, 48)]
            let b = [try hours("shared", 0, 30.0, 48)]
            let sel = try Self.runShare([a, b])
            Self.expectStatus(sel, 0, "fake-00", .ok, nil, 1)
            Self.expectStatus(sel, 1, "fake-01", .ok, nil, 1)
            #expect(Self.forwarded(sel) == [Identity(a[1].member), Identity(b[0].member)])
        }
    }

    // C: /service/share/many-copies (test-service.c:3315-3343)
    @Test func shareManyCopies() throws {
        let same = try member("shared", "m000", 10.0, 48)
        var a = [WxMember](repeating: same, count: 200_000)
        for m in 1..<127 {
            a.append(try member("shared", String(format: "m%03d", m), 10.0 + 0.05 * Double(m), 48))
        }
        let own = try member("own", "m000", 30.0, 48)
        let sel = Self.select([try Self.ok("fake-00", a), try Self.ok("fake-01", [same]), try Self.ok("fake-02", [own])])
        Self.expectStatus(sel, 0, "fake-00", .ok, nil, 127)
        Self.expectStatus(sel, 1, "fake-01", .ok, nil, 0)
        Self.expectStatus(sel, 2, "fake-02", .ok, nil, 1)
        #expect(Self.forwarded(sel).count == 128)
    }

    /// mark_origin (test-service.c:3346-3350).
    private static let markOrigin = now / hourS * hourS - hourS + 48 * hourS

    /// check_marks (test-service.c:3357-3376): the forwarded marks are exactly
    /// the plan's; returns how many marks were forwarded.
    private static func checkMarks(_ sel: ServicePipeline.Selection, _ specs: [[Spec]],
                                   sourceLocation: SourceLocation = #_sourceLocation) -> Int {
        let plans = plan(specs)
        let sent = Set(forwarded(sel))
        var n = 0
        for i in specs.indices {
            let chosen = Set(plans[i].chosen)
            for entry in specs[i] where entry.markT != 0 {
                let id = Identity(entry.member)
                #expect(sent.contains(id) == chosen.contains(id), "mark \(entry.markT)", sourceLocation: sourceLocation)
                n += chosen.contains(id) ? 1 : 0
            }
        }
        return n
    }

    private func baseSpec() throws -> [Spec] { [try hours("fake-base", 0, 20.0, 48)] }  // :3379-3385

    // C: /service/share/exact-sets (test-service.c:3393-3472)
    @Test func shareExactSets() throws {
        let t0 = Self.markOrigin
        // 128 + 64 distinct marks and the base member: 1 + 64 + 63 are dealt (:3397-3413)
        do {
            let a = try (0..<128).map { try mark("src-a", $0, t0 + Int64($0) * Self.hourS) }
            let b = try (0..<64).map { try mark("src-b", $0, t0 + Int64(128 + $0) * Self.hourS) }
            let specs = [try baseSpec(), a, b]
            let sel = try Self.runShare(specs)
            #expect(Self.checkMarks(sel, specs) == 127)
            Self.expectStatus(sel, 0, "fake-00", .ok, nil, 1)
            Self.expectStatus(sel, 1, "fake-01", .ok, nil, 64)
            Self.expectStatus(sel, 2, "fake-02", .ok, nil, 63)
        }
        // fake-b repeats m050 .. m099 of fake-a (:3415-3432)
        do {
            let a = try (0..<100).map { try mark("shared", $0, t0 + Int64($0) * Self.hourS) }
            let b = try (0..<90).map { try mark("shared", 50 + $0, t0 + Int64(100 + $0) * Self.hourS) }
            let specs = [try baseSpec(), a, b]
            let sel = try Self.runShare(specs)
            #expect(Self.checkMarks(sel, specs) == 127)
            Self.expectStatus(sel, 0, "fake-00", .ok, nil, 1)
            Self.expectStatus(sel, 1, "fake-01", .ok, nil, 87)
            Self.expectStatus(sel, 2, "fake-02", .ok, nil, 40)
        }
        // every other member of fake-a is garbage: it takes no place (:3434-3452)
        do {
            var a: [Spec] = []
            for m in 0..<100 {
                a.append(try mark("src-a", m, t0 + Int64(m) * Self.hourS))
                a.append(try garbage("junk", m))
            }
            let b = try (0..<90).map { try mark("src-b", $0, t0 + Int64(100 + $0) * Self.hourS) }
            let specs = [try baseSpec(), a, b]
            let sel = try Self.runShare(specs)
            #expect(Self.checkMarks(sel, specs) == 127)
            Self.expectStatus(sel, 0, "fake-00", .ok, nil, 1)
            Self.expectStatus(sel, 1, "fake-01", .ok, nil, 64)
            Self.expectStatus(sel, 2, "fake-02", .ok, nil, 63)
        }
        // 130 members without data, then 5 marks, next to a provider with 5 marks (:3454-3471)
        do {
            var a = try (0..<130).map { try garbage("junk", $0) }
            a += try (0..<5).map { try mark("src-a", $0, t0 + Int64($0) * Self.hourS) }
            let b = try (0..<5).map { try mark("src-b", $0, t0 + Int64(5 + $0) * Self.hourS) }
            let specs = [try baseSpec(), a, b]
            let sel = try Self.runShare(specs)
            #expect(Self.checkMarks(sel, specs) == 10)
            Self.expectStatus(sel, 1, "fake-01", .ok, nil, 5)
            Self.expectStatus(sel, 2, "fake-02", .ok, nil, 5)
        }
    }

    // C: /service/share/exact-random (test-service.c:3476-3513); SeededRNG replaces g_test_rand
    @Test func shareExactRandom() throws {
        var rng = SeededRNG(seed: 0x5E_4A1C_E15)
        let t0 = Self.markOrigin
        for _ in 0..<fuzzIterations(40) {
            let n = Int.random(in: 2..<9, using: &rng)
            let nModels = Bool.random(using: &rng) ? 20 : 200
            var specs = [try baseSpec()]
            var nMarks = 0
            for _ in 1..<n {
                var spec: [Spec] = []
                let len = Int.random(in: 0..<3, using: &rng) == 0
                    ? Int.random(in: 0..<8, using: &rng) : Int.random(in: 20..<130, using: &rng)
                for _ in 0..<len {
                    let source = ["src-a", "src-b", "src-c"][Int.random(in: 0..<3, using: &rng)]
                    let model = Int.random(in: 0..<nModels, using: &rng)
                    let roll = Int.random(in: 0..<100, using: &rng)
                    if roll < 70 && nMarks < 190 {
                        spec.append(try mark(source, model, t0 + Int64(nMarks) * Self.hourS))
                        nMarks += 1
                    } else if roll < 85 {
                        spec.append(try garbage(source, model))
                    } else if roll < 95 {
                        spec.append(try hours(source, model, 25.0, 48))
                    } else {
                        spec.append(try quarters(source, model))
                    }
                }
                specs.append(spec)
            }
            let sel = try Self.runShare(specs)
            _ = Self.checkMarks(sel, specs)
        }
    }

    // C: /service/share/random (test-service.c:3516-3563); SeededRNG replaces g_test_rand
    @Test func shareRandom() throws {
        var rng = SeededRNG(seed: 0x5A_4E_D0_0D)
        for _ in 0..<fuzzIterations(60) {
            let n = Int.random(in: 1..<9, using: &rng)
            let nModels = Bool.random(using: &rng) ? 12 : 400
            var specs: [[Spec]] = []
            for _ in 0..<n {
                let roll = Int.random(in: 0..<10, using: &rng)
                let len = roll == 0 ? 0
                    : roll < 5 ? Int.random(in: 1..<20, using: &rng)
                    : roll < 8 ? Int.random(in: 20..<130, using: &rng)
                    : Int.random(in: 120..<261, using: &rng)
                var spec: [Spec] = []
                for _ in 0..<len {  // random_member (:3517-3534)
                    let source = ["src-a", "src-b", "src-c"][Int.random(in: 0..<3, using: &rng)]
                    let model = Int.random(in: 0..<nModels, using: &rng)
                    let tempC = 10.0 + Double(Int.random(in: 0..<25, using: &rng))
                    let r = Int.random(in: 0..<100, using: &rng)
                    if r < 55 {
                        spec.append(try hours(source, model, tempC, 48))
                    } else if r < 65 {
                        spec.append(try hours(source, model, tempC, 3))
                    } else if r < 72 {
                        spec.append(try hours(source, model, tempC, 1))
                    } else if r < 80 {
                        spec.append(try quarters(source, model))
                    } else {
                        spec.append(try garbage(source, model))
                    }
                }
                specs.append(spec)
            }
            try Self.runShare(specs)
        }
    }
}
