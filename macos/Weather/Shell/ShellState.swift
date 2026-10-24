// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellState.swift - what the app shell owns for the whole process (wx-app.c:1897-1955 startup,
// :1957-2040 shutdown): the AppModel built by AppEnvironment.make on the sandbox container's
// Application Support / Caches directories, the window-wide view models, the network monitor
// (g_network_monitor_get_default, wx-app.c:1921-1922) and the quit flush.
//
// The AppModel contract for the shell (U27): visibility, focus and the network state reach the
// model only after AppEnvironment.make has returned (so the first round sees the restored
// selection); until then the window's reports are remembered and replayed in order.

import AppKit
import Foundation
import Network
import Observation
import WeatherCore

/// The process-wide shell state. One instance, owned by ShellAppDelegate.
@MainActor
@Observable
final class ShellState {
    /// What the main window shows.
    enum Page: Equatable {
        /// The model is not built (or not loaded) yet: a neutral, empty page. The first-run page
        /// must never appear here (C builds the window only after the load, wx-app.c:1935-1947).
        case loading
        /// No saved place: the first-run page (wx-window.c:554-560).
        case firstRun
        /// The sidebar and the detail pane.
        case places
    }

    /// The flush limit at quit: WX_APP_SHUTDOWN_WAIT_MS (wx-app.c:2004) in seconds.
    static let quitWait = TimeInterval(AppModel.shutdownWaitMs) / 1000

    /// The loaded application model; nil until AppEnvironment.make has returned.
    private(set) var model: AppModel?
    /// The first-run page's view model (created with the model).
    private(set) var firstRun: FirstRunViewModel?
    /// The sources popover's view model, alive for the whole process (U30/U33).
    private(set) var sources: SourcesViewModel?
    /// A quit has begun (⌘Q, the window closed, SIGTERM or SIGINT); later requests only wait.
    private(set) var isQuitting = false

    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var windowFocused = false
    @ObservationIgnored private var online: Bool?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var loadTask: Task<AppModel, Never>?
    /// The clock that bounds a quit during the load (AppEnvironment.make gives the model a
    /// SystemClock, so the default is the same time base as flush's limit).
    @ObservationIgnored private let clock: any WxClock
    @ObservationIgnored private let log: AppModel.LogSink

    init(clock: any WxClock = SystemClock(), log: @escaping AppModel.LogSink = AppModel.systemLog) {
        self.clock = clock
        self.log = log
    }

    /// The page for a model state: the first-run page only for a model that exists and is
    /// loaded (DECISIONS #58); every other state is `.loading`.
    static func page(model: AppModel?, firstRun: FirstRunViewModel?) -> Page {
        guard let model, model.isLoaded, let firstRun else {
            return .loading
        }
        return firstRun.isShown ? .firstRun : .places
    }

    /// The page the main window shows now.
    var page: Page { Self.page(model: model, firstRun: firstRun) }

