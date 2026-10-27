// U43 harness H2 (U23-F1): SettingsWindowManager.present on an open window, old vs new.
import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func spin() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    if Probe.window?.reallyOrderedIn == true { Probe.everOrderedIn = true }
}
var failures: [String] = []
func pin(_ ok: Bool, _ what: String) { print((ok ? "PIN ok   " : "PIN FAIL ") + what); if !ok { failures.append(what) } }
func controller() -> ObjectIdentifier? { Probe.window?.contentViewController.map(ObjectIdentifier.init) }
func draft() -> String { Probe.draft?.wrappedValue ?? "<none>" }
func lastTab() -> String { Probe.appeared.last ?? "<none>" }

let shell = ShellState()
let mgr = SettingsWindowManager.shared
// 1. Stations & Keys… opens Settings on Stations; the user pastes a key but does not press Save.
mgr.showSettings(state: shell, initialTab: .stations); spin()
Probe.draft?.wrappedValue = "pasted-key"; spin()
let c1 = controller()
print("1 open on Stations: tab=\(lastTab()) draft=\(draft()) visible=\(Probe.window?.isVisible ?? false) offscreen-origin=\(Probe.window?.frame.origin ?? .zero)")
// 2. Stations & Keys… again while it is open.
mgr.showSettings(state: shell, initialTab: .stations); spin()
print("2 Stations & Keys… while open: same views=\(controller() == c1) tab=\(lastTab()) draft=\(draft())")
pin(controller() == c1 && draft() == "pasted-key", "re-request while open keeps the views and the unsaved key draft")
// 3. Cmd-, (Data Sources & Weights…, tab .sources) while open: the requested tab is shown.
Probe.appeared.removeAll()
mgr.showSettings(state: shell, initialTab: .sources); spin()
print("3 Cmd-, while open: same views=\(controller() == c1) appeared=\(Probe.appeared)")
pin(Probe.appeared.last == "sources", "a request for another tab switches to it")
// 4. Back to Stations & Keys…: whether the TabView kept the other tab's state (reported, not pinned).
mgr.showSettings(state: shell, initialTab: .stations); spin()
print("4 back to Stations: same views=\(controller() == c1) tab=\(lastTab()) draft=\(draft())")
// 5. The toolbar gear (showSettings(model:sources:), tab .sources) while open.
Probe.draft?.wrappedValue = "pasted-key-2"; spin()
Probe.appeared.removeAll()
mgr.showSettings(model: nil, sources: nil); spin()
print("5 gear while open: same views=\(controller() == c1) appeared=\(Probe.appeared)")
pin(controller() == c1 && Probe.appeared.last == "sources", "the gear keeps the views and shows Sources")
mgr.showSettings(state: shell, initialTab: .stations); spin()
// 6. Close, then Stations & Keys…: a closed window starts from fresh views (decided behaviour).
Probe.window?.close(); spin()
mgr.showSettings(state: shell, initialTab: .stations); spin()
let c6 = controller()
print("6 close then reopen: same views=\(c6 == c1) tab=\(lastTab()) draft=\(draft())")
pin(c6 != c1 && draft() == "" && lastTab() == "stations", "reopening a closed window rebuilds it (unsaved edits are discarded, as before)")
// 7. Minimised with an unsaved draft, then Stations & Keys….
Probe.draft?.wrappedValue = "typed-then-minimised"; spin()
Probe.window?.minimised = true
mgr.showSettings(state: shell, initialTab: .stations); spin()
print("7 minimised then Stations & Keys…: same views=\(controller() == c6) draft=\(draft()) visible=\(Probe.window?.isVisible ?? false)")
pin(controller() == c6 && draft() == "typed-then-minimised", "a minimised window keeps its views and draft")
print("activate calls (faked): \(Probe.activations); window ever really ordered in (AppKit isVisible/isMiniaturized): \(Probe.everOrderedIn)")
print("settings: failures=\(failures.count)")
exit(failures.isEmpty ? 0 : 1)
