// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U35AuditFixTests.swift - regression tests for the verified audit findings of
// slices P05 / P06 (HTTPClient, strict gzip) fixed by U35. U05-F2 is
// comment-only; U06-F1 is also pinned by HTTPClientWireTests'
// strictGzipWhereURLSessionDoesNotInflate ("late garbage"); U06-F2 (slices
// consumed by index) changes no result and is covered by
// gzipMemberDecoderFindsTheExactEnd.

import Foundation
import Synchronization
import Testing
@testable import WeatherCore

/// A WxClock whose monotonic time moves WITHOUT waking its sleepers, which are released
/// explicitly: what a late SuspendingClock wake-up (HTTPClient.swift file comment, about
/// 6.7 % late) looks like to the code that reads the clock right after its sleep returns.
/// ManualClock cannot show it: its advance resumes each sleeper at exactly its deadline.
private final class LateWakeClock: WxClock {
    private struct State {
        var monotonic: Int64 = 0
        var nextID: UInt64 = 0
        var sleepers: [UInt64: (deadline: Int64, continuation: CheckedContinuation<Void, any Error>)] = [:]
    }
    private let state = Mutex(State())

    var wallMicroseconds: Int64 { 1_791_676_800_000_000 + monotonicMicroseconds }
    var monotonicMicroseconds: Int64 { state.withLock { $0.monotonic } }
    /// The deadlines of the sleepers not yet released, ascending.
    var pendingDeadlines: [Int64] { state.withLock { $0.sleepers.values.map(\.deadline).sorted() } }

