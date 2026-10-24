// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WeatherCore.swift - module marker of the WeatherCore framework (the
// toolkit-free model, providers, blending, scheduling and storage of the
// macOS port). WeatherCore's default actor isolation is nonisolated: the
// target sets no SWIFT_DEFAULT_ACTOR_ISOLATION, so UI-facing observable types
// must be marked @MainActor explicitly.

/// Identity constants shared by the app and the framework.
public enum WeatherCoreInfo {
    /// Application identifier; equals WX_APP_ID (src/ui/wx-app.h:149) and the
    /// app target's PRODUCT_BUNDLE_IDENTIFIER.
    public static let applicationID = "io.github.wtp128pro.Weather"
}
