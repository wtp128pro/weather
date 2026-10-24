// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FormatZone.swift - the place time zone of the formatting module: THE TIME
// ZONE RULE, the resolved zone that the zone-taking formatters use, the local
// calendar arithmetic (12-hour clock fields, local day numbers, the local day
// end) and the held zone of the widgets. Port of the zone parts of
// src/widgets/wx-format.c (tz_shape_ok/zone_for/wx_format_zone_new :94-352,
// local_dt/day_diff/weekday_of :371-452, local_day_number and
// wx_format_local_day_end_z :669-719) and of WxHeldZone
// (src/widgets/wx-widget-util.{h,c}).
//
// THE TIME ZONE RULE (wx-format.h:43-52) is WxDaily.lookedUpName (DECISIONS
// #41): a name is looked up only when it has the shape Area/Location (at
// most 64 bytes, components [A-Za-z][A-Za-z0-9_+-]*, at least one '/');
// "UTC", nil, "" and every other string are UTC without a lookup, and a
// well-shaped name that the zone database does not know is UTC too. Case
// variants are UTC (matching the contract of test-blend.c:4907), and the 15
// ICU-only legacy identifiers absent from macOS /usr/share/zoneinfo are
// rejected by `legacyICUTimezones` so they fall back to UTC as in C
// (DECISIONS #41).
//
// Not ported (GLib mechanics, no Swift analogue): the 8-entry LRU cache of
// GTimeZone objects, the 4-entry negative ring with its 30-second expiry and
// the loader/clock test hooks (wx-format.c:117-318, wx-format-testing.h).
// They exist so that g_time_zone_new_identifier() does not read a zoneinfo
// file per call and so that a TRANSIENT failure (EMFILE) heals; Foundation's
// TimeZone(identifier:) answers from in-memory ICU data with no such failure
// mode, so a lookup's answer depends only on the name. `Zone.resolved` keeps
// the observable contract of wx_format_zone_new(): false exactly when a
// looked-up name is not a zone.

import Foundation

extension WxFormat {
    /// A resolved place time zone (wx_format_zone_new): hold one to format
    /// with the zone-taking functions without any further lookup.
    public struct Zone: Sendable, Equatable {
        /// The zone, nil for UTC.
        let tz: TimeZone?
        /// False exactly when the name was looked up (Area/Location shaped)
        /// and the lookup failed: the zone is then only the UTC fallback.
        /// True for a real zone and for the UTC results that need no lookup
        /// (nil, "", "UTC", every ill-shaped name).
        public let resolved: Bool

        /// UTC, resolved.
        public static let utc = Zone(tz: nil, resolved: true)

        /// The 15 legacy IANA identifiers that ICU's built-in table still
        /// accepts (`TimeZone(identifier:) != nil`) after macOS's
        /// `/usr/share/zoneinfo` (`tzdata.zi`) removed them (DECISIONS #41).
        static let legacyICUTimezones: Set<String> = [
            "SystemV/AST4", "SystemV/AST4ADT", "SystemV/CST6", "SystemV/CST6CDT",
            "SystemV/EST5", "SystemV/EST5EDT", "SystemV/HST10", "SystemV/MST7",
            "SystemV/MST7MDT", "SystemV/PST8", "SystemV/PST8PDT", "SystemV/YST9",
            "SystemV/YST9YDT", "US/Pacific-New", "Canada/East-Saskatchewan",
        ]

        /// Looks up a shape-validated zone identifier while rejecting the 15
        /// ICU-only legacy identifiers absent from `/usr/share/zoneinfo`.
        static func resolveTimeZone(_ name: String) -> TimeZone? {
            guard !legacyICUTimezones.contains(name) else {
                return nil
            }
            return TimeZone(identifier: name)
        }

        private init(tz: TimeZone?, resolved: Bool) {
            self.tz = tz
            self.resolved = resolved
        }

        /// zone_for (wx-format.c:241-318) on raw bytes: the bytes before the
        /// first 0x00 are the name; at most 65 bytes are examined.
        public init(timezoneBytes: [UInt8]?) {
            guard let name = WxDaily.lookedUpName(timezoneBytes) else {
                self = .utc
                return
            }
            if let tz = Self.resolveTimeZone(name) {
                self.init(tz: tz, resolved: true)
            } else {
                self.init(tz: nil, resolved: false)
            }
        }

        /// zone_for on a Swift string (see `init(timezoneBytes:)`).
        public init(timezone: String?) {
            self.init(timezoneBytes: timezone.map { Array($0.utf8) })
        }

