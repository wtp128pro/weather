// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Scheduler.swift - RefreshScheduler: the pure refresh-policy state machine,
// a literal port of src/sched/wx-scheduler.{h,c}.
//
// The scheduler decides WHEN a forecast is fetched; it never fetches, never
// reads a clock and has no timers. The owner feeds it inputs (every call
// carries the current time as a `RefreshScheduler.Time` read by the caller),
// then drains the resulting actions with `takeActions()` and arms at most one
// timer for `nextWakeupUS`. Because time is an argument every rule is
// deterministic. Not thread-safe by itself: it is a value type; keep one
// instance in the owner (e.g. a @MainActor refresh engine).
//
// Rules (wx-scheduler.h:19-81), all ported literally:
//  - A request is issued only while visible AND online ("active").
//  - Event rounds (show, focus while active, network back while visible) skip
//    a place whose latest SUCCESS is < 120 s old; periodic rounds (every
//    600 s while active with a place) skip one < 540 s old. A place exactly
//    120 s / 540 s old is wanted again.
//  - At most one request per place and at most 3 in total; a cancelled
//    request keeps its slot until `requestDone` reports it. Waiting places
//    start selected-first, then in list order.
//  - FAILED marks stale and forgets the success; CANCELLED changes neither.
//  - A forward wall-clock jump of more than 10 s beyond the monotonic clock
//    makes an armed deadline due at once; all time arithmetic saturates.

/// Pure refresh-policy logic (port of WxScheduler, src/sched/wx-scheduler.h).
public struct RefreshScheduler: Sendable {

    // MARK: Constants (src/sched/wx-scheduler.h:89-106)

    /// Period of the periodic round, microseconds (WX_SCHED_PERIOD_US, 600 s).
    public static let periodUS: Int64 = 600 * 1_000_000
    /// An event round skips a place whose latest success is less than this
    /// ago (WX_SCHED_FRESH_US, 120 s).
    public static let freshUS: Int64 = 120 * 1_000_000
    /// A periodic round skips a place whose latest success is less than this
    /// ago (WX_SCHED_PERIODIC_FRESH_US, 540 s).
    public static let periodicFreshUS: Int64 = 540 * 1_000_000
    /// Maximum number of requests outstanding at once (WX_SCHED_MAX_INFLIGHT).
    public static let maxInflight: Int = 3
    /// Wall-minus-monotonic drift above which a forward clock jump is assumed
    /// (WX_SCHED_JUMP_TOLERANCE_US, 10 s).
    public static let jumpToleranceUS: Int64 = 10 * 1_000_000
    /// WX_SCHED_KEY_BYTES: a key is 1 to keyBytes - 1 (23) bytes of [0-9.,-].
    public static let keyBytes: Int = 24

    // MARK: Public value types

    /// The instant an input happens at; both clocks are read by the caller
    /// (WxSchedTime). `monoUS` is a monotonic microsecond count >= 0; every
    /// call given a negative `monoUS` changes nothing (the C code logs a
    /// critical and returns). `wallMS` is real time in ms since the Unix epoch.
    public struct Time: Sendable, Equatable, Hashable {
        public var monoUS: Int64
        public var wallMS: Int64
        public init(monoUS: Int64, wallMS: Int64) {
            self.monoUS = monoUS
            self.wallMS = wallMS
        }
    }

    /// Kind of instruction for the owner (WxSchedActionType).
    public enum ActionKind: Sendable, Equatable, Hashable {
        /// Start a forecast refresh for the place.
        case fetch
        /// Cancel the request with this id.
        case cancel
    }

    /// An instruction for the owner (WxSchedAction).
    public struct Action: Sendable, Equatable, Hashable {
        public var kind: ActionKind
        /// fetch: id of the new request (never 0, never reused); cancel: id of
        /// the request to cancel.
        public var id: UInt64
        /// fetch: the place key; cancel: "".
        public var key: String
        public init(kind: ActionKind, id: UInt64, key: String) {
            self.kind = kind
            self.id = id
            self.key = key
        }
    }

    /// Outcome of a request (WxSchedResult).
    public enum Outcome: Sendable, Equatable, Hashable {
        case ok
        /// Any error except cancellation.
        case failed
        /// Ended by cancellation.
        case cancelled
    }

    // MARK: State (src/sched/wx-scheduler.c:9-35)

    private struct Entry: Sendable {
        var key: String
        /// No longer tracked, but its cancelled request has not completed yet.
        var removed = false
        /// Waiting for a slot.
        var wanted = false
        /// The latest request failed.
        var failed = false
        /// The latest request succeeded (okUS is valid).
        var fresh = false
        /// Monotonic time of that success.
        var okUS: Int64 = 0
        /// 0: nothing in flight.
        var reqID: UInt64 = 0
        var reqCancelling = false
        init(key: String) { self.key = key }
    }

