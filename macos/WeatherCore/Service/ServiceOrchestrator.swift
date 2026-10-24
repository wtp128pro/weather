// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ServiceOrchestrator.swift - the forecast service: fans one refresh out to
// every enabled registered provider that covers the place, waits for all of
// them or for a deadline, blends what arrived into one WxForecast with a
// per-source status, and runs place searches through the registry's geocoder.
// Port of the orchestration of src/service/wx-service.c (wx_service_refresh_async
// :1123-1163, start_fetches :1101-1119, on_child_done :939-980, op_complete
// :818-848, on_deadline / on_outer_cancelled :886-916, op_add_slots :1033-1051,
// build_forecast :766-794, wx_service_search_async :1245-1264, on_search_done
// :1226-1241) following the contract of src/service/wx-service.h:1-176. The
// pure stages (normalisation, statuses, usable/distinct/fair-share members,
// error precedence) are ServicePipeline (U15); the blend is WxBlend (U21).
//
// Refresh, in order (wx-service.h:10-38):
//  1. A caller whose task is already cancelled gets CancellationError and
//     nothing else is done (no registry call, no provider call).
//  2. registry.listCovering(place) (covers() once per enabled provider), then
//     registry.listProviders() (so a provider a covers() added is listed). A
//     provider whose id, read now, is not a valid source id is neither
//     fetched nor listed (ServicePipeline.initialStatus(for:) == nil). No
//     covering provider left: WxError(.unsupported, "no enabled data source
//     covers this place"), no provider fetched.
//  3. fetch(place) is started on every covering provider, in registration
//     order, each in its OWN unstructured task (Task.immediate on the main
//     actor): the caller's cancellation is never propagated to a provider, and
//     the deadline never cancels the caller. The deadline (`deadlineMs`, 30 s)
//     runs from the call, on the monotonic clock.
//  4. The refresh completes as soon as every started fetch has returned, or
//     when the deadline expires, or when the caller's task is cancelled. At
//     the deadline or the caller's cancellation the fetch tasks still running
//     are cancelled and NOT waited for (no task group: a provider that ignores
//     cancellation or never answers cannot delay the result); whatever such a
//     task returns later is dropped unread (C's `op->task == NULL` guard,
//     wx-service.c:950). The outcome is built at completion: the slots are
//     settled and reduced by ServicePipeline.select (registration order,
//     whatever the arrival order; a fetched slot without an answer is
//     .noAnswer), the blend is called with now = the wall clock at completion
//     when some member is forwarded, and otherwise (or when the blend fails)
//     the error is Selection.failure(blendError:) - its "<provider id>: "
//     prefix is the id read in step 2 (wx-service.c:675), never the result's
//     providerID; member source ids are never compared with the provider id.
//  5. The caller's cancellation outranks everything (wx-service.h:120-122,
//     GTask semantics): if the calling task is cancelled before refresh
//     returns, it throws CancellationError, even when the forecast was ready.
//
// Search (wx-service.h:153-164): a cancelled caller gets CancellationError and
// the geocoder is not called; no geocoder: WxError(.unsupported, "no geocoder
// is registered"); otherwise the registry's geocoder (the one set at the call)
// is awaited in the caller's own task (C passes the caller's cancellable on
// unchanged), its errors are normalised by ServicePipeline.normalize WITHOUT
// a provider prefix, and at most WxLimits.geocoderMaxHits places are returned
// in the geocoder's order. A caller cancelled before search returns gets
// CancellationError.
//
// Differences that follow from the Swift types (unreachable states, so not
// checked at run time): a WxPlace is valid by construction, so the C
// "invalid place" (WX_ERROR_INVALID_ARG) and the re-validation of geocoder
// hits (NULL or invalid places) cannot occur; a fetch either returns or
// throws (no "result and error"); a geocoder returns an array, never NULL
// ("the geocoder returned no result" cannot occur); the C criticals of
// wrong-typed arguments are compile-time errors. The callback "never before
// the *_async function has returned" and "exactly once" have no counterpart:
// there is no callback, the caller awaits one return.