    /// Sets the monotonic time to `time`, then releases the sleepers whose deadline is at most
    /// `limit`: they wake at `time`, later than their deadline.
    func wakeLate(at time: Int64, upTo limit: Int64) {
        let due = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.monotonic = time
            let ids = s.sleepers.filter { $0.value.deadline <= limit }.keys
            return ids.compactMap { s.sleepers.removeValue(forKey: $0)?.continuation }
        }
        for continuation in due { continuation.resume() }
    }

    nonisolated(nonsending) func sleep(until deadline: Int64) async throws {
        try Task.checkCancellation()
        if monotonicMicroseconds >= deadline { return }
        let id = state.withLock { s -> UInt64 in
            defer { s.nextID += 1 }
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { s -> Bool in
                    if Task.isCancelled { return true }
                    s.sleepers[id] = (deadline, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id)?.continuation }?.resume(throwing: CancellationError())
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct U35AuditFixTests {

    // U05-F1 (paced path): B's pacing sleep returned after B's whole-operation deadline. The
    // queue head took its turn anyway: an attempt was begun and cancelled at once by its expired
    // deadline (finishedAttemptCount 1 -> 2), and the pacing slot it took held the next queued
    // operation C asleep until B's late start + minGapMs. Now B fails with the deadline's TIMEOUT
    // and begins nothing, and C goes at once.
    @Test func pacingWakeAfterTheTotalDeadlineBeginsNoAttempt() async throws {
        let server = try LoopbackServer([.text(HTTPClientTests.kBody)])
        defer { server.stop() }
        let clock = LateWakeClock()
        let http = try HTTPClientTests.client(
            server, timeoutMs: 5000, backoffMs: 5, gapMs: 1000, clock: clock, totalDeadlineMs: 2000)
        // A goes at once at 0 s; the next attempt may start at 1 s.
        #expect(HTTPClientTests.body(await HTTPClientTests.fetch(http)) != nil)
        #expect(http.finishedAttemptCount == 1)
        // B (deadline 2 s) sleeps for the slot at 1 s; the sleep returns at 2.5 s.
        let b = HTTPClientTests.start(http)
        let sleeping = await HTTPClientTests.waitUntil(timeout: .seconds(10)) { clock.pendingDeadlines == [1_000_000] }
        #expect(sleeping, "B sleeps for the pacing slot: \(clock.pendingDeadlines)")
        clock.wakeLate(at: 2_500_000, upTo: 1_000_000)
        let errorB = await HTTPClientTests.outcome(of: b, within: .seconds(10)).flatMap(HTTPClientTests.wxError)
        #expect(errorB?.code == .timeout)
        #expect(errorB?.message == HTTPPolicy.Message.deadlineExceeded)
        #expect(http.finishedAttemptCount == 1, "an attempt was begun for B after its total deadline")
        // C at 2.5 s: A's slot ended at 1 s, so C goes now, not at 3.5 s.
        let attemptsBeforeC = http.finishedAttemptCount
        let c = HTTPClientTests.start(http)
        let settled = await HTTPClientTests.waitUntil(timeout: .seconds(10)) {
            http.finishedAttemptCount > attemptsBeforeC || clock.pendingDeadlines.contains(3_500_000)
        }
        #expect(settled)
        #expect(!clock.pendingDeadlines.contains(3_500_000), "C is held for the slot B took")
        clock.wakeLate(at: 3_500_000, upTo: 3_500_000)  // releases a held C inside its deadline (4.5 s)
        let outcomeC = await HTTPClientTests.outcome(of: c, within: .seconds(10))
        #expect(outcomeC.flatMap(HTTPClientTests.body) != nil)
    }

    // U05-F1 (back-off path, unpaced): the back-off sleep after a 503 returned after the
    // whole-operation deadline; the retry was begun anyway and cancelled at once. Now the
    // operation fails with the deadline's TIMEOUT and begins no second attempt.
    @Test func backoffWakeAfterTheTotalDeadlineBeginsNoAttempt() async throws {
        let server = try LoopbackServer([
            .respond(status: 503, body: Data(HTTPClientTests.kBody.utf8)), .text(HTTPClientTests.kBody),
        ])
        defer { server.stop() }
        let clock = LateWakeClock()
        let http = try HTTPClientTests.client(
            server, timeoutMs: 5000, backoffMs: 1000, clock: clock, totalDeadlineMs: 2000)
        let operation = HTTPClientTests.start(http)
        let backingOff = await HTTPClientTests.waitUntil(timeout: .seconds(10)) {
            http.finishedAttemptCount == 1 && clock.pendingDeadlines == [1_000_000]
        }
        #expect(backingOff, "back-off sleep until 1 s: \(clock.pendingDeadlines)")
        clock.wakeLate(at: 2_500_000, upTo: 1_000_000)
        let error = await HTTPClientTests.outcome(of: operation, within: .seconds(10)).flatMap(HTTPClientTests.wxError)
        #expect(error?.code == .timeout)
        #expect(error?.message == HTTPPolicy.Message.deadlineExceeded)
        #expect(http.finishedAttemptCount == 1, "a retry was begun after the total deadline")
        #expect(server.requestCount == 1)
        clock.wakeLate(at: 10_000_000, upTo: .max)
    }

    // U06-F1: the strict decoder kept a read's tail shorter than one 4 KiB slice undecoded until
    // the next read or finish(), so the end of a short member was found only then: bytes in a
    // later read were "data after the end" (C: "continues after its end marker", wx-http.c:
    // 913-916), and a read C fails at once (wx-http.c:999-1001) got no verdict until the body
    // ended. Now every read is decoded when it arrives.
    @Test func gzipVerdictComesFromTheReadThatHoldsIt() {
        let member = Data(HTTPClientTests.gzipJSON)
        let limit = HTTPPolicy.maxBodyBytes
        let twoReads = HTTPClient.GzipMemberDecoder(limit: limit)
        #expect(twoReads.feed(member) == nil)
        #expect(twoReads.feed(Data([0x41])) == .continuesAfterEnd)
        let oneRead = HTTPClient.GzipMemberDecoder(limit: limit)
        #expect(oneRead.feed(member + Data([0x41])) == .dataAfterEnd)
        // Each verdict's error, C's text (wx-http.c:915, :937). Pinned here because the wire
        // test's late-garbage row cannot pin it: there the verdict depends on how the reads split.
        #expect(HTTPClient.GzipMemberDecoder.Failure.continuesAfterEnd.error
            == WxError(.parse, "compressed body continues after its end marker"))
        #expect(HTTPClient.GzipMemberDecoder.Failure.dataAfterEnd.error
            == WxError(.parse, "data after the end of the compressed body"))
        // Invalid DEFLATE data (block type 3) in a short read.
        let corrupt = HTTPClient.GzipMemberDecoder(limit: limit)
        #expect(corrupt.feed(Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF, 0x07, 0, 0, 0])) == .corrupt)
    }

    // U06-F1 through the real transfer, on a list CFNetwork leaves undecoded: the member and
    // "xy" arrive in one read, then "z" and the drop of the connection before the declared
    // Content-Length. C reports PARSE at the first read, after 1 request; the deferred tail got
    // no verdict before the drop, whose NETWORK was retried (3 requests). (When the bytes and the
    // drop arrive together, CFNetwork fails the task without handing the bytes over: NETWORK x3
    // before and after the fix.)
    @Test func gzipTrailingBytesBeforeADroppedConnectionAreParse() async throws {
        let payload = HTTPClientTests.gzipJSON + Array("xyz".utf8)
        let response = HTTPClientTests.responseWith(
            "Content-Encoding: identity, gzip\r\n", payload, sendLen: payload.count, declared: payload.count + 100)
        try await HTTPClientTests.expectCase(
            HTTPClientTests.split(response, first: response.count - 1, delayMs: 200), code: .parse, requests: 1,
            messageContains: "data after the end of the compressed body", "member + xyz, then the connection drops")
    }
}
