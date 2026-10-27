// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U33AuditFixTests.swift - regression tests for the verified audit findings of
// slice P02 (refresh engine / scheduler / registry / orchestrator) fixed by U33.

import Testing
@testable import WeatherCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct U33AuditFixTests {
    /// The RefreshEngine with recording handlers (RefreshEngineTests' Host is file-private).
    @MainActor final class Probe {
        let clock = ManualClock()
        var engine: RefreshEngine!
        var fetches: [UInt64] = []
        var cancels: [UInt64] = []
        var displayed: [Int64] = []

        init() {
            engine = RefreshEngine(
                clock: clock, online: true,
                fetch: { [weak self] id, _ in self?.fetches.append(id) },
                cancel: { [weak self] id in self?.cancels.append(id) },
                display: { [weak self] now in self?.displayed.append(now) })
        }

        /// The place selected and shown: one request in flight (its end is not reported).
        func start() {
            engine.setPlaces([Self.miami])
            engine.select(Self.miami)
            engine.setVisible(true)
        }

        static let miami = "25.7617,-80.1918"
    }

    /// After shutdown the network monitor's report is ignored like every other input
    /// (RefreshEngine.shutdown: "from now on every input is ignored"): no display tick,
    /// no offline flip, no request, no timer, no clock.
    private func expectSetOnlineIgnored(_ p: Probe) async {
        let fetches = p.fetches, cancels = p.cancels, displayed = p.displayed
        p.engine.setOnline(false)
        #expect(!p.engine.isOffline)
        p.engine.setOnline(true)
        await p.clock.advance(by: 700 * 1_000_000)
        #expect(p.displayed == displayed, "display callbacks after shutdown = \(p.displayed.count - displayed.count)")
        #expect(p.fetches == fetches)
        #expect(p.cancels == cancels)
        #expect(!p.engine.isOffline)
        #expect(!p.engine.refreshTimerArmed)
        #expect(!p.engine.displayClockRunning)
    }

    // U02-F1: setOnline lacked the shutdown guard the other inputs carry, so each network
    // change after shutdown still ran the display handler and flipped the offline flags.
    @Test func setOnlineAfterShutdownIsIgnored() async throws {
        let p = Probe()
        p.start()
        // The start fetched once and that request ends before the shutdown (no id-0 fallback that
        // would let a start that fetched nothing pass; U33 verifier handoff).
        #expect(p.fetches.count == 1)
        p.engine.requestFinished(id: try #require(p.fetches.last), result: .ok)
        p.engine.shutdown()
        await expectSetOnlineIgnored(p)
    }

    // U02-F1 with a request in flight at shutdown: its cancel is the only effect, and its
    // late end is still accepted.
    @Test func setOnlineAfterShutdownWithARequestInFlightIsIgnored() async {
        let p = Probe()
        p.start()
        #expect(p.fetches.count == 1)
        p.engine.shutdown()
        #expect(p.cancels == p.fetches)
        await expectSetOnlineIgnored(p)
        p.engine.requestFinished(id: p.fetches.last ?? 0, result: .cancelled)
        #expect(p.engine.state(of: Probe.miami)?.loading == false)
    }
}
