// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ServicePipeline.swift - the pure stages of one refresh of the forecast
// service: what happens between "every fetch has answered (or the deadline
// expired)" and "the blend is called / the refresh fails". Port of
// src/service/wx-service.c: normalize_error (:174-190), error_rank (:212-232),
// is_local_refusal (:255-262), member_usable (:501-517), collect_usable
// (:582-594), settle_slot (:613-632), pick_error (:656-678), select_members
// (:704-744), the result recording of on_child_done (:946-977), status_for
// (:999-1011) and the result assembly of build_forecast (:765-794), following
// the contract of src/service/wx-service.h:45-151.
//
// The asynchronous orchestration (fan-out, deadline, cancellation, the blend
// call itself) is not here; it drives these functions:
//   1. one `Slot` per listed provider with a valid id, in registration order
//      (`initialStatus(for:)`; nil = the provider is ignored), `outcome` nil
//      for a provider that was not fetched;
//   2. `select(_:deadlineMs:)` once every fetch has answered or the deadline
//      expired (`.noAnswer` for the ones that did not);
//   3. when `results` is not empty, blend them (with `statuses`); when there
//      is no forecast, the refresh error is `failure(blendError:)` (nil when
//      the blend was not called).
//
// Differences that follow from the Swift types (all unreachable states):
// WxMember is valid by construction (ids, hour stamps and counts are checked
// when it is built), so the blend-validity half of member_usable can only
// fail for a member C would have to hand-build; it is still checked, in the C
// order. A [WxMember] holds no NULL entry (drop_null_members). A provider's
// fetch either returns or throws, so "a result and an error" cannot occur;
// "a NULL result without an error" is `.answered(nil)`. WxError.Code holds
// only WxError values, so "a WX_ERROR code that is not a WxError value"
// cannot occur; every error that is neither WxError nor CancellationError
// counts as WX_ERROR_NETWORK with its localizedDescription as the message.

import Foundation

/// The pure member pipeline and error ranking of the forecast service
/// (src/service/wx-service.h:45-151).
public enum ServicePipeline {
    /// WX_BLEND_MAX_MEMBERS (src/blend/wx-blend.h:26): the most members the
    /// blend takes, and so the most the service forwards.
    public static let blendMaxMembers = 128

    /// MESSAGE_MAX (src/service/wx-service.c:26): longest provider message
    /// kept in a service error, bytes (after sanitising).
    public static let messageMax = 200

    /// LOCAL_REFUSAL_RANK (src/service/wx-service.c:193): after every rank of
    /// `errorRank(_:)`.
    static let localRefusalRank = 7

    /// The two message prefixes of a provider's local refusal
    /// (src/service/wx-service.c:259-261).
    static let localRefusalPrefixes = [
        "a request for this place was sent less than 10 minutes ago",
        "too many outstanding requests",
    ]

    /// The messages of the failures the service makes up itself
    /// (src/service/wx-service.c:965, :975).
    static let noResultMessage = "the provider returned no result"
    static let noDataMessage = "the provider returned no forecast data"

    // MARK: - Types

    /// A normalised failure (normalize_error): a cancellation the provider
    /// reported itself, or a WX_ERROR error with a sanitised message. Also
    /// the refresh error picked by `Selection.failure(blendError:)`.
    public enum Failure: Error, Equatable, Hashable, Sendable {
        /// G_IO_ERROR_CANCELLED ("operation was cancelled").
        case cancelled
        /// A WX_ERROR error.
        case error(WxError)

        /// The error to throw: `CancellationError()` or the WxError.
        public var thrownError: any Error {
            switch self {
            case .cancelled:
                return CancellationError()
            case .error(let error):
                return error
            }
        }
    }

    /// How one started fetch ended (what on_child_done / settle_slot see).
    public enum FetchOutcome: Sendable {
        /// The fetch returned. nil is "a NULL result without an error" (the
        /// provider interface forbids it).
        case answered(WxSourceResult?)
        /// The fetch threw `error` (normalised by `normalize(_:)`).
        case failed(any Error)
        /// No answer before the deadline: WX_ERROR_TIMEOUT
        /// "no answer within <deadline> ms".
        case noAnswer
    }

    /// One listed provider of one refresh (Slot, src/service/wx-service.c:269-279).
    public struct Slot: Sendable {
        /// The provider's initial status (`initialStatus(for:)`: SKIPPED, no
        /// error, 0 members).
        public let status: WxSourceStatus
        /// nil when the provider was not fetched (disabled or not covering).
        public var outcome: FetchOutcome?

        public init(status: WxSourceStatus, outcome: FetchOutcome? = nil) {
            self.status = status
            self.outcome = outcome
        }
    }

    /// What `select(_:deadlineMs:)` decided.
    public struct Selection: Sendable {
        /// The final status of every slot, in slot (registration) order:
        /// state and error code per settle_slot, nMembers = the members
        /// forwarded to the blend.
        public let statuses: [WxSourceStatus]
        /// The blend's input: one result per provider that has a member
        /// forwarded, in registration order, holding exactly the forwarded
        /// members in the provider's own order (providerID = the result's).
        public let results: [WxSourceResult]
        /// The normalised failure of every slot (nil: not fetched, or OK).
        public let failures: [Failure?]