import Foundation

/// The forecast service (WxService, src/service/wx-service.h).
///
/// A main-actor object like the registry it reads (C: "main thread only").
/// Every operation reads the registry when it starts, so providers added,
/// enabled or disabled later take effect with the next one. The service holds
/// its own strong reference to the registry. An operation in flight keeps the
/// service alive until it returns; a provider fetch that outlives its refresh
/// (deadline, cancellation) references neither the service nor the refresh's
/// caller.
@MainActor
public final class ServiceOrchestrator {
    /// WX_SERVICE_DEADLINE_MS (src/service/wx-service.h:187-188): overall
    /// deadline of one refresh, in milliseconds, counted from the call.
    public nonisolated static let deadlineMs: UInt32 = 30000

    /// The message of a refresh with no covering provider (wx-service.c:1146).
    nonisolated static let noCoveringMessage = "no enabled data source covers this place"

    /// The message of a search without a geocoder (wx-service.c:1258).
    nonisolated static let noGeocoderMessage = "no geocoder is registered"

    private let registry: WxRegistry
    private let clock: any WxClock
    private var deadlineOverrideMs: UInt32 = ServiceOrchestrator.deadlineMs

    /// TEST SEAM (wx_service_test_set_deadline_ms, wx-service-testing.h:20-36):
    /// the deadline of every refresh started from now on; setting 0 restores
    /// `deadlineMs`. A refresh in flight keeps the deadline it started with.
    /// Reached only through `@testable import`; production code never sets it.
    var testDeadlineMs: UInt32 {
        get { deadlineOverrideMs }
        set { deadlineOverrideMs = newValue != 0 ? newValue : Self.deadlineMs }
    }

    /// TEST SEAM: runs on the main actor right after a refresh completed (its
    /// outcome is built and every slot is closed), before the refresh resumes
    /// its caller - the window between C's callback and wx_service_refresh_finish
    /// (test-service.c:2035-2064). nil in production.
    var completionProbe: (@MainActor () -> Void)?

    /// wx_service_new: a service over `registry`, timing on `clock` (the
    /// deadline on its monotonic time, the forecast's generatedS from its
    /// wall time). Production passes the default `SystemClock()`.
    public init(registry: WxRegistry, clock: any WxClock = SystemClock()) {
        self.registry = registry
        self.clock = clock
    }

    // MARK: - Refresh

    /// wx_service_refresh_async + wx_service_refresh_finish (see the file
    /// comment for the order of the steps).
    ///
    /// - Returns: the blended forecast (generatedS = the wall clock when the
    ///   refresh completed; `sources` = one status per listed provider in
    ///   registration order).
    /// - Throws: `CancellationError` when the calling task was cancelled before
    ///   this returns, or when no provider is OK and every covering provider
    ///   reported its own cancellation; otherwise a `WxError` (only this
    ///   domain): `.unsupported` "no enabled data source covers this place", or
    ///   the most informative failure of the providers and the blend
    ///   (ServicePipeline.Selection.failure(blendError:)).
    public func refresh(_ place: WxPlace) async throws -> WxForecast {
        let outcome = await runRefresh(place)
        // GTask: a cancellable cancelled before *_finish wins over every outcome.
        if Task.isCancelled {
            throw CancellationError()
        }
        return try outcome.get()
    }