    /// Display order; removed entries last.
    private var entries: [Entry] = []
    private var selKey: String?
    private var visible = false
    private var online = false
    private var inflight = 0
    private var nextID: UInt64 = 1
    private var deadlineUS: Int64 = -1
    private var last: Time?
    private var actions: [Action] = []

    /// A scheduler that is hidden, offline and empty (wx_scheduler_new): it
    /// emits nothing until told otherwise; the first request id is 1.
    public init() {}

    // MARK: Small helpers (wx-scheduler.c:39-75)

    private static func satAdd(_ a: Int64, _ b: Int64) -> Int64 {
        // Only ever called with b = periodUS > 0, as in the C code.
        a > Int64.max - b ? Int64.max : a + b
    }

    private static func satSub(_ a: Int64, _ b: Int64) -> Int64 {
        if b < 0 && a > Int64.max + b { return Int64.max }
        if b > 0 && a < Int64.min + b { return Int64.min }
        return a - b
    }

    /// normalise(): the bytes up to the first NUL among the first keyBytes
    /// bytes (a Swift string is NUL-terminated at its end, as when passed to
    /// C); 1...23 bytes, every one an ASCII digit or one of ".,-".
    static func normalise(_ key: String?) -> String? {
        guard let key else { return nil }
        var bytes = Array(key.utf8)
        bytes.append(0)
        guard let end = bytes.prefix(keyBytes).firstIndex(of: 0), end > 0 else { return nil }
        for b in bytes[0..<end] {
            let isDigit = b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
            if !isDigit && b != UInt8(ascii: ".") && b != UInt8(ascii: ",") && b != UInt8(ascii: "-") {
                return nil
            }
        }
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }

    private var isActive: Bool { visible && online }

    private func isSelected(_ e: Entry) -> Bool {
        guard let selKey else { return false }
        return !e.removed && e.key == selKey
    }

    private static func want(_ e: inout Entry) {
        if e.reqID == 0 || e.reqCancelling {
            e.wanted = true
        }
    }

    /// cancel_request(): marks the request cancelling and returns its CANCEL.
    private static func cancelRequest(_ e: inout Entry) -> Action? {
        if e.reqID == 0 || e.reqCancelling { return nil }
        e.reqCancelling = true
        return Action(kind: .cancel, id: e.reqID, key: "")
    }

    // MARK: Starting requests (wx-scheduler.c:276-342)

    private mutating func startRequest(at i: Int) {
        let id = nextID
        nextID &+= 1
        entries[i].reqID = id
        entries[i].reqCancelling = false
        entries[i].wanted = false
        inflight += 1
        actions.append(Action(kind: .fetch, id: id, key: entries[i].key))
    }

    private mutating func startNext() -> Bool {
        for pass in 0..<2 {
            for i in entries.indices {
                let e = entries[i]
                if e.removed || e.reqID != 0 || !e.wanted || isSelected(e) != (pass == 0) {
                    continue
                }
                startRequest(at: i)
                return true
            }
        }
        return false
    }

    private mutating func pump() {
        if !isActive { return }
        while inflight < Self.maxInflight && startNext() {}
    }

    // MARK: Rounds, time, deadline (wx-scheduler.c:365-497)

    private mutating func addRound(_ now: Time, window: Int64) {
        for i in entries.indices where !entries[i].removed {
            if !entries[i].fresh || Self.satSub(now.monoUS, entries[i].okUS) >= window {
                Self.want(&entries[i])
            }
        }
    }

    private mutating func dropAll() {
        for i in entries.indices {
            entries[i].wanted = false
            if let a = Self.cancelRequest(&entries[i]) { actions.append(a) }
        }
    }

    private var hasPlaces: Bool {
        guard let first = entries.first else { return false }
        return !first.removed
    }

    private mutating func rearm(_ now: Time) {
        if !isActive || !hasPlaces {
            deadlineUS = -1
        } else if deadlineUS < 0 {
            deadlineUS = Self.satAdd(now.monoUS, Self.periodUS)
        }
    }

    private mutating func advance(_ now: Time) {
        if let last, deadlineUS >= 0 {
            let driftMS = Self.satSub(Self.satSub(now.wallMS, last.wallMS),
                                      Self.satSub(now.monoUS, last.monoUS) / 1000)
            if driftMS > Self.jumpToleranceUS / 1000 {
                deadlineUS = now.monoUS
            }
        }
        last = now
    }

    private mutating func finish(_ now: Time) {
        pump()
        rearm(now)
    }

    // MARK: Inputs

