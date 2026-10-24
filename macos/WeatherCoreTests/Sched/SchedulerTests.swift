// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SchedulerTests.swift - port of src/sched/test-scheduler.c (offline unit
// tests of WxScheduler) onto RefreshScheduler.
//
// Pure logic: no clock, no network. Every test drives the scheduler with a
// fake time held by the fixture (SchedFx, the port of the C `Fx`), which
// checks after every call the invariants of test-scheduler.c:69-122: at most
// one outstanding request per place, at most 3 in total, unique non-zero ids,
// CANCEL only for outstanding requests and at most once, no FETCH while
// inactive, inflightCount equal to the fixture's own count, and a deadline
// that exists exactly while active with a place, never more than a period
// ahead. Expected values are the C literals (cited per test as
// test-scheduler.c:<line>); the scheduler constants are re-stated here from
// wx-scheduler.h:90-106, never read from the code under test.

import Testing
@testable import WeatherCore

// MARK: - Literals of the C tests

/// Microseconds per second (test-scheduler.c:33).
private let SEC: Int64 = 1_000_000
/// WX_SCHED_PERIOD_US (wx-scheduler.h:90).
private let PERIOD_US: Int64 = 600 * SEC
/// WX_SCHED_FRESH_US (wx-scheduler.h:95).
private let FRESH_US: Int64 = 120 * SEC
/// WX_SCHED_PERIODIC_FRESH_US (wx-scheduler.h:100).
private let PERIODIC_FRESH_US: Int64 = 540 * SEC
/// WX_SCHED_MAX_INFLIGHT (wx-scheduler.h:102).
private let MAX_INFLIGHT = 3
/// WX_SCHED_JUMP_TOLERANCE_US (wx-scheduler.h:104).
private let JUMP_TOLERANCE_US: Int64 = 10 * SEC

// test-scheduler.c:35-39, 313
private let MIA = "25.7617,-80.1918"
private let TPA = "27.9506,-82.4572"
private let ORL = "28.5383,-81.3792"
private let LON = "51.5072,-0.1276"
private let TYO = "35.6762,139.6503"
private let SYD = "-33.8688,151.2093"

// test-scheduler.c:281-282
private let kThree = [MIA, TPA, ORL]
private let kFive = [MIA, TPA, ORL, LON, TYO]

private typealias Outcome = RefreshScheduler.Outcome
private typealias Kind = RefreshScheduler.ActionKind

// MARK: - Fixture (test-scheduler.c:47-310)

private struct Outstanding {
    var id: UInt64
    var key: String
    var cancelled: Bool
}

private final class SchedFx {
    var s = RefreshScheduler()
    var monoUS: Int64 = 1000 * SEC // test-scheduler.c:130
    var wallMS: Int64 = 1_790_000_000_000 // test-scheduler.c:131
    var visible = false
    var online = false
    /// Distinct valid tracked places, as the tests know them.
    var nPlaces = 0
    /// Everything emitted so far.
    var all: [RefreshScheduler.Action] = []
    /// Emitted by the latest call.
    var last: [RefreshScheduler.Action] = []
    var out: [Outstanding] = []
    private var seenIDs: Set<UInt64> = []

    var now: RefreshScheduler.Time { RefreshScheduler.Time(monoUS: monoUS, wallMS: wallMS) }

    private func check(_ ok: Bool, _ what: @autoclosure () -> String, _ loc: SourceLocation) {
        if !ok {
            Issue.record("fixture invariant: \(what()) [mono=\(monoUS) wall=\(wallMS)]", sourceLocation: loc)
        }
    }

    /// collect(): takes the actions of the latest call and checks every invariant.
    func collect(_ loc: SourceLocation = #_sourceLocation) {
        last = s.takeActions()
        for a in last {
            all.append(a)
            if a.kind == .cancel {
                var found = false
                for j in out.indices where out[j].id == a.id {
                    found = true
                    check(!out[j].cancelled, "never cancelled twice (id \(a.id))", loc)
                    out[j].cancelled = true
                }
                check(found, "CANCEL only for an outstanding request (id \(a.id))", loc)
                check(a.key == "", "CANCEL key is empty", loc)
                seenIDs.insert(a.id)
                continue
            }
            check(visible && online, "never a request while inactive", loc)
            check(a.id != 0, "FETCH id is not 0", loc)
            check(!a.key.isEmpty, "FETCH key is not empty", loc)
            for p in out {
                check(p.id != a.id, "id \(a.id) already outstanding", loc)
                check(p.key != a.key, "one request per place (\(a.key))", loc)
            }
            check(!seenIDs.contains(a.id), "ids never reused (\(a.id))", loc)
            seenIDs.insert(a.id)
            out.append(Outstanding(id: a.id, key: a.key, cancelled: false))
            check(out.count <= MAX_INFLIGHT, "at most \(MAX_INFLIGHT) in flight", loc)
        }
        check(s.inflightCount == out.count, "inflightCount \(s.inflightCount) == \(out.count)", loc)
        let wake = s.nextWakeupUS
        let armed = visible && online && nPlaces > 0
        check((wake >= 0) == armed, "deadline \(wake) exists iff armed (\(armed))", loc)
        if armed && monoUS <= Int64.max - PERIOD_US {
            check(wake <= monoUS + PERIOD_US, "deadline at most one period ahead", loc)
        }
    }

    /// fx_advance(): both clocks forward by `seconds`, saturating.
    func advance(_ seconds: Int64) {
        if monoUS > Int64.max - seconds * SEC { monoUS = Int64.max } else { monoUS += seconds * SEC }
        if wallMS > Int64.max - seconds * 1000 { wallMS = Int64.max } else { wallMS += seconds * 1000 }
    }

    /// fx_set_mono(): monotonic clock to the absolute `mono`, wall clock by the same amount.
    func setMono(_ mono: Int64, _ loc: SourceLocation = #_sourceLocation) {
        check(mono >= monoUS, "setMono goes forward", loc)
        wallMS += (mono - monoUS) / 1000
        monoUS = mono
    }

    /// fx_jump_wall(): only the wall clock.
    func jumpWall(_ seconds: Int64) {
        wallMS += seconds * 1000
    }

    func places(_ keys: [String?], _ loc: SourceLocation = #_sourceLocation) {
        s.setPlaces(keys, now: now)
        collect(loc)
    }

    func setKnown(_ keys: [String], _ loc: SourceLocation = #_sourceLocation) {
        nPlaces = keys.count
        places(keys, loc)
    }

    func select(_ key: String?, _ loc: SourceLocation = #_sourceLocation) {
        s.setSelection(key, now: now)
        collect(loc)
    }

    func setVisible(_ v: Bool, _ loc: SourceLocation = #_sourceLocation) {
        visible = v
        s.setVisible(v, now: now)
        collect(loc)
    }

    func setOnline(_ v: Bool, _ loc: SourceLocation = #_sourceLocation) {
        online = v
        s.setOnline(v, now: now)
        collect(loc)
    }

    func focus(_ loc: SourceLocation = #_sourceLocation) {
        s.focusRegained(now: now)
        collect(loc)
    }

    func tick(_ loc: SourceLocation = #_sourceLocation) {
        s.tick(now: now)
        collect(loc)
    }

    func done(_ id: UInt64, _ r: Outcome, _ loc: SourceLocation = #_sourceLocation) {
        s.requestDone(id: id, outcome: r, now: now)
        if let j = out.firstIndex(where: { $0.id == id }) {
            out.remove(at: j)
        }
        collect(loc)
    }

    /// fx_finish_all(): completes everything outstanding (and whatever that starts) with `r`.
    func finishAll(_ r: Outcome, _ loc: SourceLocation = #_sourceLocation) {
        var guardCount = 0
        while let first = out.first {
            guardCount += 1
            if guardCount >= 100_000 {
                Issue.record("finishAll did not converge", sourceLocation: loc)
                return
            }
            done(first.id, r, loc)
        }
    }

    func outID(_ key: String) -> UInt64 {
        out.first(where: { $0.key == key })?.id ?? 0
    }

    func outCancelled(_ key: String, _ loc: SourceLocation = #_sourceLocation) throws -> Bool {
        let o = try #require(out.first(where: { $0.key == key }), "outstanding \(key)", sourceLocation: loc)
        return o.cancelled
    }

    private static func count(_ arr: ArraySlice<RefreshScheduler.Action>, _ kind: Kind, _ key: String?) -> Int {
        arr.filter { $0.kind == kind && (key == nil || $0.key == key) }.count
    }