        /// The UTC offset in seconds east, in effect at the UTC instant `t`.
        func offset(_ t: Int64) -> Int64 {
            guard let tz else {
                return 0
            }
            return Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))))
        }

        /// local_day_number (wx-format.c:669-675): whole days since
        /// 1970-01-01 of the local date at `t` (t in the time range).
        func dayNumber(_ t: Int64) -> Int64 {
            WxFormat.floorDiv(t + offset(t), WxFormat.dayS)
        }

        /// The zone's offset changes in (lo, hi], each with the offset in
        /// effect from it on.
        func transitions(after lo: Int64, through hi: Int64) -> [(t: Int64, offset: Int64)] {
            guard let tz else {
                return []
            }
            var out: [(t: Int64, offset: Int64)] = []
            var from = Date(timeIntervalSince1970: TimeInterval(lo))
            while let next = tz.nextDaylightSavingTimeTransition(after: from) {
                let raw = next.timeIntervalSince1970
                let t = Int64(raw.rounded(.up))
                if t > hi || raw <= from.timeIntervalSince1970 {
                    break
                }
                out.append((t, offset(t)))
                from = next
            }
            return out
        }
    }

    /// WxHeldZone (wx-widget-util.h:37-104): the place time zone a widget
    /// keeps between updates, so that drawing never looks a zone up.
    public struct HeldZone: Sendable, Equatable {
        /// The name the zone stands for (at most 64 bytes, as g_strlcpy into
        /// char[65]); empty at the start.
        public private(set) var nameBytes: [UInt8]
        /// The held zone (UTC at the start).
        public private(set) var zone: Zone

        /// wx_held_zone_init: UTC for the name "", resolved, no lookup.
        public init() {
            nameBytes = []
            zone = .utc
        }

        /// False when the zone is only the fallback of a failed lookup of the name.
        public var resolved: Bool { zone.resolved }

        /// wx_held_zone_update (wx-widget-util.c:19-35): a different name is
        /// resolved and replaces the zone; the same name is looked up again
        /// only while the held zone is a fallback, and a retry that fails
        /// again changes nothing.
        ///
        /// - Returns: true iff the held zone or name changed.
        @discardableResult
        public mutating func update(_ timezone: String) -> Bool {
            update(timezoneBytes: Array(timezone.utf8))
        }

        /// `update(_:)` on raw bytes (read up to the first 0x00, as strcmp).
        @discardableResult
        public mutating func update(timezoneBytes: [UInt8]) -> Bool {
            let name = Array(timezoneBytes.prefix { $0 != 0 })
            let sameName = name == nameBytes
            if sameName && zone.resolved {
                return false
            }
            let fresh = Zone(timezoneBytes: name)
            if sameName && !fresh.resolved {
                return false  // the retry failed again: keep the fallback we have
            }
            zone = fresh
            nameBytes = Array(name.prefix(WxLimits.placeTimezoneMax))
            return true
        }
    }

    /// wx_same_value (wx-widget-util.h:31-35): true iff both are NaN or both
    /// compare equal (the compare-before-set setters, an unknown value is NaN).
    public static func sameValue(_ a: Double, _ b: Double) -> Bool {
        (a.isNaN && b.isNaN) || a == b
    }

    /// wx_format_local_day_end_z (wx-format.c:678-711; contract
    /// wx-format.h:206-242): the EARLIEST UTC instant after `tS` whose local
    /// date is later than the local date of `tS` (the first midnight when the
    /// clock is set back across midnight, the first valid instant when
    /// midnight does not exist, the first instant of the next existing date
    /// when a whole date is skipped), or 0 when `tS` is outside
    /// [WxLimits.timeMinS, WxLimits.timeMaxS).
    ///
    /// Candidates, as in C: 00:00 of the next local date read with every
    /// offset in effect within two days of `tS`, accepted when that instant
    /// really is on that date and after `tS`; and every offset change in that
    /// window that moves the local date past the date of `tS` (C takes the
    /// latter from GLib's own midnight, which lands on it). The result is
    /// bounded by tS + 2 days, as in C.
    public static func localDayEnd(_ tS: Int64, zone: Zone) -> Int64 {
        guard timeOK(tS) else {
            return 0
        }
        let today = zone.dayNumber(tS)
        let nextDay = today + 1
        var first = Int64.max
        let changes = zone.transitions(after: tS - 2 * dayS, through: tS + 2 * dayS)
        var offsets = [zone.offset(tS - 2 * dayS)]
        offsets.append(contentsOf: changes.map(\.offset))
        for off in offsets {
            let c = nextDay * dayS - off
            if c > tS && c < first && zone.dayNumber(c) == nextDay {
                first = c
            }
        }
        for change in changes where change.t > tS && change.t < first && zone.dayNumber(change.t) > today {
            first = change.t
        }
        return min(first, tS + 2 * dayS)
    }

    /// wx_format_local_day_end (wx-format.c:714-719).
    public static func localDayEnd(_ tS: Int64, timezone: String?) -> Int64 {
        localDayEnd(tS, zone: Zone(timezone: timezone))
    }

    // MARK: - Internal

    /// Seconds per day and per hour.
    static let dayS: Int64 = 86_400
    static let hourS: Int64 = 3_600

    /// time_ok (wx-format.c:64-68): WX_TIME_MIN_S <= t < WX_TIME_MAX_S.
    static func timeOK(_ t: Int64) -> Bool {
        t >= WxLimits.timeMinS && t < WxLimits.timeMaxS
    }

    /// Floor division (b > 0); equal to C's / for the non-negative local
    /// clock readings of the time range.
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }

    /// The local calendar fields of an instant (local_dt, wx-format.c:371-378).
    struct LocalTime {
        /// Days since 1970-01-01 of the local date.
        let dayNumber: Int64
        /// Seconds since local midnight, 0..<86400.
        let secondOfDay: Int64

        var hour: Int64 { secondOfDay / 3600 }
        var minute: Int64 { secondOfDay % 3600 / 60 }

        /// English weekday name (weekday_of, wx-format.c:448-452); day 0
        /// (1970-01-01) was a Thursday.
        var weekdayName: String {
            WxFormat.weekdayNames[Int(((dayNumber + 3) % 7 + 7) % 7)]
        }
    }

    /// local_dt: nil when `t` is outside the time range.
    static func localTime(_ t: Int64, _ zone: Zone) -> LocalTime? {
        guard timeOK(t) else {
            return nil
        }
        let local = t + zone.offset(t)
        let day = floorDiv(local, dayS)
        return LocalTime(dayNumber: day, secondOfDay: local - day * dayS)
    }

    /// weekday_names (wx-format.c:33-34), Monday first.
    static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
}
