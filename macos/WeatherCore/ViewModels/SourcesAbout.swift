// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SourcesAbout.swift - the About fields, verbatim from show_about()
// (src/ui/wx-window.c:670-678), for the standard macOS About panel opened by
// the popover's "About Weather" button.

/// The About panel fields. `programName`, `version`, `comments`, `copyright`
/// and `website` are the C strings; the licence is GTK_LICENSE_GPL_3_0.
public enum AboutInfo {
    /// "program-name".
    public static let programName = "Neginato Mezora"
    /// "version": WX_APP_VERSION in C. Here it is the app's MARKETING_VERSION (every
    /// Debug and Release config in Weather.xcodeproj/project.pbxproj), not meson.build:3;
    /// bump this literal with it.
    public static let version = "0.4.0"
    /// "comments".
    public static let comments =
        "Weather forecasts from several free sources, with the rain you can expect and when."
    /// "copyright" (U+00A9, the C bytes "\xC2\xA9").
    public static let copyright = "Copyright \u{00A9} 2026 wtp128pro"
    /// The licence as an SPDX identifier (the SPDX header of every C file).
    public static let licenseSPDX = "GPL-3.0-or-later"
    /// The licence name GTK shows for GTK_LICENSE_GPL_3_0.
    public static let licenseName = "GNU General Public License, version 3 or later"
    /// The licence link GTK shows for GTK_LICENSE_GPL_3_0.
    public static let licenseURL = "https://www.gnu.org/licenses/gpl-3.0.html"
    /// "website".
    public static let website = "https://github.com/wtp128pro/weather"
    /// "logo-icon-name": the application id.
    public static let logoIconName = "io.github.wtp128pro.Weather"
}