    func countAll(_ kind: Kind, _ key: String? = nil) -> Int { Self.count(all[...], kind, key) }
    func countLast(_ kind: Kind, _ key: String? = nil) -> Int { Self.count(last[...], kind, key) }
    func countSince(_ mark: Int, _ kind: Kind, _ key: String? = nil) -> Int {
        Self.count(all[mark...], kind, key)
    }

    /// NO_ACTIONS
    func noActions(_ loc: SourceLocation = #_sourceLocation) {
        #expect(last.isEmpty, "expected no actions, got \(last)", sourceLocation: loc)
    }

    /// ASSERT_LAST_LEN
    func lastLen(_ n: Int, _ loc: SourceLocation = #_sourceLocation) {
        #expect(last.count == n, "latest call emitted \(last)", sourceLocation: loc)
    }

    /// last_key()
    func lastKey(_ i: Int, _ loc: SourceLocation = #_sourceLocation) throws -> String {
        try #require(i < last.count, "action \(i) of \(last)", sourceLocation: loc)
        return last[i].key
    }

    /// fx_started(): visible + online + `keys`, nothing completed.
    static func started(_ keys: [String]) -> SchedFx {
        let fx = SchedFx()
        fx.setKnown(keys)
        fx.setOnline(true)
        fx.setVisible(true)
        return fx
    }

    /// fx_second_requests() (test-scheduler.c:331-348): MIA, TPA, ORL fetched at 1000 s, OK at
    /// 1100 s; a focus at 1230 s starts a second request for each.
    static func secondRequests() -> SchedFx {
        let fx = started(kThree)
        fx.setMono(1100 * SEC)
        fx.finishAll(.ok)
        #expect(fx.s.nextWakeupUS == 1600 * SEC)
        fx.setMono(1230 * SEC)
        fx.focus()
        #expect(fx.countLast(.fetch) == 3)
        return fx
    }
}

// MARK: - Suite

@Suite struct SchedulerTests {

    // Executor-added: the constants equal the C header literals.
    @Test("constants equal wx-scheduler.h:90-106")
    func constants() {
        #expect(RefreshScheduler.periodUS == 600 * 1_000_000) // wx-scheduler.h:90
        #expect(RefreshScheduler.freshUS == 120 * 1_000_000) // :95
        #expect(RefreshScheduler.periodicFreshUS == 540 * 1_000_000) // :100
        #expect(RefreshScheduler.maxInflight == 3) // :102
        #expect(RefreshScheduler.jumpToleranceUS == 10 * 1_000_000) // :104
        #expect(RefreshScheduler.keyBytes == 24) // :106
    }

    // MARK: Idle, rounds, in-flight cap, start order

    @Test("/sched/idle-has-no-actions-no-timer") // C: test-scheduler.c:355
    func idleHasNoActionsNoTimer() {
        let fx = SchedFx()
        #expect(fx.s.nextWakeupUS == -1)
        #expect(fx.s.takeActions().isEmpty)
        #expect(fx.s.inflightCount == 0)
        fx.setKnown(kThree)
        fx.noActions()
        fx.setVisible(true) // visible but offline
        fx.noActions()
        #expect(fx.s.nextWakeupUS == -1)
        fx.advance(600)
        fx.tick()
        fx.noActions()
        fx.setOnline(true) // now active: exactly one round
        #expect(fx.countLast(.fetch) == 3)
    }

    @Test("/sched/start-round-once-per-place") // C: test-scheduler.c:377
    func startRoundOncePerPlace() {
        let fx = SchedFx.started(kThree)
        fx.lastLen(3)
        #expect(fx.countLast(.fetch) == 3)
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US)
        #expect(fx.s.inflightCount == 3)

