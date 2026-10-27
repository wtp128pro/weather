// Stand-ins for the Settings window harness. NSWindow and NSApp are SHADOWED in this module, so
// the extracted SettingsWindowManager builds windows that are never ordered on screen, never
// write a frame autosave entry, and never activate this process.
import AppKit
import SwiftUI
import WeatherCore

enum Probe {
    static var appeared: [String] = []
    static var draft: Binding<String>?
    static var window: NSWindow?
    static var activations = 0
    static var everOrderedIn = false
}

final class FakeApp {
    func activate(ignoringOtherApps flag: Bool) { Probe.activations += 1 }
}
let NSApp = FakeApp()

class NSWindow: AppKit.NSWindow {
    /// What isVisible / isMiniaturized report: the window is never really put on screen.
    var shown = false
    var minimised = false
    override init(contentRect: NSRect, styleMask style: AppKit.NSWindow.StyleMask,
                  backing backingStoreType: AppKit.NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        Probe.window = self
    }
    override var isVisible: Bool { shown && !minimised }
    /// AppKit's own answer: whether the window was ever really ordered in.
    var reallyOrderedIn: Bool { super.isVisible || super.isMiniaturized }
    override var isMiniaturized: Bool { minimised }
    override func makeKeyAndOrderFront(_ sender: Any?) { shown = true; minimised = false }
    override func orderFront(_ sender: Any?) { shown = true }
    override func close() { shown = false }
    override func center() { setFrameOrigin(NSPoint(x: -20000, y: -20000)) }
    override func setFrameAutosaveName(_ name: AppKit.NSWindow.FrameAutosaveName) -> Bool { true }
}

final class ShellState {
    var model: AppModel? { nil }
    var sources: SourcesViewModel? { nil }
}

/// A tab with one unsaved text, like NetworkRow's key draft.
struct DraftTab: View {
    let name: String
    @State private var draft = ""
    var body: some View {
        Text(name).onAppear {
            Probe.appeared.append(name)
            if name == "stations" { Probe.draft = $draft }
        }
    }
}
struct SourcesSettingsTab: View {
    let appModel: AppModel?
    let sourcesVM: SourcesViewModel?
    var body: some View { DraftTab(name: "sources") }
}
struct WeightsSettingsTab: View {
    let appModel: AppModel?
    var body: some View { DraftTab(name: "weights") }
}
struct StationsSettingsTab: View {
    let appModel: AppModel?
    var body: some View { DraftTab(name: "stations") }
}
struct GeneralSettingsTab: View {
    let appModel: AppModel?
    var body: some View { DraftTab(name: "general") }
}