    /// The refresh up to its outcome (wx_service_refresh_async).
    private func runRefresh(_ place: WxPlace) async -> Result<WxForecast, any Error> {
        if Task.isCancelled {  // g_task_return_error_if_cancelled, wx-service.c:1132
            return .failure(CancellationError())
        }
        let startUs = clock.monotonicMicroseconds  // the deadline runs from the call
        let deadlineMs = deadlineOverrideMs  // op_new: the deadline this refresh started with

        // Covering first: a covers() that adds a provider is then listed too (wx-service.c:1139-1141).
        let covering = registry.listCovering(place)
        let providers = registry.listProviders()
        var slots: [ServicePipeline.Slot] = []
        var fetches: [(index: Int, provider: any WxProvider)] = []
        for provider in providers {  // op_add_slots, wx-service.c:1033-1051
            guard let status = ServicePipeline.initialStatus(for: provider) else {
                continue  // an invalid id cannot be reported: neither fetched nor listed
            }
            if covering.contains(where: { $0 === provider }) {
                fetches.append((slots.count, provider))
            }
            slots.append(ServicePipeline.Slot(status: status))
        }
        if fetches.isEmpty {
            return .failure(WxError(.unsupported, Self.noCoveringMessage))
        }

        let operation = RefreshOperation(
            place: place, slots: slots, fetched: fetches.map(\.index), deadlineMs: deadlineMs,
            clock: clock, probe: completionProbe)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<WxForecast, any Error>, Never>) in
                operation.start(continuation, fetches: fetches, deadlineUs: Self.deadline(startUs, deadlineMs))
            }
        } onCancel: {
            // on_outer_cancelled runs in the main context, never inside the cancel call.
            Task { @MainActor in operation.complete(.cancelled) }
        }
    }

    /// startUs + deadlineMs milliseconds, saturating (a monotonic reading is
    /// never near Int64.max; the clamp only keeps the sum from trapping).
    private nonisolated static func deadline(_ startUs: Int64, _ deadlineMs: UInt32) -> Int64 {
        let (sum, overflow) = startUs.addingReportingOverflow(Int64(deadlineMs) * 1000)
        return overflow ? Int64.max : sum
    }

    /// How a refresh completes (Done, wx-service.c:302-307).
    private enum Done {
        case all  // every started fetch has returned
        case deadline  // the deadline expired
        case cancelled  // the caller's task was cancelled
    }

    /// The state of one refresh (Op, wx-service.c:281-294). Main actor only.
    /// It never references the service, so a late fetch result finds only a
    /// closed operation.
    @MainActor
    private final class RefreshOperation {
        private let place: WxPlace
        private var slots: [ServicePipeline.Slot]
        private let fetched: [Int]
        private let deadlineMs: UInt32
        private let clock: any WxClock
        private let probe: (@MainActor () -> Void)?
        private var pending = 0  // started fetches that have not returned
        private var starting = false  // do not complete from a fetch while starting
        private var outcome: Result<WxForecast, any Error>?  // set exactly once, at completion
        private var continuation: CheckedContinuation<Result<WxForecast, any Error>, Never>?
        private var children: [Task<Void, Never>] = []
        private var deadlineTask: Task<Void, Never>?

        init(
            place: WxPlace, slots: [ServicePipeline.Slot], fetched: [Int], deadlineMs: UInt32,
            clock: any WxClock, probe: (@MainActor () -> Void)?
        ) {
            self.place = place
            self.slots = slots
            self.fetched = fetched
            self.deadlineMs = deadlineMs
            self.clock = clock
            self.probe = probe
        }

        /// True until the operation completed (C: op->task != NULL).
        var isOpen: Bool { outcome == nil }

        /// Arms the deadline and starts every fetch (wx-service.c:1151-1161,
        /// start_fetches :1101-1119): one after the other, in registration
        /// order, before the caller suspends; a fetch not started yet when
        /// the operation completed (cancelled meanwhile) is not started.
        func start(
            _ continuation: CheckedContinuation<Result<WxForecast, any Error>, Never>,
            fetches: [(index: Int, provider: any WxProvider)], deadlineUs: Int64
        ) {
            if let outcome {  // cancelled before the continuation existed
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            let clock = self.clock
            deadlineTask = Task { @MainActor [weak self] in
                do {
                    try await clock.sleep(until: deadlineUs)
                } catch {
                    return  // stopped: the operation completed first
                }
                self?.complete(.deadline)
            }
            starting = true
            let place = self.place
            for (index, provider) in fetches where isOpen {
                pending += 1
                // Runs synchronously up to the provider call: the fetches start in order.
                let child = Task.immediate { @MainActor [self] in
                    let answer: ServicePipeline.FetchOutcome
                    do {
                        answer = .answered(try await provider.fetch(place))
                    } catch {
                        answer = .failed(error)
                    }
                    self.childDone(index, answer)
                }
                children.append(child)
            }
            starting = false
            finishIfDone()
        }

        /// on_child_done: records a fetch's answer, or drops it unread when
        /// the operation has already completed.
        private func childDone(_ index: Int, _ answer: ServicePipeline.FetchOutcome) {
            guard isOpen else {
                return  // too late: deadline or cancellation came first
            }
            slots[index].outcome = answer
            pending -= 1
            finishIfDone()
        }

        /// op_finish_if_done.
        private func finishIfDone() {
            if isOpen && !starting && pending == 0 {
                complete(.all)
            }
        }

        /// op_complete: completes the operation exactly once - builds the
        /// outcome (a cancellation needs none), stops the deadline, cancels
        /// the fetches still running (deadline and cancellation; they are not
        /// awaited) and resumes the caller.
        func complete(_ how: Done) {
            guard isOpen else {
                return
            }
            let result: Result<WxForecast, any Error>
            if how == .cancelled {
                result = .failure(CancellationError())
            } else {
                for index in fetched where slots[index].outcome == nil {
                    slots[index].outcome = .noAnswer  // settle_slot: the deadline's timeout
                }
                result = buildForecast()
            }
            outcome = result
            deadlineTask?.cancel()
            deadlineTask = nil
            if how != .all {
                for child in children {
                    child.cancel()
                }
            }
            children = []
            probe?()
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: result)
            }
        }

        /// build_forecast (wx-service.c:766-794): selects the members, blends
        /// them with the statuses of every slot when some member is
        /// forwarded, and otherwise (or when the blend fails) picks the error.
        private func buildForecast() -> Result<WxForecast, any Error> {
            let selection = ServicePipeline.select(slots, deadlineMs: deadlineMs)
            var blendError: WxError?
            if !selection.results.isEmpty {
                let nowS = clock.wallSeconds  // g_get_real_time() / G_USEC_PER_SEC at completion
                do {
                    return .success(
                        try WxBlend.forecast(
                            place: place, results: selection.results, statuses: selection.statuses, nowS: nowS))
                } catch {
                    blendError = error
                }
            }
            return .failure(selection.failure(blendError: blendError).thrownError)
        }
    }

    // MARK: - Search

    /// wx_service_search_async + wx_service_search_finish for the C string in
    /// `textBytes` (passed to the geocoder unchanged).
    ///
    /// - Returns: at most `WxLimits.geocoderMaxHits` places in the geocoder's
    ///   order (possibly none).
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   this returns (the geocoder is not called when it already was) or when
    ///   the geocoder reports a cancellation; `WxError(.unsupported, "no
    ///   geocoder is registered")`; otherwise the geocoder's error normalised
    ///   (WxError keeps its code, any other error is `.network`; the message
    ///   sanitised to `ServicePipeline.messageMax` bytes, without a prefix).
    public func search(textBytes: [UInt8]) async throws -> [WxPlace] {
        let outcome = await runSearch(textBytes)
        if Task.isCancelled {
            throw CancellationError()
        }
        return try outcome.get()
    }

    /// `search(textBytes:)` with the UTF-8 bytes of `text`.
    public func search(_ text: String) async throws -> [WxPlace] {
        try await search(textBytes: Array(text.utf8))
    }

    /// The search up to its outcome (wx_service_search_async, on_search_done).
    private func runSearch(_ textBytes: [UInt8]) async -> Result<[WxPlace], any Error> {
        if Task.isCancelled {
            return .failure(CancellationError())
        }
        // The registry's geocoder at the call; the local reference keeps it
        // alive even if it is replaced while it runs (wx-service.c:1261-1262).
        guard let geocoder = registry.geocoder else {
            return .failure(WxError(.unsupported, Self.noGeocoderMessage))
        }
        do {
            let hits = try await geocoder.search(textBytes: textBytes)
            return .success(Array(hits.prefix(WxLimits.geocoderMaxHits)))  // copy_valid_hits
        } catch {
            return .failure(ServicePipeline.normalize(error).thrownError)
        }
    }
}