        fx.finishAll(.ok)
        for k in kThree {
            #expect(fx.countAll(.fetch, k) == 1)
            #expect(!fx.s.isStale(k))
        }
        #expect(fx.all.count == 3)
        #expect(fx.s.inflightCount == 0)
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US)

        // Showing again while already visible, or going online again: nothing.
        fx.setVisible(true)
        fx.setOnline(true)
        fx.noActions()
    }

    @Test("/sched/inflight-cap") // C: test-scheduler.c:402
    func inflightCap() throws {
        let fx = SchedFx.started(kFive)
        fx.lastLen(MAX_INFLIGHT)
        #expect(fx.s.inflightCount == MAX_INFLIGHT)
        // Asking again while requests are in flight or waiting does not duplicate anything.
        let mark = fx.all.count
        fx.focus()
        fx.focus()
        fx.setVisible(true)
        fx.setOnline(true)
        fx.noActions()
        #expect(fx.all.count == mark)
        // One completes: exactly one more starts, in list order.
        fx.done(fx.outID(MIA), .ok)
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == LON)
        fx.done(fx.outID(TPA), .failed)
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == TYO)
        // The failed request is not retried within the same round.
        fx.finishAll(.ok)
        #expect(fx.all.count == 5)
    }

    @Test("/sched/start-order-selected-first") // C: test-scheduler.c:429
    func startOrderSelectedFirst() throws {
        let fx = SchedFx()
        fx.setKnown(kFive)
        fx.select(LON) // the fourth place
        fx.setOnline(true)
        fx.setVisible(true)
        // Three slots: the selected place first, then list order.
        fx.lastLen(MAX_INFLIGHT)
        #expect(try fx.lastKey(0) == LON)
        #expect(try fx.lastKey(1) == MIA)
        #expect(try fx.lastKey(2) == TPA)
        fx.done(fx.outID(LON), .ok)
        #expect(try fx.lastKey(0) == ORL)
        fx.done(fx.outID(MIA), .ok)
        #expect(try fx.lastKey(0) == TYO)
        fx.finishAll(.ok)
    }

    // MARK: Selection

    @Test("/sched/selection/fetches-nothing") // C: test-scheduler.c:454
    func selectionFetchesNothing() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        let deadline = fx.s.nextWakeupUS
        fx.advance(500) // every success is old, yet changing the selection fetches nothing
        fx.select(TPA)
        fx.noActions()
        fx.select(ORL)
        fx.noActions()
        fx.select(nil)
        fx.noActions()
        #expect(fx.s.nextWakeupUS == deadline)
        for k in kThree {
            #expect(!fx.s.isStale(k)) // no stale mark changes
        }
    }

    @Test("/sched/selection/all-slots-busy") // C: test-scheduler.c:475
    func selectionAllSlotsBusy() throws {
        let fx = SchedFx.started(kFive) // MIA, TPA, ORL in flight; LON, TYO wait
        #expect(fx.s.inflightCount == MAX_INFLIGHT)
        fx.select(TYO)
        fx.noActions()
        #expect(fx.s.inflightCount == MAX_INFLIGHT)
        fx.done(fx.outID(MIA), .ok)
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == TYO) // ahead of LON
        // Selecting a place that is already in flight changes nothing either.
        fx.select(TPA)
        fx.noActions()
        fx.done(fx.outID(TPA), .ok)
        #expect(try fx.lastKey(0) == LON)
        fx.finishAll(.ok)
    }

    @Test("/sched/selection/invalid-or-untracked") // C: test-scheduler.c:495
    func selectionInvalidOrUntracked() throws {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        // An invalid selection is "none"; the selection need not be tracked (yet).
        fx.select("bad key")
        fx.select(nil)
        fx.select("")
        fx.select("1.0000,2.0000")
        fx.noActions()
        #expect(!fx.s.isStale("1.0000,2.0000"))
        // The untracked selection takes effect once the place appears: it goes first.
        fx.advance(10)
        fx.setKnown([MIA, TPA, ORL, LON, "1.0000,2.0000"])
        fx.lastLen(2) // the two new places (LON and the former selection), both fit
        #expect(try fx.lastKey(0) == "1.0000,2.0000")
        #expect(try fx.lastKey(1) == LON)
        fx.finishAll(.ok)
    }

    // MARK: Periodic rounds

    @Test("/sched/periodic/deadline-and-early-tick") // C: test-scheduler.c:522
    func periodicDeadlineAndEarlyTick() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        let deadline = fx.s.nextWakeupUS
        #expect(deadline == 1000 * SEC + PERIOD_US)

        fx.advance(300) // an early tick changes nothing
        fx.tick()
        fx.noActions()
        #expect(fx.s.nextWakeupUS == deadline)
        // An event round in between (the successes are 300 s old) does not move it.
        fx.focus()
        #expect(fx.countLast(.fetch) == 3)
        #expect(fx.s.nextWakeupUS == deadline)
        fx.finishAll(.ok)
        #expect(fx.s.nextWakeupUS == deadline)
    }

    @Test("/sched/periodic/skips-young-successes") // C: test-scheduler.c:543
    func periodicSkipsYoungSuccesses() {
        let fx = SchedFx.started(kThree)
        fx.advance(100)
        fx.finishAll(.ok) // successes at 1100 s
        let deadline = fx.s.nextWakeupUS
        #expect(deadline == 1600 * SEC)
        // The deadline finds the successes 500 s old, younger than 540 s: skipped.
        fx.setMono(deadline)
        fx.tick()
        fx.noActions()
        #expect(fx.s.nextWakeupUS == deadline + PERIOD_US)
        // One period later they are 1100 s old: a round for every place.
        fx.advance(600)
        fx.tick()
        #expect(fx.countLast(.fetch) == 3)
        #expect(fx.s.nextWakeupUS == deadline + 2 * PERIOD_US)
        fx.finishAll(.ok)
    }

    @Test("/sched/periodic/freshness-540s-is-stale") // C: test-scheduler.c:566
    func periodicFreshness540sIsStale() {
        let fx = SchedFx.started(kThree)
        fx.advance(60)
        fx.finishAll(.ok) // successes at 1060 s; the deadline is at 1600 s
        #expect(fx.s.nextWakeupUS - fx.monoUS == PERIODIC_FRESH_US)
        fx.setMono(fx.s.nextWakeupUS)
        fx.tick()
        #expect(fx.countLast(.fetch) == 3)
        fx.finishAll(.ok)
    }

    @Test("/sched/periodic/freshness-539s-is-fresh") // C: test-scheduler.c:580
    func periodicFreshness539sIsFresh() {
        let fx = SchedFx.started(kThree)
        fx.advance(61)
        fx.finishAll(.ok) // successes at 1061 s: 539 s before the deadline
        fx.setMono(fx.s.nextWakeupUS)
        fx.tick()
        fx.noActions()
    }

    @Test("/sched/periodic/late-and-no-catch-up") // C: test-scheduler.c:592
    func periodicLateAndNoCatchUp() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        let deadline = fx.s.nextWakeupUS
        fx.setMono(deadline)
        fx.tick()
        #expect(fx.countLast(.fetch) == 3)
        #expect(fx.s.nextWakeupUS == deadline + PERIOD_US)
        fx.finishAll(.ok)

        // Woken very late: one round, the next a full period later.
        fx.advance(3600)
        fx.tick()
        #expect(fx.countLast(.fetch) == 3)
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US)
        fx.finishAll(.ok)
        fx.tick() // the same instant again: no catch-up round
        fx.noActions()
    }

    @Test("/sched/periodic/merges-with-inflight") // C: test-scheduler.c:615
    func periodicMergesWithInflight() {
        let fx = SchedFx.started(kFive)
        // Slow responses: a periodic tick arrives while the first wave is still in flight.
        let deadline = fx.s.nextWakeupUS
        fx.setMono(deadline)
        let mark = fx.all.count
        fx.tick()
        fx.noActions()
        #expect(fx.countSince(mark, .fetch) == 0)
        // The places that were waiting are still waiting (merged), not duplicated.
        fx.finishAll(.ok)
        for k in kFive {
            #expect(fx.countAll(.fetch, k) == 1)
        }
    }

    // MARK: Event rounds: freshness window, show/hide, network, focus

    @Test("/sched/event/freshness-119s-is-fresh") // C: test-scheduler.c:637
    func eventFreshness119sIsFresh() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.advance(119)
        fx.focus()
        fx.noActions()
    }

    @Test("/sched/event/freshness-120s-is-stale") // C: test-scheduler.c:648
    func eventFreshness120sIsStale() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.advance(120)
        fx.focus()
        #expect(fx.countLast(.fetch) == 3)
        fx.finishAll(.ok)
    }

    @Test("/sched/event/and-periodic-windows-differ") // C: test-scheduler.c:662
    func eventAndPeriodicWindowsDiffer() {
        let fx = SchedFx.started(kThree)
        fx.advance(300)
        fx.finishAll(.ok) // successes at 1300 s; the deadline stays at 1600 s
        fx.setMono(1430 * SEC)
        fx.tick() // early
        fx.noActions()
        fx.setMono(1600 * SEC) // the successes are 300 s old
        fx.tick()
        fx.noActions() // the periodic round skips them ...
        fx.focus()
        #expect(fx.countLast(.fetch) == 3) // ... an event round does not
        fx.finishAll(.ok)
    }

    @Test("/sched/event/show-hide-cycle") // C: test-scheduler.c:680
    func eventShowHideCycle() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        // A hide/show cycle inside the window does not refetch; one outside does.
        fx.advance(5)
        fx.setVisible(false)
        fx.noActions() // nothing was in flight
        fx.advance(5)
        fx.setVisible(true)
        fx.noActions()
        fx.advance(200)
        fx.setVisible(false)
        fx.setVisible(true)
        #expect(fx.countLast(.fetch) == 3)
        fx.finishAll(.ok)
    }

    @Test("/sched/event/network-cycle") // C: test-scheduler.c:700
    func eventNetworkCycle() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.advance(10)
        fx.setOnline(false)
        fx.setOnline(true)
        fx.noActions() // inside the window
        fx.advance(130)
        fx.setOnline(false)
        fx.setOnline(true)
        #expect(fx.countLast(.fetch) == 3)
        fx.finishAll(.ok)
    }

    @Test("/sched/focus/regained-runs-one-round") // C: test-scheduler.c:717
    func focusRegainedRunsOneRound() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.advance(130)
        fx.focus()
        #expect(fx.countLast(.fetch) == 3)
        fx.focus() // a second focus event while the first round is in flight: merged
        fx.noActions()
        fx.finishAll(.ok)
        fx.focus() // just refreshed
        fx.noActions()
    }

    @Test("/sched/focus/while-offline") // C: test-scheduler.c:733
    func focusWhileOffline() {
        let fx = SchedFx()
        fx.setKnown(kThree)
        fx.setVisible(true) // visible, offline
        fx.focus()
        fx.noActions()
        #expect(fx.s.nextWakeupUS == -1)
        fx.advance(500)
        fx.focus()
        fx.noActions()
        fx.setOnline(true) // the reconnect is the event round
        #expect(fx.countLast(.fetch) == 3)
        fx.finishAll(.ok)
    }

    @Test("/sched/focus/while-hidden") // C: test-scheduler.c:751
    func focusWhileHidden() {
        let fx = SchedFx()
        fx.setKnown(kThree)
        fx.setOnline(true) // online, hidden
        fx.focus()
        fx.noActions()
        #expect(fx.s.nextWakeupUS == -1)
        fx.setVisible(true) // showing is the event round, exactly one
        #expect(fx.countLast(.fetch) == 3)
        fx.focus()
        fx.noActions()
        fx.finishAll(.ok)
    }

    @Test("/sched/focus/while-hidden-leaves-no-waiting-state") // C: test-scheduler.c:771
    func focusWhileHiddenLeavesNoWaitingState() {
        let fx = SchedFx.started(kThree)
        fx.setVisible(false)
        fx.lastLen(3) // three CANCELs
        fx.advance(1)
        fx.focus()
        fx.noActions()
        fx.finishAll(.ok)
        fx.noActions()
        fx.advance(1)
        fx.setVisible(true)
        fx.noActions() // every place succeeded 1 s ago
        #expect(fx.s.inflightCount == 0)
    }

    @Test("/sched/focus/while-offline-leaves-no-waiting-state") // C: test-scheduler.c:790
    func focusWhileOfflineLeavesNoWaitingState() {
        let fx = SchedFx.started(kThree)
        fx.setOnline(false)
        fx.lastLen(3)
        fx.advance(1)
        fx.focus()
        fx.noActions()
        fx.finishAll(.ok)
        fx.noActions()
        fx.advance(1)
        fx.setOnline(true)
        fx.noActions()
        #expect(fx.s.inflightCount == 0)
    }

    // MARK: Failure, cancellation and the memory of the latest success

    @Test("/sched/failure/marks-stale") // C: test-scheduler.c:812
    func failureMarksStale() {
        let fx = SchedFx.started(kThree)
        fx.done(fx.outID(MIA), .failed)
        fx.done(fx.outID(TPA), .ok)
        fx.done(fx.outID(ORL), .cancelled)
        #expect(fx.s.isStale(MIA))
        #expect(!fx.s.isStale(TPA))
        #expect(!fx.s.isStale(ORL)) // cancellation never marks stale
        // Nothing retries by itself.
        fx.advance(10)
        fx.tick() // no deadline has been reached
        fx.noActions()
        #expect(fx.s.isStale(MIA))
    }

    @Test("/sched/stale-query-edge-keys") // C: test-scheduler.c:830
    func staleQueryEdgeKeys() {
        let fx = SchedFx.started(kThree)
        fx.done(fx.outID(MIA), .failed)
        #expect(fx.s.isStale(MIA))
        #expect(!fx.s.isStale(LON)) // unknown
        #expect(!fx.s.isStale(nil))
        #expect(!fx.s.isStale("not a key"))
        #expect(!fx.s.isStale(""))
        #expect(!fx.s.isStale("25.7617,-80.1918 "))
        #expect(!fx.s.isStale("123456789012345678901234"))
        fx.finishAll(.ok)
    }

    @Test("/sched/failure/retried-by-event-round") // C: test-scheduler.c:846
    func failureRetriedByEventRound() {
        let fx = SchedFx.started(kThree)
        fx.done(fx.outID(MIA), .failed)
        fx.done(fx.outID(TPA), .ok)
        fx.done(fx.outID(ORL), .cancelled)
        fx.advance(10)
        // The failed place and the cancelled one (it never succeeded) are wanted, the fresh one not.
        fx.focus()
        fx.lastLen(2)
        #expect(fx.countLast(.fetch, MIA) == 1)
        #expect(fx.countLast(.fetch, ORL) == 1)
        #expect(fx.countLast(.fetch, TPA) == 0)
        #expect(fx.s.isStale(MIA)) // the mark stays until a success
        fx.done(fx.outID(MIA), .ok)
        #expect(!fx.s.isStale(MIA))
        fx.finishAll(.ok)
    }

    @Test("/sched/failure/stale-mark-survives-every-other-input") // C: test-scheduler.c:870
    func staleMarkSurvivesEveryOtherInput() {
        let fx = SchedFx.started(kThree)
        fx.done(fx.outID(MIA), .failed)
        fx.finishAll(.ok)
        #expect(fx.s.isStale(MIA))
        fx.setVisible(false)
        #expect(fx.s.isStale(MIA))
        fx.setOnline(false)
        #expect(fx.s.isStale(MIA))
        fx.setOnline(true) // hidden: no round
        fx.setVisible(true) // the round retries MIA; the request is outstanding, the mark stays
        #expect(fx.countLast(.fetch, MIA) == 1)
        #expect(fx.s.isStale(MIA))
        fx.select(MIA)
        #expect(fx.s.isStale(MIA))
        fx.select(TPA)
        fx.focus()
        fx.advance(700)
        fx.tick()
        #expect(fx.s.isStale(MIA))
        fx.setKnown([ORL, TPA, MIA])
        #expect(fx.s.isStale(MIA))
        // Only a success clears it (a cancelled completion does not).
        fx.setVisible(false)
        fx.finishAll(.cancelled)
        #expect(fx.s.isStale(MIA))
        fx.setVisible(true)
        #expect(fx.s.isStale(MIA))
        fx.done(fx.outID(MIA), .ok)
        #expect(!fx.s.isStale(MIA))
        fx.finishAll(.ok)
    }

    @Test("/sched/failure/retried-by-periodic-round") // C: test-scheduler.c:907
    func failureRetriedByPeriodicRound() {
        let fx = SchedFx.started(kThree)
        fx.done(fx.outID(MIA), .failed)
        fx.advance(100)
        fx.finishAll(.ok) // TPA, ORL succeed at 1100 s; MIA failed at 1000 s
        fx.setMono(fx.s.nextWakeupUS)
        fx.tick() // the others are 500 s old (fresh for periodic rounds); the failed one is wanted
        fx.lastLen(1)
        #expect(fx.countLast(.fetch, MIA) == 1)
        fx.finishAll(.ok)
    }

    @Test("/sched/failure/forgets-earlier-success") // C: test-scheduler.c:925
    func failureForgetsEarlierSuccess() throws {
        let fx = SchedFx.secondRequests()
        fx.advance(1)
        fx.done(fx.outID(MIA), .failed)
        fx.done(fx.outID(TPA), .ok)
        fx.done(fx.outID(ORL), .ok)
        #expect(fx.s.isStale(MIA))
        fx.setMono(1600 * SEC)
        fx.tick()
        fx.lastLen(1) // TPA, ORL: successes 369 s old, skipped
        #expect(try fx.lastKey(0) == MIA)
        fx.finishAll(.ok)
    }

    @Test("/sched/cancelled-newest-request-keeps-earlier-success") // C: test-scheduler.c:945
    func cancelledNewestRequestKeepsEarlierSuccess() {
        let fx = SchedFx.secondRequests()
        fx.advance(1)
        fx.done(fx.outID(MIA), .cancelled) // the owner cancelled it itself
        fx.done(fx.outID(TPA), .ok)
        fx.done(fx.outID(ORL), .ok)
        #expect(!fx.s.isStale(MIA))
        fx.setMono(1600 * SEC)
        fx.tick()
        fx.noActions() // MIA: success 500 s old; TPA, ORL: 369 s old
        fx.setMono(2200 * SEC)
        fx.tick() // after the window: everything is old
        #expect(fx.countLast(.fetch) == 3)
        fx.finishAll(.ok)
    }

    @Test("/sched/cancelled-newest-request-event-round-wants-again") // C: test-scheduler.c:966
    func cancelledNewestRequestEventRoundWantsAgain() throws {
        let fx = SchedFx.secondRequests()
        fx.advance(1)
        fx.done(fx.outID(MIA), .cancelled)
        fx.done(fx.outID(TPA), .ok)
        fx.done(fx.outID(ORL), .ok)
        fx.advance(9)
        fx.focus()
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == MIA)
        fx.finishAll(.ok)
    }

    @Test("/sched/ok-after-cancel-counts-as-success") // C: test-scheduler.c:984
    func okAfterCancelCountsAsSuccess() throws {
        let fx = SchedFx.started(kThree)
        fx.advance(1)
        fx.setVisible(false)
        #expect(fx.countLast(.cancel) == 3)
        fx.done(fx.outID(MIA), .ok) // finished before it noticed the cancel
        fx.done(fx.outID(TPA), .cancelled)
        fx.done(fx.outID(ORL), .failed) // failed on the way down
        fx.noActions()
        #expect(!fx.s.isStale(MIA))
        #expect(!fx.s.isStale(TPA))
        #expect(fx.s.isStale(ORL))
        fx.advance(1)
        fx.setVisible(true)
        fx.lastLen(2) // MIA is fresh: skipped
        #expect(fx.countLast(.fetch, MIA) == 0)
        fx.finishAll(.ok)
        // MIA's success is dated t = 1001 s, TPA's and ORL's t = 1002 s. At 1120 s MIA is 119 s old.
        fx.advance(118)
        fx.focus()
        fx.noActions()
        // At t = 1121 s MIA is exactly 120 s old and wanted; TPA and ORL are 119 s old and not.
        fx.advance(1)
        fx.focus()
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == MIA)
        fx.finishAll(.ok)
    }

    @Test("/sched/cancelled-never-fresh") // C: test-scheduler.c:1017
    func cancelledNeverFresh() {
        let fx = SchedFx.started(kThree)
        fx.advance(1)
        fx.setVisible(false)
        fx.finishAll(.cancelled)
        // Nothing arrived: showing a second later wants every place.
        fx.advance(1)
        fx.setVisible(true)
        #expect(fx.countLast(.fetch) == 3)
        // A success then makes only that place fresh.
        fx.done(fx.outID(MIA), .ok)
        fx.done(fx.outID(TPA), .cancelled)
        fx.done(fx.outID(ORL), .failed)
        fx.advance(1)
        fx.focus()
        fx.lastLen(2)
        #expect(fx.countLast(.fetch, MIA) == 0)
        fx.finishAll(.ok)
    }

    @Test("/sched/hide-cancels-and-drops-waiting") // C: test-scheduler.c:1040
    func hideCancelsAndDropsWaiting() {
        let fx = SchedFx.started(kFive)
        #expect(fx.s.inflightCount == 3)
        let idMIA = fx.outID(MIA)
        fx.setVisible(false)
        #expect(fx.countLast(.cancel) == 3)
        #expect(fx.s.nextWakeupUS == -1)
        // Cancelled requests keep their slots until reported; nothing waiting starts.
        #expect(fx.s.inflightCount == 3)
        fx.done(idMIA, .cancelled)
        fx.noActions()
        #expect(!fx.s.isStale(MIA))
        fx.finishAll(.cancelled)
        fx.noActions() // the dropped waiting places (LON, TYO) did not start
        #expect(fx.countAll(.fetch, LON) == 0)
        #expect(fx.countAll(.fetch, TYO) == 0)
    }

    @Test("/sched/show-before-cancelled-requests-reported") // C: test-scheduler.c:1063
    func showBeforeCancelledRequestsReported() throws {
        let fx = SchedFx.started(kFive)
        fx.setVisible(false)
        fx.done(fx.outID(MIA), .cancelled)
        fx.setVisible(true)
        fx.lastLen(1)
        #expect(fx.countLast(.fetch, MIA) == 1) // its slot was freed
        #expect(try fx.outCancelled(TPA))
        #expect(try fx.outCancelled(ORL))
        #expect(fx.countAll(.fetch, TPA) == 1)
        #expect(fx.s.inflightCount == 3)
        fx.done(fx.outID(TPA), .cancelled)
        #expect(fx.countLast(.fetch, TPA) == 1) // the freed slot restarts it
        fx.finishAll(.ok)
        for k in kFive {
            #expect(fx.countAll(.fetch, k) >= 1)
        }
    }

    @Test("/sched/hide-show-hide-before-cancels-reported") // C: test-scheduler.c:1088
    func hideShowHideBeforeCancelsReported() {
        let fx = SchedFx.started(kThree)
        fx.setVisible(false)
        fx.lastLen(3)
        fx.advance(1)
        fx.setVisible(true)
        fx.noActions() // the places wait for their cancelled requests
        fx.setVisible(false)
        fx.noActions() // already being cancelled: no second CANCEL
        fx.finishAll(.ok)
        fx.noActions()
        fx.advance(1)
        fx.setVisible(true)
        fx.noActions()
        #expect(fx.s.inflightCount == 0)
    }

    @Test("/sched/offline-cancels-and-back-online") // C: test-scheduler.c:1108
    func offlineCancelsAndBackOnline() {
        let fx = SchedFx.started(kThree)
        fx.setOnline(false)
        #expect(fx.countLast(.cancel) == 3)
        #expect(fx.s.nextWakeupUS == -1)
        fx.finishAll(.cancelled)
        fx.noActions()
        #expect(!fx.s.isStale(MIA))
        fx.advance(5)
        fx.focus() // offline: nothing
        fx.noActions()
        fx.setOnline(true) // the cancelled requests delivered nothing: all wanted again
        #expect(fx.countLast(.fetch) == 3)
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US)
        fx.finishAll(.ok)
        // Hiding and losing the network with nothing in flight emits nothing at all.
        fx.setVisible(false)
        fx.setOnline(false)
        fx.noActions()
    }

    @Test("/sched/dropped-waiting-wanted-again") // C: test-scheduler.c:1132
    func droppedWaitingWantedAgain() {
        let fx = SchedFx.started(kFive) // LON and TYO wait for a slot
        fx.setVisible(false)
        fx.finishAll(.cancelled)
        #expect(fx.countAll(.fetch, LON) == 0)
        fx.setVisible(true)
        fx.finishAll(.ok)
        #expect(fx.countAll(.fetch, LON) == 1)
        #expect(fx.countAll(.fetch, TYO) == 1)
    }

    // MARK: Timer

    @Test("/sched/timer/when-hidden-or-offline") // C: test-scheduler.c:1150
    func noTimerWhenHiddenOrOffline() {
        let fx = SchedFx.started(kThree)
        #expect(fx.s.nextWakeupUS >= 0)
        fx.setVisible(false)
        #expect(fx.s.nextWakeupUS == -1)
        fx.finishAll(.cancelled)
        fx.advance(50)
        fx.setVisible(true)
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US) // fresh
        fx.setOnline(false)
        #expect(fx.s.nextWakeupUS == -1)
        fx.finishAll(.cancelled)
        fx.advance(50)
        fx.setOnline(true)
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US)
        fx.finishAll(.ok)
    }

    @Test("/sched/timer/without-places") // C: test-scheduler.c:1171
    func noTimerWithoutPlaces() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.setKnown([])
        #expect(fx.s.nextWakeupUS == -1)
        fx.advance(1000)
        fx.tick()
        fx.noActions()
        fx.setKnown([MIA]) // the first place arms a fresh deadline and is fetched at once
        #expect(fx.countLast(.fetch, MIA) == 1)
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US)
        fx.finishAll(.ok)
    }

    @Test("/sched/tick-while-hidden-does-nothing") // C: test-scheduler.c:1189
    func tickWhileHiddenDoesNothing() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.setVisible(false)
        fx.advance(2000) // a deadline that fires while hidden (the tick arrives late)
        fx.tick()
        fx.noActions()
        #expect(fx.s.nextWakeupUS == -1)
    }

    // MARK: The tracked set

    @Test("/sched/place/added-fetched-at-once") // C: test-scheduler.c:1206
    func placeAddedFetchedAtOnce() throws {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        let deadline = fx.s.nextWakeupUS
        fx.advance(10)
        // A new place is fetched at once; the kept ones are fresh and not refetched.
        fx.setKnown([MIA, TPA, ORL, LON])
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == LON)
        #expect(fx.s.nextWakeupUS == deadline) // the deadline is kept
        #expect(fx.s.inflightCount == 1)
        fx.finishAll(.ok)
    }

    @Test("/sched/place/reorder-keeps-state") // C: test-scheduler.c:1224
    func placeReorderKeepsState() throws {
        let fx = SchedFx.started(kThree)
        fx.done(fx.outID(MIA), .failed)
        fx.done(fx.outID(TPA), .ok)
        fx.done(fx.outID(ORL), .ok)
        fx.setKnown([ORL, MIA, TPA])
        fx.noActions() // reordering fetches nothing and keeps every state
        #expect(fx.s.isStale(MIA))
        #expect(!fx.s.isStale(TPA))
        fx.advance(130)
        fx.focus() // list order now: ORL, MIA, TPA
        fx.lastLen(3)
        #expect(try fx.lastKey(0) == ORL)
        #expect(try fx.lastKey(1) == MIA)
        #expect(try fx.lastKey(2) == TPA)
        fx.finishAll(.ok)
    }

    @Test("/sched/place/removed-cancels-request") // C: test-scheduler.c:1248
    func placeRemovedCancelsRequest() {
        let fx = SchedFx.started(kFive) // MIA, TPA, ORL in flight; LON, TYO wait
        fx.setKnown([LON, TYO])
        #expect(fx.countLast(.cancel) == 3)
        #expect(fx.countLast(.fetch) == 0) // the cap counts cancelled requests
        #expect(fx.s.inflightCount == 3)
        fx.done(fx.outID(MIA), .cancelled)
        #expect(fx.countLast(.fetch, LON) == 1)
        fx.done(fx.outID(TPA), .failed) // a removed place's result marks nothing
        #expect(!fx.s.isStale(TPA))
        #expect(fx.countLast(.fetch, TYO) == 1)
        fx.done(fx.outID(ORL), .ok)
        #expect(!fx.s.isStale(ORL))
        fx.finishAll(.ok)
        #expect(fx.s.inflightCount == 0)
    }

    @Test("/sched/place/removed-has-no-stale-mark") // C: test-scheduler.c:1271
    func placeRemovedHasNoStaleMark() throws {
        let fx = SchedFx.started(kThree)
        fx.done(fx.outID(MIA), .failed)
        fx.done(fx.outID(TPA), .ok)
        fx.done(fx.outID(ORL), .ok)
        #expect(fx.s.isStale(MIA))
        fx.advance(10)
        fx.focus() // the failed place is retried
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == MIA)
        #expect(fx.s.isStale(MIA)) // the mark stays while the retry runs
        fx.setKnown([TPA, ORL])
        #expect(fx.countLast(.cancel) == 1)
        #expect(!fx.s.isStale(MIA)) // removed: no mark, though the entry lingers
        #expect(fx.s.inflightCount == 1)
        fx.done(fx.outID(MIA), .cancelled)
        #expect(!fx.s.isStale(MIA))
        fx.advance(1)
        fx.setKnown(kThree) // added back: a new place without a mark
        #expect(!fx.s.isStale(MIA))
        #expect(fx.countLast(.fetch, MIA) == 1)
        fx.finishAll(.ok)
    }

    @Test("/sched/place/removed-while-waiting") // C: test-scheduler.c:1299
    func placeRemovedWhileWaiting() throws {
        let fx = SchedFx.started(kFive) // LON waits
        fx.setKnown([MIA, TPA, ORL, TYO])
        fx.noActions() // nothing in flight for LON: nothing to cancel
        fx.done(fx.outID(MIA), .ok)
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == TYO)
        fx.finishAll(.ok)
        #expect(fx.countAll(.fetch, LON) == 0)
    }

    @Test("/sched/place/readded-after-cancel-reported") // C: test-scheduler.c:1314
    func placeReaddedAfterCancelReported() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.advance(1)
        let four = [MIA, TPA, ORL, LON]
        fx.setKnown(four)
        fx.done(fx.outID(LON), .failed)
        #expect(fx.s.isStale(LON))
        fx.setKnown(kThree) // LON removed: its mark is gone, nothing in flight
        #expect(!fx.s.isStale(LON))
        fx.noActions()
        fx.setKnown(four) // a new place again: no mark, fetched at once
        #expect(!fx.s.isStale(LON))
        #expect(fx.countLast(.fetch, LON) == 1)
        fx.finishAll(.ok)
    }

    @Test("/sched/place/revived-while-request-winds-down") // C: test-scheduler.c:1336
    func placeRevivedWhileRequestWindsDown() throws {
        let fx = SchedFx.started(kThree)
        fx.done(fx.outID(MIA), .failed)
        #expect(fx.s.isStale(MIA))
        let two = [TPA, ORL]
        fx.setKnown(two) // MIA is out of the set; TPA, ORL stay in flight
        #expect(!fx.s.isStale(MIA))
        // Remove TPA while it is in flight, then add it back: it is revived.
        fx.setKnown([ORL])
        #expect(fx.countLast(.cancel) == 1)
        #expect(fx.s.inflightCount == 2)
        fx.setKnown(two)
        fx.noActions() // no second request while the first winds down
        #expect(fx.s.inflightCount == 2)
        #expect(try fx.outCancelled(TPA))
        #expect(!fx.s.isStale(TPA))
        fx.done(fx.outID(TPA), .cancelled)
        fx.lastLen(1) // now the revived place starts
        #expect(fx.countLast(.fetch, TPA) == 1)
        #expect(try !fx.outCancelled(TPA))
        fx.finishAll(.ok)
    }

    @Test("/sched/place/clear-all") // C: test-scheduler.c:1362
    func placeClearAll() {
        let fx = SchedFx.started(kThree)
        fx.setKnown([])
        #expect(fx.countLast(.cancel) == 3)
        #expect(fx.s.nextWakeupUS == -1)
        #expect(fx.s.inflightCount == 3) // still outstanding until reported
        fx.finishAll(.cancelled)
        #expect(fx.s.inflightCount == 0)
        for k in kThree {
            #expect(!fx.s.isStale(k))
        }
        fx.focus()
        fx.noActions()
    }

    @Test("/sched/places-added-while-inactive-wait") // C: test-scheduler.c:1379
    func placesAddedWhileInactiveWait() throws {
        let fx = SchedFx()
        fx.setKnown(kThree)
        fx.noActions()
        fx.setOnline(true)
        fx.noActions()
        fx.setVisible(true)
        #expect(fx.countLast(.fetch) == 3)
        fx.finishAll(.ok)
        // Hidden again: a new place does not fetch until the next event round.
        fx.setVisible(false)
        fx.advance(1)
        fx.setKnown([MIA, TPA, ORL, LON])
        fx.noActions()
        fx.setVisible(true)
        fx.lastLen(1) // only the new place: the others are fresh
        #expect(try fx.lastKey(0) == LON)
        fx.finishAll(.ok)
    }

    @Test("/sched/remove-selected-place") // C: test-scheduler.c:1406
    func removeSelectedPlace() throws {
        let fx = SchedFx()
        fx.setKnown(kFive)
        fx.select(TYO)
        fx.setOnline(true)
        fx.setVisible(true)
        #expect(try fx.lastKey(0) == TYO) // TYO, MIA, TPA in flight; ORL, LON wait
        fx.setKnown([MIA, TPA, ORL, LON])
        fx.lastLen(1)
        #expect(fx.countLast(.cancel) == 1)
        #expect(try fx.outCancelled(TYO))
        fx.done(fx.outID(TYO), .cancelled)
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == ORL) // list order: the removed selection has no say
        fx.done(fx.outID(MIA), .ok)
        #expect(try fx.lastKey(0) == LON)
        // Add the selected place back together with a new place that precedes it in the list.
        fx.setKnown([SYD, MIA, TPA, ORL, LON, TYO])
        #expect(fx.s.inflightCount == 3) // TPA, ORL, LON: SYD and TYO wait
        fx.noActions()
        fx.done(fx.outID(TPA), .ok)
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == TYO) // the selection first, though SYD is earlier
        fx.done(fx.outID(ORL), .ok)
        #expect(try fx.lastKey(0) == SYD)
        fx.finishAll(.ok)
    }

    // MARK: Keys

    @Test("/sched/key/validation") // C: test-scheduler.c:1443
    func keyValidation() throws {
        let fx = SchedFx()
        fx.setOnline(true)
        fx.setVisible(true)
        let k23 = "12345678901234567890.-," // 23 characters of the alphabet
        let keys: [String?] = [
            nil,
            "",
            "abc",
            "25.7617, -80.1918",
            "25.7617;-80.1918",
            " 25.7617,-80.1918",
            "25.7617,-80.1918\n",
            "../../etc",
            "%s",
            "\u{e9}", // "\xc3\xa9"
            "123456789012345678901234", // 24 characters: too long
            "1234567890123456789012345678901234567890",
            MIA,
            MIA, // repeat
            k23,
            "-1.5000,2.5000",
        ]
        fx.s.setPlaces(keys, now: fx.now)
        fx.nPlaces = 3 // MIA, the 23-character key, -1.5/2.5
        fx.collect()
        fx.lastLen(3)
        #expect(try fx.lastKey(0) == MIA)
        #expect(try fx.lastKey(1) == k23)
        #expect(try fx.lastKey(2) == "-1.5000,2.5000")
        #expect(!fx.s.isStale("123456789012345678901234"))
        fx.done(fx.outID(k23), .failed)
        #expect(fx.s.isStale(k23))
        #expect(!fx.s.isStale("123456789012345678901234"))
        fx.finishAll(.ok)
        // An empty list is allowed.
        fx.nPlaces = 0
        fx.s.setPlaces([], now: fx.now)
        fx.collect()
    }

    // C: /sched/key/guard-pages — behavioural part only. The C case proves that
    // at most WX_SCHED_KEY_BYTES bytes are read from an unterminated buffer at
    // a guard page (C-INTERNAL: a Swift String carries its length). Ported: a
    // 24-byte key with no terminator inside the first 24 bytes is rejected
    // whatever its first byte (0 makes it empty), a key whose terminator is
    // the 24th byte is accepted, and the action order CANCEL-then-FETCH.
    @Test("/sched/key/guard-pages (behavioural part)") // C: test-scheduler.c:1486
    func keyGuardPages() throws {
        let fx = SchedFx()
        fx.setOnline(true)
        fx.setVisible(true)
        for first in 0..<256 {
            let lead = String(Character(Unicode.Scalar(UInt8(first))))
            let buf = lead + String(repeating: "1", count: 23)
            fx.places([buf]) // never a terminator within 24 bytes (or an empty key): rejected
            fx.select(buf)
            #expect(!fx.s.isStale(buf))
        }
        // A valid key.
        fx.nPlaces = 1
        fx.places([MIA])
        fx.lastLen(1)
        #expect(try fx.lastKey(0) == MIA)
        // A 23-character key whose terminator is the 24th byte.
        let b23 = String(repeating: "7", count: 23)
        fx.places([b23])
        #expect(fx.countLast(.fetch) == 1) // the 23-character key
        #expect(try fx.lastKey(1) == "77777777777777777777777")
        #expect(fx.countLast(.cancel) == 1) // MIA left the set
    }

    // MARK: requestDone edge cases

    @Test("/sched/request-done/unknown-ids") // C: test-scheduler.c:1540
    func requestDoneUnknownIDs() {
        let fx = SchedFx.started(kThree)
        // Unknown, zero and huge ids are ignored, whatever the result.
        let ids: [UInt64] = [0, UInt64.max, 9999, 4]
        for id in ids {
            fx.s.requestDone(id: id, outcome: .failed, now: fx.now)
            fx.collect()
            fx.s.requestDone(id: id, outcome: .ok, now: fx.now)
            fx.collect()
        }
        fx.noActions()
        #expect(fx.s.inflightCount == 3)
        for k in kThree {
            #expect(!fx.s.isStale(k))
        }
        fx.finishAll(.ok)
    }

    // C: /sched/request-done/unknown-result — adapted. The C case passes
    // (WxSchedResult)42, which wx-scheduler.h:328-330 says is handled like
    // CANCELLED. Outcome is a closed Swift enum, so an out-of-range value
    // cannot be constructed; the scenario is run with .cancelled, the value the
    // C contract maps it to, and keeps every C assertion.
    @Test("/sched/request-done/unknown-result (adapted: closed enum, mapped to cancelled)") // C: test-scheduler.c:1562
    func requestDoneUnknownResult() throws {
        let fx = SchedFx.started(kThree)
        let id = fx.outID(MIA)
        fx.s.requestDone(id: id, outcome: .cancelled, now: fx.now)
        if let j = fx.out.firstIndex(where: { $0.id == id }) {
            fx.out.remove(at: j)
        }
        fx.collect()
        #expect(!fx.s.isStale(MIA))
        #expect(fx.s.inflightCount == 2)
        fx.advance(1)
        fx.finishAll(.ok)
        fx.focus()
        fx.lastLen(1) // MIA never succeeded: wanted; the others are fresh
        #expect(try fx.lastKey(0) == MIA)
        fx.finishAll(.ok)
    }

    @Test("/sched/request-done/twice") // C: test-scheduler.c:1585
    func requestDoneTwice() {
        let fx = SchedFx.started(kThree)
        let id = fx.outID(MIA)
        fx.done(id, .ok)
        // Reporting the same request twice is ignored: no second effect, no mark.
        fx.s.requestDone(id: id, outcome: .failed, now: fx.now)
        fx.collect()
        #expect(!fx.s.isStale(MIA))
        #expect(fx.s.inflightCount == 2)
        fx.finishAll(.ok)
        // The place with the doubled report is fresh from the first one.
        fx.advance(100)
        fx.focus()
        fx.noActions()
    }

    // MARK: Clocks

    @Test("/sched/clock/forward-jump-makes-deadline-due") // C: test-scheduler.c:1608
    func clockForwardJumpMakesDeadlineDue() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        let deadline = fx.s.nextWakeupUS
        // Suspend/resume: the wall clock jumps by an hour, the monotonic clock by one second.
        fx.monoUS += 1 * SEC
        fx.jumpWall(1)
        fx.jumpWall(3600)
        fx.focus() // any input with a time notices the jump; the successes are 1 s old
        fx.noActions()
        #expect(fx.s.nextWakeupUS == fx.monoUS) // due now
        #expect(fx.s.nextWakeupUS < deadline)
        fx.tick()
        // The successes are 1 s old: the periodic round skips them; there is no burst of rounds.
        fx.noActions()
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US)
        fx.tick()
        fx.noActions()
    }

    @Test("/sched/clock/forward-jump-refetches-old-data") // C: test-scheduler.c:1632
    func clockForwardJumpRefetchesOldData() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.monoUS += 1000 * SEC
        fx.wallMS += 1000 * 1000 + 3600 * 1000
        fx.tick()
        #expect(fx.countLast(.fetch) == 3)
        #expect(fx.s.nextWakeupUS == fx.monoUS + PERIOD_US)
        fx.finishAll(.ok)
        fx.tick()
        fx.noActions()
    }

    @Test("/sched/clock/jump-tolerance-boundary") // C: test-scheduler.c:1649
    func clockJumpToleranceBoundary() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        let deadline = fx.s.nextWakeupUS
        fx.monoUS += 1 * SEC
        fx.wallMS += 1000 + JUMP_TOLERANCE_US / 1000
        fx.focus()
        #expect(fx.s.nextWakeupUS == deadline)
        fx.wallMS += 1 + JUMP_TOLERANCE_US / 1000
        fx.focus() // the wall clock advanced 10.001 s more than the monotonic one
        #expect(fx.s.nextWakeupUS == fx.monoUS)
    }

    @Test("/sched/clock/jump-noticed-by-every-input", arguments: 0..<7) // C: test-scheduler.c:1666
    func clockJumpNoticedByEveryInput(input: Int) {
        // SET_PLACES, SET_SELECTION, SET_VISIBLE, SET_ONLINE, FOCUS, REQUEST_DONE, TICK
        let tickInput = 6
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.monoUS += 1 * SEC
        fx.jumpWall(1 + 3600)
        switch input {
        case 0: fx.places(kThree)
        case 1: fx.select(TPA)
        case 2: fx.setVisible(true) // unchanged: still notices
        case 3: fx.setOnline(true)
        case 4: fx.focus()
        case 5:
            fx.s.requestDone(id: 12345, outcome: .ok, now: fx.now)
            fx.collect()
        default: fx.tick()
        }
        fx.noActions() // the successes are 1 s old
        let want = input == tickInput ? fx.monoUS + PERIOD_US : fx.monoUS
        #expect(fx.s.nextWakeupUS == want, "input \(input)")
    }

    @Test("/sched/clock/jump-without-deadline") // C: test-scheduler.c:1708
    func clockJumpWithoutDeadline() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        fx.setVisible(false)
        fx.monoUS += 1 * SEC
        fx.jumpWall(1 + 7200)
        fx.focus() // hidden
        fx.noActions()
        #expect(fx.s.nextWakeupUS == -1)
        fx.tick()
        fx.noActions()
        fx.setKnown([])
        fx.setVisible(true) // active but no places
        fx.jumpWall(7200)
        fx.tick()
        fx.noActions()
        #expect(fx.s.nextWakeupUS == -1)
    }

    @Test("/sched/clock/backward-jump-changes-nothing") // C: test-scheduler.c:1730
    func clockBackwardJumpChangesNothing() {
        let fx = SchedFx.started(kThree)
        fx.finishAll(.ok)
        let deadline = fx.s.nextWakeupUS
        fx.wallMS -= 7 * 24 * 3600 * 1000
        fx.focus()
        fx.noActions()
        #expect(fx.s.nextWakeupUS == deadline)
        fx.advance(600)
        fx.tick()
        #expect(fx.countLast(.fetch) == 3)
    }

    @Test("/sched/extreme-clock-values") // C: test-scheduler.c:1746
    func extremeClockValues() {
        let monos: [Int64] = [Int64.max, Int64.max - 5 * SEC, 0, 1, Int64.max - PERIOD_US,
                              Int64.max - PERIOD_US + 1, Int64.max / 2]
        let walls: [Int64] = [Int64.max, Int64.min, 0, -1, Int64.max - 5, Int64.min + 5]
        for (i, mono) in monos.enumerated() {
            for (j, wall) in walls.enumerated() {
                let fx = SchedFx()
                fx.monoUS = mono
                fx.wallMS = wall
                fx.setKnown(kThree)
                fx.setOnline(true)
                fx.setVisible(true)
                #expect(fx.countLast(.fetch) == 3, "mono[\(i)] wall[\(j)]")
                // The deadline saturates instead of overflowing.
                if mono > Int64.max - PERIOD_US {
                    #expect(fx.s.nextWakeupUS == Int64.max, "mono[\(i)] wall[\(j)]")
                }
                fx.finishAll(.ok)
                // Time moves by saturating steps; nothing may overflow or trap.
                fx.advance(1)
                fx.focus()
                fx.advance(700)
                fx.tick()
                fx.finishAll(.failed)
                fx.advance(100_000)
                fx.tick()
                fx.focus()
                fx.finishAll(.ok)
                fx.wallMS = j % 2 != 0 ? Int64.min : Int64.max // the wall clock jumps across its range
                fx.tick()
                fx.focus()
                fx.wallMS = j % 2 != 0 ? Int64.max : Int64.min
                fx.tick()
                fx.setVisible(false)
                fx.setVisible(true)
                fx.finishAll(.ok)
            }
        }
    }

    // MARK: Preconditions and the action array

    // C: /sched/preconditions/negative-mono — behavioural part. The g_return
    // critical message is GLIB-INTERNAL; the behaviour "a negative monotonic
    // time changes nothing and the scheduler stays usable" is ported.
    @Test("/sched/preconditions/negative-mono (behavioural part)") // C: test-scheduler.c:1845
    func preconditionsNegativeMono() {
        let neg = RefreshScheduler.Time(monoUS: -1, wallMS: 0)
        var s = RefreshScheduler()
        s.setPlaces([MIA], now: neg)
        s.setSelection(MIA, now: neg)
        s.setVisible(true, now: neg)
        s.setOnline(true, now: neg)
        s.focusRegained(now: neg)
        s.tick(now: neg)
        s.requestDone(id: 1, outcome: .ok, now: neg)
        // The failed calls changed nothing.
        #expect(s.nextWakeupUS == -1)
        #expect(s.takeActions().isEmpty)
        #expect(s.inflightCount == 0)
        // The scheduler is still fully usable afterwards.
        let ok = RefreshScheduler.Time(monoUS: 5 * SEC, wallMS: 0)
        s.setPlaces([MIA], now: ok)
        s.setOnline(true, now: ok)
        s.setVisible(true, now: ok)
        #expect(s.inflightCount == 1)
    }

    @Test("/sched/take-actions-drains") // C: test-scheduler.c:1885
    func takeActionsDrains() {
        let fx = SchedFx()
        fx.setKnown(kThree)
        fx.setOnline(true)
        fx.s.setVisible(true, now: fx.now)
        fx.visible = true
        let a = fx.s.takeActions()
        #expect(a.count == 3)
        #expect(fx.s.takeActions().isEmpty) // drained
        // The array is the caller's: it survives further calls.
        fx.advance(1)
        fx.s.setVisible(false, now: fx.now)
        fx.visible = false
        let b = fx.s.takeActions()
        #expect(b.count == 3)
        #expect(a.first?.kind == .fetch)
        #expect(b.first?.kind == .cancel)
        #expect(b.first?.id == a.first?.id)
    }

    // C: /sched/untaken-actions-freed-with-scheduler — the leak check itself is
    // C-INTERNAL (ARC frees the value); the observable assertion is ported.
    @Test("/sched/untaken-actions-freed-with-scheduler (observable part)") // C: test-scheduler.c:1915
    func untakenActionsFreedWithScheduler() {
        var s = RefreshScheduler()
        let t = RefreshScheduler.Time(monoUS: 5 * SEC, wallMS: 0)
        s.setPlaces([MIA, TPA], now: t)
        s.setOnline(true, now: t)
        s.setVisible(true, now: t)
        #expect(s.inflightCount == 2)
    }

    // MARK: Random walks (seeded with SeededRNG instead of GRand; the oracles are the C ones)

    // test-scheduler.c:1933
    private static let kPool = [MIA, TPA, ORL, LON, TYO, "-33.8688,151.2093", "0.0000,0.0000"]

    @Test("/sched/random-walk") // C: test-scheduler.c:1941
    func randomWalkInvariants() {
        let pool = Self.kPool
        let n = pool.count
        for seed in 1...fuzzIterations(40) {
            var rnd = SeededRNG(seed: UInt64(seed))
            let fx = SchedFx()
            var lastOK = [Int64](repeating: -1, count: n) // mono time of the latest success, -1 none
            var failed = [Bool](repeating: false, count: n)
            var tracked = [Bool](repeating: false, count: n)
            var expectStale = [Bool](repeating: false, count: n)
            func idx(_ key: String) -> Int { pool.firstIndex(of: key) ?? n }
            for step in 0..<4000 {
                fx.advance(Int64(Int.random(in: 0..<4, using: &rnd)))
                var eventRound = false
                let mark = fx.all.count
                switch Int.random(in: 0..<11, using: &rnd) {
                case 0: // new place set: a random subset in random order
                    var keys: [String] = []
                    var inSet = [Bool](repeating: false, count: n)
                    for _ in 0..<n {
                        let pick = Int.random(in: 0..<n, using: &rnd)
                        if !inSet[pick] && Int.random(in: 0..<100, using: &rnd) < 70 {
                            inSet[pick] = true
                            keys.append(pool[pick])
                        }
                    }
                    fx.nPlaces = keys.count
                    fx.places(keys)
                    for k in 0..<n {
                        if !inSet[k] {
                            tracked[k] = false; failed[k] = false; expectStale[k] = false; lastOK[k] = -1
                        } else if !tracked[k] {
                            tracked[k] = true; failed[k] = false; expectStale[k] = false; lastOK[k] = -1
                        }
                    }
                case 1:
                    let key: String? = Bool.random(using: &rnd) ? pool[Int.random(in: 0..<n, using: &rnd)] : nil
                    fx.select(key)
                case 2:
                    let v = Bool.random(using: &rnd)
                    eventRound = v && !fx.visible && fx.online
                    fx.setVisible(v)
                case 3:
                    let v = Bool.random(using: &rnd)
                    eventRound = v && fx.visible && !fx.online
                    fx.setOnline(v)
                case 4:
                    eventRound = fx.visible && fx.online
                    fx.focus()
                case 5:
                    fx.advance(Int64(Int.random(in: 0..<700, using: &rnd)))
                    fx.tick()
                default: // complete a random outstanding request
                    if fx.out.isEmpty { break }
                    let o = fx.out[Int.random(in: 0..<fx.out.count, using: &rnd)]
                    var r: Outcome = o.cancelled ? .cancelled
                        : (Int.random(in: 0..<10, using: &rnd) < 7 ? .ok : .failed)
                    if o.cancelled && Int.random(in: 0..<4, using: &rnd) == 0 {
                        r = .ok // a cancelled request that finished anyway is reported as it ended
                    }
                    let k = idx(o.key)
                    #expect(k < n)
                    fx.done(o.id, r)
                    if k < n && tracked[k] {
                        if r == .ok {
                            failed[k] = false; expectStale[k] = false; lastOK[k] = fx.monoUS
                        } else if r == .failed {
                            failed[k] = true; expectStale[k] = true; lastOK[k] = -1
                        }
                    }
                }
                // (a) stale marks follow the model exactly.
                for k in 0..<n where fx.s.isStale(pool[k]) != (tracked[k] && expectStale[k]) {
                    Issue.record("seed \(seed) step \(step): stale mark of \(pool[k])")
                }

                // (b) liveness of an event round.
                if eventRound && Int.random(in: 0..<3, using: &rnd) == 0 {
                    var wanted = [Bool](repeating: false, count: n)
                    for k in 0..<n {
                        wanted[k] = tracked[k]
                            && (failed[k] || lastOK[k] < 0 || fx.monoUS - lastOK[k] >= FRESH_US)
                    }
                    var merged = [Bool](repeating: false, count: n)
                    var firstNew = UInt64.max
                    for a in fx.all[mark...] where a.kind == .fetch && a.id < firstNew {
                        firstNew = a.id
                    }
                    for o in fx.out where !o.cancelled && o.id < firstNew {
                        let k = idx(o.key)
                        if k < n { merged[k] = true }
                    }
                    var guardCount = 0
                    while let o = fx.out.first {
                        guardCount += 1
                        if guardCount >= 1000 {
                            Issue.record("seed \(seed) step \(step): liveness drain did not converge")
                            break
                        }
                        let r: Outcome = o.cancelled ? .cancelled : .ok
                        let k = idx(o.key)
                        fx.done(o.id, r)
                        if r == .ok && k < n && tracked[k] {
                            failed[k] = false; expectStale[k] = false; lastOK[k] = fx.monoUS
                        }
                    }
                    for k in 0..<n where wanted[k] {
                        let fetched = fx.all[mark...].contains { $0.kind == .fetch && $0.key == pool[k] }
                        if !(fetched || merged[k]) {
                            Issue.record("seed \(seed) step \(step): \(pool[k]) not refreshed by the event round")
                        }
                    }
                    for k in 0..<n where wanted[k] && fx.visible && fx.online && fx.s.isStale(pool[k]) {
                        Issue.record("seed \(seed) step \(step): \(pool[k]) stale after OK")
                    }
                }
            }
            fx.finishAll(.ok)
        }
    }

    @Test("/sched/random-quiescence") // C: test-scheduler.c:2117
    func randomWalkQuiescence() {
        let pool = Self.kPool
        let n = pool.count
        for seed in 100..<(100 + fuzzIterations(40)) {
            var rnd = SeededRNG(seed: UInt64(seed))
            let fx = SchedFx()
            fx.nPlaces = 0
            for _ in 0..<3000 {
                fx.advance(Int64(Int.random(in: 0..<250, using: &rnd)))
                switch Int.random(in: 0..<8, using: &rnd) {
                case 0: fx.setVisible(Bool.random(using: &rnd))
                case 1: fx.setOnline(Bool.random(using: &rnd))
                case 2: fx.focus()
                case 3: fx.tick()
                case 4:
                    var keys: [String] = []
                    var inSet = [Bool](repeating: false, count: n)
                    for _ in 0..<n {
                        let pick = Int.random(in: 0..<n, using: &rnd)
                        if !inSet[pick] {
                            inSet[pick] = true
                            keys.append(pool[pick])
                        }
                    }
                    fx.nPlaces = keys.count
                    fx.places(keys)
                default:
                    if !fx.out.isEmpty {
                        let o = fx.out[Int.random(in: 0..<fx.out.count, using: &rnd)]
                        fx.done(o.id, o.cancelled ? .cancelled : .ok)
                    }
                }
            }
            // Quiesce: complete everything, then an active scheduler must have nothing waiting.
            fx.finishAll(.ok)
            let mark = fx.all.count
            fx.finishAll(.ok)
            #expect(fx.all.count == mark, "seed \(seed)")
            #expect(fx.s.inflightCount == 0, "seed \(seed)")
        }
    }
}
