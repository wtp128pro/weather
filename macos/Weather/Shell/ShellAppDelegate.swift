// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellAppDelegate.swift - the process lifecycle (main.c:44-75, wx-app.c:1957-2040):
//  - SIGINT and SIGTERM quit like closing the window; the signal sources stay installed, so a
//    second signal repeats the request and does not cut the wait short (main.c:10-37, 67-68);
//  - every quit path (⌘Q, the window closed, a signal) goes through applicationShouldTerminate,
//    which answers terminateLater and replies after `await AppModel.flush(timeout: 5)`;
//  - closing the last window ends the app (GtkApplication's default);
//  - no window tabs (one main window, wx-app.c:1950-1955).

import AppKit
import Dispatch
import Foundation

/// The NSApplicationDelegate behind WeatherApp's @NSApplicationDelegateAdaptor.
final class ShellAppDelegate: NSObject, NSApplicationDelegate {
    /// The process-wide shell state.
    let shell = ShellState()

    private var signalSources: [any DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        installSignalSources()
        shell.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shell.quit {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// g_unix_signal_add(SIGINT/SIGTERM, on_terminate) (main.c:67-68): the default disposition is
    /// replaced for the life of the process and each delivery asks for a normal quit on the main
    /// queue.
    private func installSignalSources() {
        guard signalSources.isEmpty else {
            return
        }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.shell.requestTermination()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
