// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HelpWindowManager.swift - Bundled HTML Help Book viewer for Neginato Mezora,
// modelled after Neginato's HelpWindowManager.

import AppKit
import SwiftUI
import WebKit

/// Presents the bundled `NeginatoMezora.help` HTML Help Book in a dedicated,
/// non-blocking macOS window with sidebar navigation and full-text search.
@MainActor
final class HelpWindowManager {
    static let shared = HelpWindowManager()

    private var windowController: NSWindowController?
    private weak var webView: WKWebView?

    private init() {}

    /// Opens the Help window at the specified anchor or page (default: `index.html`).
    func showHelp(page: String = "index.html") {
        if let wc = windowController, let window = wc.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if page != "index.html" {
                loadPage(page)
            }
            return
        }

        let contentView = HelpWebView(onWebViewCreated: { [weak self] wv in
            self?.webView = wv
            self?.loadPage(page)
        })

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Neginato Mezora Help"
        window.center()
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NeginatoMezoraHelpWindow")
        window.minSize = NSSize(width: 680, height: 460)

        let wc = NSWindowController(window: window)
        self.windowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadPage(_ page: String) {
        guard let webView else { return }
        if let helpRoot = Self.locateHelpResourcesRoot() {
            let targetURL = helpRoot.appendingPathComponent(page)
            let fileURL = FileManager.default.fileExists(atPath: targetURL.path)
                ? targetURL
                : helpRoot.appendingPathComponent("index.html")
            webView.loadFileURL(fileURL, allowingReadAccessTo: helpRoot)
        } else {
            webView.loadHTMLString(
                """
                <!DOCTYPE html>
                <html>
                <head><meta charset="utf-8"><title>Neginato Mezora Help</title>
                <style>body{font-family:-apple-system,sans-serif;padding:40px;color:#e5e7eb;background:#111827;}</style>
                </head>
                <body>
                <h1>Neginato Mezora Help</h1>
                <p>Help bundle resources could not be located in the application bundle.</p>
                </body>
                </html>
                """,
                baseURL: nil
            )
        }
    }

    /// Resolves `NeginatoMezora.help/Contents/Resources/en.lproj` inside the app bundle
    /// or adjacent source tree during development.
    private static func locateHelpResourcesRoot() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "NeginatoMezora", withExtension: "help") {
            let enLproj = bundleURL
                .appendingPathComponent("Contents/Resources/en.lproj", isDirectory: true)
            if FileManager.default.fileExists(atPath: enLproj.appendingPathComponent("index.html").path) {
                return enLproj
            }
        }
        if let resourceURL = Bundle.main.resourceURL {
            let direct = resourceURL
                .appendingPathComponent("NeginatoMezora.help/Contents/Resources/en.lproj", isDirectory: true)
            if FileManager.default.fileExists(atPath: direct.appendingPathComponent("index.html").path) {
                return direct
            }
            // Also handle flat synchronization if Xcode copies en.lproj directly:
            let flat = resourceURL.appendingPathComponent("en.lproj", isDirectory: true)
            if FileManager.default.fileExists(atPath: flat.appendingPathComponent("index.html").path) {
                return flat
            }
        }
        return nil
    }
}

private struct HelpWebView: NSViewRepresentable {
    let onWebViewCreated: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        DispatchQueue.main.async {
            onWebViewCreated(webView)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