        /// pick_error (src/service/wx-service.c:656-678): the error of a
        /// refresh without a forecast. The most informative WX_ERROR among the
        /// slots' failures (UNSUPPORTED included), the earlier slot on a tie;
        /// `blendError` (the blend's own error, nil when the blend was not
        /// called) replaces it only when it ranks strictly better. A local
        /// refusal ranks after everything and is reported as NOT_FOUND. A
        /// slot's error reads "<provider id>: <message>"; the blend's is
        /// returned as it is. `.cancelled` when no WX_ERROR failure and no
        /// blend error exist (every covering provider cancelled itself).
        public func failure(blendError: WxError?) -> Failure {
            var best: (index: Int, error: WxError)?
            var bestRank = Int.max
            for (i, failure) in failures.enumerated() {
                guard case .error(let error)? = failure else {
                    continue
                }
                let rank = ServicePipeline.isLocalRefusal(error)
                    ? ServicePipeline.localRefusalRank : ServicePipeline.errorRank(error.code)
                if rank < bestRank {
                    best = (i, error)
                    bestRank = rank
                }
            }
            if let blendError, ServicePipeline.errorRank(blendError.code) < bestRank {
                return .error(blendError)
            }
            if let best {
                let code = bestRank == ServicePipeline.localRefusalRank ? .notFound : best.error.code
                return .error(WxError(code, "\(statuses[best.index].providerID): \(best.error.message)"))
            }
            return .cancelled
        }
    }

    // MARK: - Statuses

    /// status_for (src/service/wx-service.c:999-1011): the initial (SKIPPED,
    /// no error, 0 members) status of a provider; an attribution URL that
    /// WxSourceStatus rejects is replaced by "". nil when the id is not a
    /// valid source id: such a provider is neither fetched nor listed.
    public static func initialStatus(
        providerID: String, name: String, attribution: String, attributionURL: String
    ) -> WxSourceStatus? {
        if let status = try? WxSourceStatus(
            providerID: providerID, name: name, attribution: attribution,
            attributionURL: attributionURL, state: .skipped, errorCode: nil, nMembers: 0)
        {
            return status
        }
        return try? WxSourceStatus(
            providerID: providerID, name: name, attribution: attribution, attributionURL: "",
            state: .skipped, errorCode: nil, nMembers: 0)
    }

    /// `initialStatus(providerID:name:attribution:attributionURL:)` of the
    /// provider's id, name, attribution and URL, read once, in that order.
    public static func initialStatus(for provider: any WxProvider) -> WxSourceStatus? {
        let id = provider.id
        let name = provider.name
        let attribution = provider.attribution
        let url = provider.attributionURL
        return initialStatus(providerID: id, name: name, attribution: attribution, attributionURL: url)
    }

    // MARK: - Errors

    /// normalize_error (src/service/wx-service.c:174-190): a CancellationError
    /// stays a cancellation; a WxError keeps its code; every other error is
    /// WX_ERROR_NETWORK. The message (the WxError's, else the error's
    /// localizedDescription) is passed through `WxText.sanitize` with
    /// `messageMax` bytes.
    public static func normalize(_ error: any Error) -> Failure {
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? WxError {
            return .error(WxError(error.code, WxText.sanitize(error.message, maxBytes: messageMax)))
        }
        return .error(WxError(.network, WxText.sanitize(error.localizedDescription, maxBytes: messageMax)))
    }

    /// error_rank (src/service/wx-service.c:212-232): 0 NETWORK and TIMEOUT,
    /// 1 RATE_LIMITED, 2 HTTP, 3 PARSE, 4 NOT_FOUND, 5 UNSUPPORTED, 6 the
    /// rest (INVALID_ARG). Smaller is more informative.
    static func errorRank(_ code: WxError.Code) -> Int {
        switch code {
        case .network, .timeout:
            return 0
        case .rateLimited:
            return 1
        case .http:
            return 2
        case .parse:
            return 3
        case .notFound:
            return 4
        case .unsupported:
            return 5
        case .invalidArg:
            return 6
        }
    }

    /// is_local_refusal (src/service/wx-service.c:255-262): a RATE_LIMITED
    /// error whose (normalised) message begins with one of the two texts a
    /// provider gives when it refuses without any network traffic. The
    /// comparison is byte-wise, like g_str_has_prefix.
    static func isLocalRefusal(_ error: WxError) -> Bool {
        guard error.code == .rateLimited else {
            return false
        }
        let message = Array(error.message.utf8)
        return localRefusalPrefixes.contains { message.starts(with: $0.utf8) }
    }

    // MARK: - Members

