// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// PickerWindow.swift - the "Add a city" window (wx-picker.c:1248-1249, wx-window.c:617-625;
// ui-widgets.md §2 items 20 and 25): title PickerViewModel.windowTitle, default size
// PickerViewModel.defaultWidth x defaultHeight, not modal. Each presentation gets a NEW
// PickerViewModel; a capture-phase key monitor forwards every key of the window to
// PickerViewModel.handleKey, so Escape without a modifier closes it from any control.

import AppKit
import SwiftUI
import WeatherCore

/// The picker window's scene. Open it with `openWindow(id: PickerWindow.windowID)` (the add
/// command, the first-run "Add a city" button); close it with
/// `dismissWindow(id: PickerWindow.windowID)` when the main window closes.
struct PickerScene: Scene {
    /// The application model; nil while it is still loading (the window then stays empty).
    let model: AppModel?

    var body: some Scene {
        Window(PickerViewModel.windowTitle, id: PickerWindow.windowID) {
            if let model {
                PickerWindow(model: model)
            }
        }
        .defaultSize(width: CGFloat(PickerViewModel.defaultWidth) + 60, height: CGFloat(PickerViewModel.defaultHeight) + 90)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
    }
}

/// The window content: a picker view model for this presentation, wired to close the window,
/// and invalidated when the window goes away.
struct PickerWindow: View {
    /// The scene id of the picker window.
    static let windowID = "picker"

    let model: AppModel

    @State private var viewModel: PickerViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let viewModel {
                PickerView(viewModel: viewModel, model: model, onDismiss: { dismiss() })
                    .background(PickerKeyMonitor(viewModel: viewModel))
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 380, minHeight: 340)
        .onAppear {
            guard viewModel == nil else {
                return
            }
            let vm = PickerViewModel(model: model)
            // place-added: AppModel.add has already saved and selected the place; the view
            // model requests the close right after.
            vm.onCloseRequest = { dismiss() }
            viewModel = vm
        }
        .onDisappear {
            viewModel?.invalidate()
            viewModel = nil
        }
    }
}

/// A zero-size view whose window's key-down events go to PickerViewModel.handleKey before any
/// control sees them (GTK's capture-phase key controller, wx-picker.c:1044). A handled key
/// stops; every other key continues to the focused control.
private struct PickerKeyMonitor: NSViewRepresentable {
    let viewModel: PickerViewModel

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.viewModel = viewModel
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var viewModel: PickerViewModel?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else {
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let windowNumber = event.windowNumber
                let key = PickerView.Keys.key(keyCode: event.keyCode)
                let modifiers = PickerView.Keys.modifiers(event.modifierFlags)
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, window.windowNumber == windowNumber,
                          let viewModel = self.viewModel
                    else {
                        return false
                    }
                    return viewModel.handleKey(key, modifiers: modifiers)
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
