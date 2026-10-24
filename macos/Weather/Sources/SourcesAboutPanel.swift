// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SourcesAboutPanel.swift - the About panel the sources popover's "About Weather"
// button opens (wx-window.c's "about-requested" handler, a GtkAboutDialog). The Mac
// standard About panel shows the application name and icon itself. GTK shows the version
// as exactly "0.1.0", but AppKit prefixes the ApplicationVersion option with "Version" when
// it looks like a number and appends the build in parentheses (NSApplication.h:561-564),
// so both version options are blank (an empty Version is "leave blank") and the version
// opens the credits. The credits then follow GTK's order: version, comments, website,
// copyright (U+00A9; Info.plist has no NSHumanReadableCopyright and AppKit no copyright
// option) and licence. Every string is AboutInfo's, verbatim.

import AppKit
import WeatherCore

/// The standard About panel filled from `AboutInfo`.
enum SourcesAboutPanel {
    /// Shows the panel: pass it as `SourcesViewModel(model:onAbout:)`'s `onAbout`.
    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: options())
        NSApplication.shared.activate()
    }

    /// The panel options: the name, blank version lines and the credits text.
    static func options() -> [NSApplication.AboutPanelOptionKey: Any] {
        [
            .applicationName: AboutInfo.programName,
            .applicationVersion: "",
            .version: "",
            .credits: credits(),
        ]
    }

    /// The credits: version, comments, website (a link), copyright and the licence name (a link
    /// to the licence), one per paragraph, centred like the rest of the panel.
    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString()
        func append(_ string: String, link: String? = nil, last: Bool = false) {
            var attributes = base
            if let link, let url = URL(string: link) {
                attributes[.link] = url
            }
            text.append(NSAttributedString(string: string, attributes: attributes))
            if !last {
                text.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        append(AboutInfo.version)
        append(AboutInfo.comments)
        append(AboutInfo.website, link: AboutInfo.website)
        append(AboutInfo.copyright)
        append(AboutInfo.licenseName, link: AboutInfo.licenseURL, last: true)
        return text
    }
}