    /// Replaces the tracked set (wx_scheduler_set_places). `keys` are in
    /// display order; nil, invalid (see `normalise`) and repeated elements are
    /// ignored. Kept places keep their state and move to the new order; a
    /// removed place's request in flight is cancelled (CANCELs are queued from
    /// the end of the old order backwards); while active a new place is wanted
    /// at once.
    public mutating func setPlaces(_ keys: [String?], now: Time) {
        guard now.monoUS >= 0 else { return }
        advance(now)

        var old = entries
        var next: [Entry] = []
        for raw in keys {
            guard let key = Self.normalise(raw) else { continue }
            if next.contains(where: { $0.key == key }) { continue }

            var e: Entry
            let revived: Bool
            if let j = old.firstIndex(where: { $0.key == key }) {
                e = old.remove(at: j)
                revived = e.removed // revived while its request winds down
            } else {
                e = Entry(key: key)
                revived = true // new
            }
            e.removed = false
            if revived {
                e.wanted = isActive
                e.failed = false
                e.fresh = false
            }
            next.append(e)
        }

        // What is left in the old array left the tracked set.
        while var e = old.popLast() {
            e.wanted = false
            if let a = Self.cancelRequest(&e) { actions.append(a) }
            if e.reqID != 0 {
                e.removed = true // keeps its slot until the request is reported done
                next.append(e)
            }
        }
        entries = next

        finish(now)
    }

    /// Sets the selected place (wx_scheduler_set_selection): nil or an invalid
    /// key means none; it need not be tracked. Fetches nothing by itself.
    public mutating func setSelection(_ key: String?, now: Time) {
        guard now.monoUS >= 0 else { return }
        advance(now)
        selKey = Self.normalise(key)
        finish(now)
    }

    /// The window became visible / hidden (wx_scheduler_set_visible). No-op
    /// when unchanged; true starts an event round when online, false cancels
    /// everything in flight and drops everything waiting.
    public mutating func setVisible(_ visible: Bool, now: Time) {
        guard now.monoUS >= 0 else { return }
        advance(now)
        if visible != self.visible {
            self.visible = visible
            if !visible {
                dropAll()
            } else if isActive {
                addRound(now, window: Self.freshUS)
            }
        }
        finish(now)
    }

    /// The network became available / unavailable (wx_scheduler_set_online).
    /// No-op when unchanged; true starts an event round when visible, false
    /// cancels everything in flight and drops everything waiting.
    public mutating func setOnline(_ online: Bool, now: Time) {
        guard now.monoUS >= 0 else { return }
        advance(now)
        if online != self.online {
            self.online = online
            if !online {
                dropAll()
            } else if isActive {
                addRound(now, window: Self.freshUS)
            }
        }
        finish(now)
    }

    /// The window became the active window (wx_scheduler_focus_regained):
    /// an event round, but only while visible and online.
    public mutating func focusRegained(now: Time) {
        guard now.monoUS >= 0 else { return }
        advance(now)
        if isActive {
            addRound(now, window: Self.freshUS)
        }
        finish(now)
    }

    /// The timer armed for `nextWakeupUS` fired (wx_scheduler_tick). If the
    /// deadline has been reached: a periodic round, and the next deadline one
    /// period after the old one (one period after `now` when late).
    public mutating func tick(now: Time) {
        guard now.monoUS >= 0 else { return }
        advance(now)
        if deadlineUS >= 0 && now.monoUS >= deadlineUS {
            var next = Self.satAdd(deadlineUS, Self.periodUS)
            if next <= now.monoUS {
                next = Self.satAdd(now.monoUS, Self.periodUS) // late: no catch-up rounds
            }
            addRound(now, window: Self.periodicFreshUS)
            deadlineUS = next
        }
        finish(now)
    }

    /// Reports how request `id` ended (wx_scheduler_request_done); every
    /// FETCH id is reported exactly once, cancelled ones included. Unknown,
    /// zero or already finished ids are ignored.
    public mutating func requestDone(id: UInt64, outcome: Outcome, now: Time) {
        guard now.monoUS >= 0 else { return }
        advance(now)

        guard id != 0, let i = entries.firstIndex(where: { $0.reqID == id }) else {
            finish(now)
            return
        }

        switch outcome {
        case .ok:
            entries[i].failed = false
            entries[i].fresh = true
            entries[i].okUS = now.monoUS
        case .failed:
            entries[i].failed = true
            entries[i].fresh = false
        case .cancelled:
            break
        }

        entries[i].reqID = 0
        entries[i].reqCancelling = false
        inflight -= 1
        if entries[i].removed {
            entries.remove(at: i)
        }
        finish(now)
    }

    // MARK: Queries

    /// Drains the actions produced since the last call, in execution order
    /// (wx_scheduler_take_actions; the C NULL is an empty array here).
    public mutating func takeActions() -> [Action] {
        let out = actions
        actions = []
        return out
    }

    /// Monotonic time (µs, the caller's `Time.monoUS` scale) at which to call
    /// `tick`, or -1: no timer must exist (wx_scheduler_next_wakeup_us).
    public var nextWakeupUS: Int64 { deadlineUS }

    /// True iff the latest request of the tracked place failed and no success
    /// has cleared it since; false for unknown, nil or invalid keys.
    public func isStale(_ key: String?) -> Bool {
        guard let norm = Self.normalise(key) else { return false }
        guard let e = entries.first(where: { !$0.removed && $0.key == norm }) else { return false }
        return e.failed
    }

    /// Number of requests outstanding, cancelled ones included.
    public var inflightCount: Int { inflight }
}