    /// member_usable (src/service/wx-service.c:501-517): the blend would let
    /// the member take part (valid ids, at most memberMaxHours hours, every
    /// stamp in [timeMinS, timeMaxS), a multiple of 3600 and after the one
    /// before) AND it has an hour, or 1...memberMaxQuarters quarters (the
    /// quarters themselves are not examined).
    static func isUsable(_ member: WxMember) -> Bool {
        if !WxLimits.isValidID(member.sourceID) || !WxLimits.isValidID(member.modelID) {
            return false
        }
        if member.hours.count > WxLimits.memberMaxHours {
            return false
        }
        for i in member.hours.indices {
            let t = member.hours[i].tS
            if t < WxLimits.timeMinS || t >= WxLimits.timeMaxS || t % 3600 != 0
                || (i > 0 && t <= member.hours[i - 1].tS)
            {
                return false
            }
        }
        return !member.hours.isEmpty
            || (!member.quarters.isEmpty && member.quarters.count <= WxLimits.memberMaxQuarters)
    }

    /// The (source id, model id) pair that makes two members "the same"
    /// (member_id_equal: both ids equal byte for byte; ids are ASCII).
    private struct MemberKey: Hashable {
        let sourceID: [UInt8]
        let modelID: [UInt8]

        init(_ member: WxMember) {
            sourceID = Array(member.sourceID.utf8)
            modelID = Array(member.modelID.utf8)
        }
    }

    // MARK: - The pipeline

    /// Records every slot's outcome (on_child_done), settles it (settle_slot),
    /// chooses the members for the blend (select_members: usable, distinct,
    /// fair share of `blendMaxMembers`) and builds the final statuses and the
    /// blend's input (build_forecast). `deadlineMs` is the deadline the
    /// refresh started with (the message of a `.noAnswer` slot).
    public static func select(_ slots: [Slot], deadlineMs: UInt32) -> Selection {
        var failures: [Failure?] = []
        var answers: [WxSourceResult?] = []  // the result of a slot with a usable member
        var forward: [[WxMember]?] = []  // nil exactly when answers[i] is nil
        failures.reserveCapacity(slots.count)
        for slot in slots {
            var failure: Failure?
            var answer: WxSourceResult?
            var usable: [WxMember]?
            switch slot.outcome {
            case nil:
                break
            case .noAnswer:
                failure = .error(WxError(.timeout, "no answer within \(deadlineMs) ms"))
            case .failed(let error):
                failure = normalize(error)
            case .answered(nil):
                failure = .error(WxError(.notFound, noResultMessage))
            case .answered(let result?):
                let members = result.members.filter(isUsable)  // collect_usable
                if members.isEmpty {
                    failure = .error(WxError(.notFound, noDataMessage))
                } else {
                    answer = result
                    usable = members
                }
            }
            failures.append(failure)
            answers.append(answer)
            forward.append(usable)
        }

        // Distinct: walking the slots in order and each list in its own order,
        // a pair seen before is dropped, whether or not its first occurrence
        // is forwarded in the end.
        var seen = Set<MemberKey>()
        for i in forward.indices {
            guard let list = forward[i] else {
                continue
            }
            var distinct: [WxMember] = []
            for member in list where seen.insert(MemberKey(member)).inserted {
                distinct.append(member)
            }
            forward[i] = distinct
        }

        // Share: one member at a time to every slot that still has one, in
        // order, until blendMaxMembers are dealt.
        var dealt = [Int](repeating: 0, count: slots.count)
        var total = 0
        var progress = true
        while progress && total < blendMaxMembers {
            progress = false
            var i = 0
            while i < slots.count && total < blendMaxMembers {
                if let list = forward[i], dealt[i] < list.count {
                    dealt[i] += 1
                    total += 1
                    progress = true
                }
                i += 1
            }
        }

        var statuses: [WxSourceStatus] = []
        var results: [WxSourceResult] = []
        statuses.reserveCapacity(slots.count)
        for i in slots.indices {
            let status = slots[i].status
            var state = status.state
            var errorCode = status.errorCode
            if slots[i].outcome != nil {  // settle_slot: a slot that was not fetched is untouched
                switch failures[i] {
                case nil:
                    state = .ok
                case .error(let error)? where error.code == .unsupported:
                    state = .skipped
                case .error(let error)?:
                    state = .failed
                    errorCode = error.code
                case .cancelled?:
                    state = .failed  // cancelled by the provider itself: no WxError code
                }
            }
            statuses.append(Self.status(status, state: state, errorCode: errorCode, nMembers: UInt32(dealt[i])))
            if let list = forward[i], dealt[i] > 0, var result = answers[i] {
                result.members = Array(list.prefix(dealt[i]))
                results.append(result)
            }
        }
        return Selection(statuses: statuses, results: results, failures: failures)
    }

    /// `status` with state, error code and member count replaced (C writes the
    /// three fields of the slot's status in place). A WxSourceStatus is valid
    /// by construction, so re-validating its own fields cannot fail.
    private static func status(
        _ status: WxSourceStatus, state: WxSourceState, errorCode: WxError.Code?, nMembers: UInt32
    ) -> WxSourceStatus {
        do {
            return try WxSourceStatus(
                providerID: status.providerID, name: status.name, attribution: status.attribution,
                attributionURL: status.attributionURL, state: state, errorCode: errorCode,
                nMembers: nMembers)
        } catch {
            preconditionFailure("a valid WxSourceStatus failed re-validation: \(error)")
        }
    }
}
