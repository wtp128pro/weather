// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellWindowObserver.swift - the main window's surface state for the scheduler
// (wx-window.c:90-91, 265-269; ui-widgets.md §2 item 36): "visible" is on screen (occlusion
// state visible), not miniaturised and the app not hidden; "focused" is the key window of the
// active app. It reports after every NSWindow occlusion / miniaturise / key change and every
// NSApplication hide / unhide / active change, and reports the window closing.

import AppKit
import Foundation
import SwiftUI

/// A zero-size view that watches the NSWindow it is placed in.
struct ShellWindowObserver: NSViewRepresentable {
    /// Called with (visible, focused) after any change of either (repeats are possible).
    let onChange: @MainActor (_ visible: Bool, _ focused: Bool) -> Void
    /// Called when the window is about to close.
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
        nsView.onClose = onClose
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class ObserverView: NSView {
        var onChange: (@MainActor (Bool, Bool) -> Void)?
        var onClose: (@MainActor () -> Void)?
        private var tokens: [any NSObjectProtocol] = []

        private static let windowChanges: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]

        private static let appChanges: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                return
            }
            let center = NotificationCenter.default
            for name in Self.windowChanges {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.report()
                    }
                })
            }
            for name in Self.appChanges {
                tokens.append(center.addObserver(forName: name, object: NSApplication.shared, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.report()
                    }
                })
            }
            tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                             queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onClose?()
                }
            })
            report()
        }

        func stopObserving() {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
            tokens = []
        }

        private func report() {
            guard let window else {
                return
            }
            let app = NSApplication.shared
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized && !app.isHidden
            let focused = app.isActive && window.isKeyWindow
            onChange?(visible, focused)
        }
    }
}
