// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Clock.swift - the injectable time source of WeatherCore. Every component
// that reads the time or waits for a deadline takes a `WxClock`; production
// passes `SystemClock` (or `.system`), tests pass a `ManualClock`.
//
// Units follow the C code: wall time is g_get_real_time() (microseconds since
// the Unix epoch; the C code derives seconds with `/ G_USEC_PER_SEC` and
// milliseconds with `/ 1000`, e.g. src/ui/wx-app.c:126,147), and monotonic
// time is g_get_monotonic_time() (microseconds). On Linux, GLib's monotonic
// clock (CLOCK_MONOTONIC) does NOT advance while the system is suspended, and
// the scheduler relies on that (cartography storage-sched-service.md §8.1).
// Darwin's CLOCK_MONOTONIC and Swift's ContinuousClock DO count sleep, so
// `SystemClock` reads CLOCK_UPTIME_RAW (the base of SuspendingClock and
// ProcessInfo.systemUptime), which does not, and sleeps on SuspendingClock.

import Foundation
import Synchronization

/// A source of wall-clock and monotonic time that can also wait for a
/// monotonic deadline.
public protocol WxClock: Sendable {
    /// Wall-clock (real) time: microseconds since 1970-01-01T00:00:00Z
    /// (g_get_real_time()). May jump when the user or NTP changes the clock.
    var wallMicroseconds: Int64 { get }

    /// Monotonic time in microseconds (g_get_monotonic_time() on Linux): it
    /// never decreases and does NOT advance while the system sleeps. Only
    /// differences between two readings are meaningful.
    var monotonicMicroseconds: Int64 { get }

    /// Suspends the caller until `monotonicMicroseconds >= deadline`
    /// (a monotonic time in microseconds). Returns at once when the deadline
    /// has already passed. Runs on the caller's actor.
    ///
    /// - Throws: `CancellationError` when the calling task is (or becomes)
    ///   cancelled before the deadline is reached.
    nonisolated(nonsending) func sleep(until deadline: Int64) async throws
}

extension WxClock {
    /// Wall-clock seconds since the epoch: `wallMicroseconds / 1_000_000`
    /// (C: `g_get_real_time() / G_USEC_PER_SEC`, truncating division).
    public var wallSeconds: Int64 { wallMicroseconds / 1_000_000 }

    /// Wall-clock milliseconds since the epoch: `wallMicroseconds / 1000`
    /// (C: `g_get_real_time() / 1000`, truncating division).
    public var wallMilliseconds: Int64 { wallMicroseconds / 1000 }
}

extension WxClock where Self == SystemClock {
    /// The real clock of the machine.
    public static var system: SystemClock { SystemClock() }
}

/// The real clock: wall time from CLOCK_REALTIME, monotonic time from
/// CLOCK_UPTIME_RAW (does not advance during system sleep), sleeping on
/// `SuspendingClock` (same time base).
public struct SystemClock: WxClock {
    public init() {}

    public var wallMicroseconds: Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_REALTIME) / 1000)
    }

    public var monotonicMicroseconds: Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000)
    }

    public nonisolated(nonsending) func sleep(until deadline: Int64) async throws {
        try Task.checkCancellation()
        while true {
            // Compare before subtracting: once deadline > now >= 0 the
            // difference cannot overflow, while `deadline - now` computed
            // first traps for deadlines near Int64.min.
            let now = monotonicMicroseconds
            if deadline <= now {
                return
            }
            // SuspendingClock does not advance while the system sleeps either;
            // the loop re-reads the clock, so an early wake-up sleeps again.
            try await Task.sleep(for: .microseconds(deadline - now), clock: .suspending)
        }
    }
}

/// A deterministic clock for tests: time moves only when `advance(by:)` or
/// `advanceWall(by:)` is called.
///
/// `advance(by:)` lets time pass through every due deadline in ascending
/// order (equal deadlines in the order the sleepers started sleeping): for
/// each sleeper whose deadline is reached it sets the clock to that deadline,
/// resumes that one sleeper, and waits until the sleeper is running again
/// before it resumes the next; when no sleeper is due any more it sets the
/// clock to the target in the same locked step, so a sleeper that starts
/// sleeping during the advance with a deadline within the target is never
/// left parked.
/// Sleepers isolated to the actor that calls `advance(by:)` therefore run
/// their code up to their next suspension point strictly in deadline order
/// (a sleeper that goes back to sleep with a deadline still within the
/// target is woken again in its turn). `sleep(until:)` runs on the caller's
/// actor. Use `waitForSleepers(_:)` to wait until tasks have actually gone to
/// sleep before advancing.
public final class ManualClock: WxClock {
    private struct Sleeper {
        let deadline: Int64
        let sequence: UInt64
        var continuation: CheckedContinuation<Void, any Error>?
        var cancelled: Bool
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var wall: Int64
        var monotonic: Int64
        var nextSequence: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        var waiters: [Waiter] = []
        /// advance(by:) waiting for the resumed sleeper `key` to run again.
        var acks: [UInt64: CheckedContinuation<Void, Never>] = [:]

        var pendingCount: Int {
            sleepers.values.reduce(0) { $0 + ($1.continuation != nil ? 1 : 0) }
        }

        /// Removes and returns the waiters whose count is reached.
        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            let pending = pendingCount
            let ready = waiters.filter { $0.count <= pending }.map(\.continuation)
            waiters.removeAll { $0.count <= pending }
            return ready
        }

