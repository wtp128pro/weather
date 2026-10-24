// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Member.swift - one forecast series from one model of one source. Port of
// WxMember (src/core/wx-types.h:344-570, src/core/wx-types.c:448-599).
//
// C builds a reference-counted member with wx_member_add_hour/_quarter and
// then shares it; adding to a shared member is refused with a critical. In
// Swift a member is a value type: the builder mutates its own copy, and every
// copy handed out is immutable to its readers (copy-on-write), so the
// build-then-share contract holds by construction and needs no check.
//
// Ids are read like C strings: up to the first 0x00 byte, and only that
// prefix is stored. Error messages are the C constants and never echo input.

/// One forecast series from one model of one source (WxMember).
///
/// Invariants (kept by `init` and the `add` methods): hours strictly
/// ascending, each tS a multiple of 3600 in [timeMinS, timeMaxS), at most
/// `WxLimits.memberMaxHours`; quarters strictly ascending, multiples of 900,
/// amounts finite in [0, precipMaxMmH], at most `WxLimits.memberMaxQuarters`;
/// every hour field finite and in range or NaN, wmo 0...99 or -1.
public struct WxMember: Equatable, Hashable, Sendable {
    /// Provider id, `WxLimits.isValidID`.
    public let sourceID: String
    /// Model id, `WxLimits.isValidID`.
    public let modelID: String
    /// UTC unix seconds the data was fetched.
    public let fetchedS: Int64
    /// The normalised hours, ascending.
    public private(set) var hours: [WxHour] = []
    /// The quarters, ascending.
    public private(set) var quarters: [WxQuarter] = []

    /// An empty member (wx_member_new, src/core/wx-types.c:450-470).
    ///
    /// - Throws: `WxError.Code.invalidArg` with "invalid source id",
    ///   "invalid model id" or "fetch time out of range" (checked in that
    ///   order); the message never contains the rejected text.
    public init(sourceID: String?, modelID: String?, fetchedS: Int64) throws(WxError) {
        try self.init(
            sourceIDBytes: sourceID.map { Array($0.utf8) },
            modelIDBytes: modelID.map { Array($0.utf8) }, fetchedS: fetchedS)
    }

    /// `init(sourceID:modelID:fetchedS:)` over raw bytes (a C string: the
    /// text ends at the first 0x00; nil is NULL).
    public init(sourceIDBytes: [UInt8]?, modelIDBytes: [UInt8]?, fetchedS: Int64) throws(WxError) {
        guard let sourceIDBytes, WxLimits.isValidID(bytes: sourceIDBytes) else {
            throw WxError(.invalidArg, "invalid source id")
        }
        guard let modelIDBytes, WxLimits.isValidID(bytes: modelIDBytes) else {
            throw WxError(.invalidArg, "invalid model id")
        }
        guard WxHour.timeInRange(fetchedS) else {
            throw WxError(.invalidArg, "fetch time out of range")
        }
        self.sourceID = Self.cString(sourceIDBytes)
        self.modelID = Self.cString(modelIDBytes)
        self.fetchedS = fetchedS
    }

    /// Appends an hourly bucket (wx_member_add_hour,
    /// src/core/wx-types.c:499-533). Hostile data is rejected, not asserted:
    /// returns false and leaves the member unchanged when tS is outside
    /// [timeMinS, timeMaxS) or not a multiple of 3600, when `memberMaxHours`
    /// hours are stored, or when tS is not strictly after the last hour.
    /// Otherwise appends `hour.normalised` (out-of-range numbers NaN, wmo
    /// outside 0...99 -1) and returns true. `hour` itself is not changed.
    @discardableResult
    public mutating func addHour(_ hour: WxHour) -> Bool {
        if !WxHour.timeInRange(hour.tS) || hour.tS % 3600 != 0 {
            return false
        }
        if hours.count >= WxLimits.memberMaxHours {
            return false
        }
        if let last = hours.last, hour.tS <= last.tS {
            return false
        }
        hours.append(hour.normalised)
        return true
    }

    /// Appends a 15-minute amount (wx_member_add_quarter,
    /// src/core/wx-types.c:537-557). Returns false (member unchanged) when
    /// tS is not a multiple of 900 or outside the time range, precipMm is not
    /// finite or outside [0, precipMaxMmH], `memberMaxQuarters` are stored,
    /// or tS is not strictly after the last quarter. The amount is stored as
    /// given (no normalisation).
    @discardableResult
    public mutating func addQuarter(_ quarter: WxQuarter) -> Bool {
        if !quarter.isValid || quarters.count >= WxLimits.memberMaxQuarters {
            return false
        }
        if let last = quarters.last, quarter.tS <= last.tS {
            return false
        }
        quarters.append(quarter)
        return true
    }

    /// The C string held by `bytes`: everything before the first 0x00.
    private static func cString(_ bytes: [UInt8]) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
