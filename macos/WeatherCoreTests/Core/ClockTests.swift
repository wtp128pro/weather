// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ClockTests.swift - WxClock contract tests (no C counterpart: the C code
// calls g_get_real_time()/g_get_monotonic_time() directly). SystemClock is
// checked against independent Apple clocks; ManualClock against its
// documented deterministic resumption order.

import Foundation
import Testing
@testable import WeatherCore

/// Labels appended by MainActor sleepers in the order they run after waking.
@MainActor private final class WakeLog {
    var labels: [String] = []
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ClockTests {
    // MARK: SystemClock

    @Test func systemWallTimeIsUnixMicroseconds() {
        let before = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let clock: any WxClock = .system
        let wall = clock.wallMicroseconds
        let seconds = clock.wallSeconds
        let after = Int64(Date().timeIntervalSince1970 * 1_000_000)
        // Date has sub-microsecond resolution; 1 ms slack covers the double rounding.
        #expect(wall >= before - 1000 && wall <= after + 1000, "wall \(wall) not in [\(before), \(after)]")
        #expect(seconds >= before / 1_000_000 && seconds <= after / 1_000_000 + 1)
    }

    @Test func systemMonotonicTimeIsAwakeUptime() {
        // ProcessInfo.systemUptime is documented as the time the system has been awake since boot:
        // it excludes sleep, exactly like GLib's CLOCK_MONOTONIC on Linux. A clock that counts
        // sleep (Darwin CLOCK_MONOTONIC, ContinuousClock) is off by the total sleep since boot.
        let clock = SystemClock()
        let before = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        let mono = clock.monotonicMicroseconds
        let after = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        #expect(mono >= before - 1000 && mono <= after + 1000, "monotonic \(mono) not in [\(before), \(after)]")
    }

    @Test func systemMonotonicNeverDecreases() {
        let clock = SystemClock()
        var last = clock.monotonicMicroseconds
        for _ in 0..<10_000 {
            let now = clock.monotonicMicroseconds
            #expect(now >= last)
            last = now
        }
    }

    @Test func systemSleepUntilWaitsForTheMonotonicDeadline() async throws {
        let clock = SystemClock()
        let deadline = clock.monotonicMicroseconds + 20_000
        try await clock.sleep(until: deadline)
        #expect(clock.monotonicMicroseconds >= deadline)
        // a deadline in the past returns at once
        let start = clock.monotonicMicroseconds
        try await clock.sleep(until: start - 5_000_000)
        #expect(clock.monotonicMicroseconds - start < 1_000_000)
    }

    // Regression (U02 verify, defect 2): sleep(until:) compares the deadline with the clock
    // before it subtracts, so a deadline far in the past cannot overflow Int64 and returns at
    // once like any passed deadline (WxClock: "Returns at once when the deadline has already
    // passed"). Subtracting first overflows for Int64.min and Int64.min + 1 on any machine
    // that has been up for more than 1 µs.
    @Test func systemSleepWithExtremePastDeadlineReturnsAtOnce() async throws {
        let clock = SystemClock()
        let now = clock.monotonicMicroseconds
        let deadlines: [Int64] = [.min, .min + 1, .min + 1_000_000, -1, 0, now - 1, now]
        for deadline in deadlines {
            let start = clock.monotonicMicroseconds
            try await clock.sleep(until: deadline)
            let elapsed = clock.monotonicMicroseconds - start
            #expect(elapsed < 1_000_000, "sleep(until: \(deadline)) took \(elapsed) µs")
        }
    }

    @Test func systemSleepThrowsWhenCancelled() async {
        let clock = SystemClock()
        let task = Task {
            try await clock.sleep(until: clock.monotonicMicroseconds + 30_000_000)
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    // MARK: ManualClock

    @Test func manualClockReadsAndAdvances() async {
        let clock = ManualClock(wallMicroseconds: 1_791_676_800_999_999, monotonicMicroseconds: 5)
        #expect(clock.wallMicroseconds == 1_791_676_800_999_999)
        #expect(clock.wallSeconds == 1_791_676_800)  // C: g_get_real_time() / G_USEC_PER_SEC truncates
        #expect(clock.wallMilliseconds == 1_791_676_800_999)  // C: g_get_real_time() / 1000
        #expect(clock.monotonicMicroseconds == 5)
        await clock.advance(by: 1)
        #expect(clock.wallMicroseconds == 1_791_676_801_000_000)
        #expect(clock.wallSeconds == 1_791_676_801)
        #expect(clock.monotonicMicroseconds == 6)
        // a system sleep moves wall time only: monotonic time does not advance during sleep
        clock.advanceWall(by: 7_200_000_000)
        #expect(clock.wallSeconds == 1_791_676_801 + 7200)
        #expect(clock.monotonicMicroseconds == 6)
        // the default start is the C tests' T0 (src/core/test-core.c:18)
        #expect(ManualClock().wallSeconds == 1_791_676_800)
        #expect(ManualClock().monotonicMicroseconds == 0)
    }

    @Test func manualSleepWithPassedDeadlineReturnsAtOnce() async throws {
        let clock = ManualClock(monotonicMicroseconds: 1000)
        try await clock.sleep(until: 1000)
        try await clock.sleep(until: 0)
        #expect(clock.pendingSleeperCount == 0)
    }

    // Repeated (20 runs) so that an order that depended on scheduling luck would show up.
    @Test(arguments: 0..<20) @MainActor func advanceResumesDueSleepersInDeadlineOrder(run: Int) async throws {
        let clock = ManualClock(monotonicMicroseconds: 0)
        let log = WakeLog()
        // registered out of deadline order; "10a" sleeps before "10b"
        let plan: [(String, Int64)] = [("50", 50), ("10a", 10), ("40", 40), ("10b", 10), ("30", 30), ("70", 70)]
        var tasks: [String: Task<Void, any Error>] = [:]
        for (index, (label, deadline)) in plan.enumerated() {
            tasks[label] = Task { @MainActor in
                try await clock.sleep(until: deadline)
                log.labels.append("\(label)@\(clock.monotonicMicroseconds)")
            }
            await clock.waitForSleepers(index + 1)
        }
        #expect(clock.pendingSleeperCount == 6)

        await clock.advance(by: 9)  // nothing is due yet
        #expect(clock.pendingSleeperCount == 6)

        await clock.advance(by: 36)  // now 45: 10a, 10b, 30, 40 are due
        #expect(clock.monotonicMicroseconds == 45)
        for label in ["10a", "10b", "30", "40"] {
            try await tasks[label]!.value
        }
        // each sleeper ran (and saw the clock at its own deadline) before the next was resumed
        #expect(log.labels == ["10a@10", "10b@10", "30@30", "40@40"])
        #expect(clock.pendingSleeperCount == 2)

        // advancing the wall clock alone (a system sleep) wakes nobody
        clock.advanceWall(by: 1_000_000)
        #expect(clock.pendingSleeperCount == 2)

        await clock.advance(by: 100)  // now 145: 50, 70
        try await tasks["50"]!.value
        try await tasks["70"]!.value
        #expect(log.labels == ["10a@10", "10b@10", "30@30", "40@40", "50@50", "70@70"])
        #expect(clock.monotonicMicroseconds == 145)
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test @MainActor func advancePassesThroughDeadlinesOfSleepersThatSleepAgain() async throws {
        let clock = ManualClock(wallMicroseconds: 1_000_000, monotonicMicroseconds: 0)
        let log = WakeLog()
        let periodic = Task { @MainActor in
            for _ in 0..<4 {
                try await clock.sleep(until: clock.monotonicMicroseconds + 10)
                log.labels.append("p@\(clock.monotonicMicroseconds)")
            }
        }
        await clock.waitForSleepers(1)
        let once = Task { @MainActor in
            try await clock.sleep(until: 25)
            log.labels.append("x@\(clock.monotonicMicroseconds)")
        }
        await clock.waitForSleepers(2)
        await clock.advance(by: 35)
        try await once.value
        #expect(log.labels == ["p@10", "p@20", "x@25", "p@30"])
        #expect(clock.monotonicMicroseconds == 35)
        #expect(clock.wallMicroseconds == 1_000_035)  // wall moved with monotonic time
        #expect(clock.pendingSleeperCount == 1)  // the periodic sleeper, due at 40
        await clock.advance(by: 5)
        try await periodic.value
        #expect(log.labels == ["p@10", "p@20", "x@25", "p@30", "p@40"])
    }

    // Regression (U02 verify, defect 1): a sleeper that starts while an advance(by:) is
    // running, with a deadline the advance's target covers, must not be left parked when the
    // advance returns. Either the advance's due-scan finds it parked, or it registers after
    // time has moved and returns at once. The advance's last (empty) scan and its jump to the
    // target are one locked section, so a sleeper cannot park between them. The sleepers run
    // on other executors, outside the waitForSleepers pattern, on purpose; with one sleeper
    // per round the version with two lock sections lost 1-33 of 20000 rounds, so each round
    // starts several sleepers to make the race window more likely to be hit.
    @Test func sleeperStartedConcurrentlyWithAdvanceIsNeverLost() async throws {
        let rounds = fuzzIterations(20_000)
        let sleepersPerRound = 4
        var lost = 0
        for round in 0..<rounds {
            let clock = ManualClock(monotonicMicroseconds: 0)
            var sleepers: [Task<Void, any Error>] = []
            for k in 0..<sleepersPerRound {
                let deadline = Int64(1 + (round + 3 * k) % 10)  // 1...10, all within the target (10)
                sleepers.append(Task.detached { try await clock.sleep(until: deadline) })
            }
            await clock.advance(by: 10)
            let parked = clock.pendingSleeperCount
            if parked > 0 {
                lost += parked
                await clock.advance(by: 0)  // wake the lost sleepers so the test does not hang
            }
            for sleeper in sleepers {
                try await sleeper.value
            }
        }
        #expect(
            lost == 0,
            "\(lost) of \(rounds * sleepersPerRound) sleepers (\(rounds) rounds) were still parked after advance(by: 10) returned"
        )
    }

    @Test func manualSleepThrowsWhenCancelled() async throws {
        let clock = ManualClock()
        let sleeping = Task { try await clock.sleep(until: 1_000) }
        await clock.waitForSleepers(1)
        sleeping.cancel()
        let result = await sleeping.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.pendingSleeperCount == 0)
        await clock.advance(by: 5_000)  // the cancelled sleeper is not resumed again

        // a task cancelled before it sleeps throws at once
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(until: 1_000_000)
        }
        let earlyResult = await early.result
        #expect(throws: CancellationError.self) { try earlyResult.get() }
        #expect(clock.pendingSleeperCount == 0)
    }
}