        /// Removes and returns the suspended sleeper with the earliest
        /// (deadline, sequence) whose deadline is <= `limit`.
        mutating func takeFirstDue(upTo limit: Int64) -> Sleeper? {
            let due = sleepers.values.filter { $0.continuation != nil && $0.deadline <= limit }
            guard let first = due.min(by: { ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence) }) else {
                return nil
            }
            sleepers[first.sequence] = nil
            return first
        }
    }

    private let state: Mutex<State>

    /// Creates a clock at the given times (microseconds). The default wall
    /// time is 2026-10-11T00:00:00Z (the C tests' T0 = 1791676800 s,
    /// src/core/test-core.c:18).
    public init(wallMicroseconds: Int64 = 1_791_676_800_000_000, monotonicMicroseconds: Int64 = 0) {
        state = Mutex(State(wall: wallMicroseconds, monotonic: monotonicMicroseconds))
    }

    public var wallMicroseconds: Int64 {
        state.withLock { $0.wall }
    }

    public var monotonicMicroseconds: Int64 {
        state.withLock { $0.monotonic }
    }

    /// The number of tasks currently suspended in `sleep(until:)`.
    public var pendingSleeperCount: Int {
        state.withLock { $0.pendingCount }
    }

    /// Moves wall and monotonic time forward by `microseconds` (>= 0),
    /// resuming every sleeper whose deadline is reached on the way, one at a
    /// time in deadline order (see the type documentation). Runs on the
    /// caller's actor.
    public nonisolated(nonsending) func advance(by microseconds: Int64) async {
        await advance(by: microseconds, isolation: #isolation)
    }

    /// The body of `advance(by:)`, run on the caller's actor (`isolation`): the
    /// next sleeper is resumed only after the previous one has run on its
    /// actor up to its next suspension point when both share that actor.
    private func advance(by microseconds: Int64, isolation: isolated (any Actor)?) async {
        precondition(microseconds >= 0, "ManualClock.advance(by:) needs a non-negative amount")
        let target = state.withLock { $0.monotonic + microseconds }
        while true {
            // One locked section either takes the next due sleeper or, when
            // none is due, moves the clock to the target. A sleeper that parks
            // after this scan therefore sees the target time and returns by
            // itself; with two sections it could park in between and be left
            // behind until the next advance.
            let next: Sleeper? = state.withLock { s in
                guard let sleeper = s.takeFirstDue(upTo: target) else {
                    if target > s.monotonic {
                        s.wall += target - s.monotonic
                        s.monotonic = target
                    }
                    return nil
                }
                if sleeper.deadline > s.monotonic {  // time passes through the deadline
                    s.wall += sleeper.deadline - s.monotonic
                    s.monotonic = sleeper.deadline
                }
                return sleeper
            }
            // takeFirstDue returns only suspended sleepers (continuation != nil).
            guard let next, let continuation = next.continuation else {
                return
            }
            // The nonisolated(nonsending) overload runs on this function's
            // isolation (the caller's actor), as the deprecated
            // `isolation:` overload did.
            await withCheckedContinuation { (ack: CheckedContinuation<Void, Never>) in
                state.withLock { $0.acks[next.sequence] = ack }
                continuation.resume()
            }
        }
    }

    /// Moves only the wall clock by `microseconds` (may be negative): what a
    /// system sleep of that length (monotonic time does not advance during
    /// sleep) or a wall-clock change looks like. No sleeper is resumed.
    public func advanceWall(by microseconds: Int64) {
        state.withLock { $0.wall += microseconds }
    }

    /// Suspends until at least `count` tasks are suspended in `sleep(until:)`.
    /// Runs on the caller's actor.
    public nonisolated(nonsending) func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = state.withLock { s in
                if s.pendingCount >= count {
                    return true
                }
                s.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    public nonisolated(nonsending) func sleep(until deadline: Int64) async throws {
        try await sleep(until: deadline, isolation: #isolation)
    }

    /// The body of `sleep(until:)`, run on the caller's actor (`isolation`).
    private func sleep(until deadline: Int64, isolation: isolated (any Actor)?) async throws {
        try Task.checkCancellation()
        let sequence: UInt64? = state.withLock { s in
            if s.monotonic >= deadline {
                return nil
            }
            let sequence = s.nextSequence
            s.nextSequence += 1
            s.sleepers[sequence] = Sleeper(deadline: deadline, sequence: sequence, continuation: nil, cancelled: false)
            return sequence
        }
        guard let sequence else {
            return
        }
        try await withTaskCancellationHandler(operation: {
            _ = isolation  // capturing the isolated parameter keeps the closure on that actor
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, resume, cancel }
                let (outcome, waiters): (Outcome, [CheckedContinuation<Void, Never>]) = state.withLock { s in
                    guard let sleeper = s.sleepers[sequence] else {
                        return (.resume, [])
                    }
                    if sleeper.cancelled {
                        s.sleepers[sequence] = nil
                        return (.cancel, [])
                    }
                    if s.monotonic >= sleeper.deadline {
                        s.sleepers[sequence] = nil
                        return (.resume, [])
                    }
                    s.sleepers[sequence]?.continuation = continuation
                    return (.wait, s.takeSatisfiedWaiters())
                }
                switch outcome {
                case .wait:
                    for waiter in waiters {
                        waiter.resume()
                    }
                case .resume:
                    continuation.resume()
                case .cancel:
                    continuation.resume(throwing: CancellationError())
                }
            }
        }, onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = state.withLock { s in
                guard let sleeper = s.sleepers[sequence] else {
                    return nil  // already resumed
                }
                if let continuation = sleeper.continuation {
                    s.sleepers[sequence] = nil
                    return continuation
                }
                s.sleepers[sequence]?.cancelled = true  // not suspended yet
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }, isolation: isolation)
        // Running again: let a waiting advance(by:) resume the next sleeper.
        let ack = state.withLock { $0.acks.removeValue(forKey: sequence) }
        ack?.resume()
    }
}