    /// The container directories (sandboxed: ~/Library/Containers/<id>/Data/Library/...). The
    /// only place in the app that resolves them.
    static func storageRoot(fileManager: FileManager = .default) -> AppEnvironment.StorageRoot {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        else {
            return AppEnvironment.StorageRoot(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        }
        return AppEnvironment.StorageRoot(configDirectory: support.path(percentEncoded: false),
                                          cacheDirectory: caches.path(percentEncoded: false))
    }

    /// Starts the network monitor and the load (once).
    func start() {
        guard loadTask == nil, !isQuitting else {
            return
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            MainActor.assumeIsolated {
                self?.networkChanged(online)
            }
        }
        pathMonitor.start(queue: .main)
        let root = Self.storageRoot()
        let initialOnline = online ?? true
        loadTask = Task { @MainActor [weak self] in
            let model = await AppEnvironment.make(storageRoot: root, online: initialOnline)
            self?.modelLoaded(model)
            return model
        }
    }

    /// The main window's state: on screen (occlusion visible, not miniaturised, the app not
    /// hidden; wx-window.c:90-91) and active (key window of the active app; wx-window.c:265-269).
    func windowStateChanged(visible: Bool, focused: Bool) {
        let visibleChanged = visible != windowVisible
        windowVisible = visible
        windowFocused = focused
        guard let model, !isQuitting else {
            return
        }
        if visibleChanged {
            model.setVisible(visible)
        }
        model.setFocused(focused)
    }

    /// The main window closed, or SIGTERM / SIGINT arrived: quit like ⌘Q (main.c:10-37). A repeated
    /// request while the quit is waiting changes nothing (the wait is not cut short).
    func requestTermination() {
        guard !isQuitting else {
            return
        }
        // Both callers run inside a main-queue block (the signal source, the willClose
        // notification on OperationQueue.main). terminate() answered with terminateLater waits in
        // a nested run loop, and the serial main queue - which runs the MainActor flush task -
        // cannot drain while that block is still executing, so the reply would never come.
        // Issue terminate from the run loop instead (observed in the scratch signal harness).
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// applicationShouldTerminate: stops the monitor, waits for the load if it is still running,
    /// then flushes (saves, cancels requests, waits at most `quitWait`) and calls `reply`.
    /// Nothing blocks the main thread: the wait is an async Task. A quit during the load is
    /// bounded as in C (wx_app_shutdown waits for the start-up load, the saves and the requests
    /// within one WX_APP_SHUTDOWN_WAIT_MS): the load gets at most `quitWait` and the flush the
    /// time that is left.
    func quit(reply: @escaping @MainActor () -> Void) {
        guard !isQuitting else {
            return
        }
        isQuitting = true
        pathMonitor.cancel()
        let task = loadTask
        let loaded = model
        let clock = self.clock
        let log = self.log
        Task { @MainActor in
            if let model = loaded {
                await model.flush(timeout: Self.quitWait)
            } else if let load = await Self.awaitLoad(task, within: Self.quitWait, clock: clock, log: log) {
                await load.model.flush(timeout: load.remaining)
            }
            reply()
        }
    }

    /// Waits for the start-up load for at most `limit` seconds on `clock`, without blocking.
    /// - Returns: the loaded model and the seconds left of `limit`; nil when there is no load or
    ///   the limit passed first (then logged "Gave up waiting for pending saves/requests after
    ///   <ms> ms", like AppModel.flush; the load itself is not cancelled).
    static func awaitLoad(_ task: Task<AppModel, Never>?, within limit: TimeInterval, clock: any WxClock,
                          log: @escaping AppModel.LogSink) async -> (model: AppModel, remaining: TimeInterval)? {
        guard let task else {
            return nil
        }
        let limitMs = Int64(max(0, limit) * 1000)
        let start = clock.monotonicMicroseconds
        let deadline = start + limitMs * 1000
        let race = LoadRace()
        let model: AppModel? = await withCheckedContinuation { continuation in
            race.continuation = continuation
            let timer = Task { @MainActor in
                try? await clock.sleep(until: deadline)
                race.finish(nil)
            }
            race.timer = timer
            Task { @MainActor in
                let model = await task.value
                race.finish(model)
            }
        }
        guard let model else {
            log(.warning, "Gave up waiting for pending saves/requests after \(limitMs) ms")
            return nil
        }
        let elapsedMs = (clock.monotonicMicroseconds - start) / 1000
        return (model, TimeInterval(max(0, limitMs - elapsedMs)) / 1000)
    }

    /// The first of the load and the deadline resumes the waiting quit; the other is ignored.
    private final class LoadRace {
        var continuation: CheckedContinuation<AppModel?, Never>?
        var timer: Task<Void, Never>?

        func finish(_ model: AppModel?) {
            timer?.cancel()
            timer = nil
            continuation?.resume(returning: model)
            continuation = nil
        }
    }

    private func networkChanged(_ online: Bool) {
        self.online = online
        guard !isQuitting else {
            return
        }
        model?.setOnline(online)
    }

    private func modelLoaded(_ model: AppModel) {
        self.model = model
        firstRun = FirstRunViewModel(model: model)
        sources = SourcesViewModel(model: model, onAbout: { SourcesAboutPanel.show() })
        guard !isQuitting else {
            return
        }
        if let online {
            model.setOnline(online)
        }
        model.setVisible(windowVisible)
        model.setFocused(windowFocused)
    }
}
