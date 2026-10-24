// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SourceResult.swift - the members one provider produced for one place. Port
// of WxSourceResult (src/core/wx-types.h:572-620,
// src/core/wx-types.c:601-646). In C the result owns a GPtrArray of member
// references; here it is a value holding member values.

/// The members one provider produced for one place (WxSourceResult).
public struct WxSourceResult: Equatable, Hashable, Sendable {
    /// Provider id, `WxLimits.isValidID`.
    public let providerID: String
    /// The members, in the order the provider appended them.
    public var members: [WxMember] = []

    /// An empty result (wx_source_result_new, src/core/wx-types.c:624-634).
    ///
    /// - Throws: `WxError.Code.invalidArg` "invalid provider id"; the message
    ///   never contains the rejected text.
    public init(providerID: String?) throws(WxError) {
        try self.init(providerIDBytes: providerID.map { Array($0.utf8) })
    }

    /// `init(providerID:)` over raw bytes (a C string: the text ends at the
    /// first 0x00; nil is NULL).
    public init(providerIDBytes: [UInt8]?) throws(WxError) {
        guard let providerIDBytes, WxLimits.isValidID(bytes: providerIDBytes) else {
            throw WxError(.invalidArg, "invalid provider id")
        }
        let end = providerIDBytes.firstIndex(of: 0) ?? providerIDBytes.endIndex
        self.providerID = String(decoding: providerIDBytes[..<end], as: UTF8.self)
    }
}
