// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WxUnits.swift - the display unit system. Port of WxUnits
// (src/core/wx-types.h:793-796). The raw values are the C ordinals.

/// Unit system for display (WxUnits). `rawValue` is the C ordinal.
public enum WxUnits: Int, CaseIterable, Sendable {
    case imperial = 0
    case metric = 1
}
