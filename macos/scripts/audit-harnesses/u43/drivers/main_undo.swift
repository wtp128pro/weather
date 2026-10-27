// U43 harness H5 (U24-F1): Undo in the search field reaches the binding through FieldAnchor.
// The window is borderless at -20000,-20000 and never ordered in; the process never activates.
import AppKit
import SwiftUI

enum UndoProbe { static var edits: [String] = [] }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
func findField(_ v: NSView) -> NSTextField? {
    if let f = v as? NSTextField, f.isEditable { return f }
    for s in v.subviews { if let f = findField(s) { return f } }
    return nil
}
let win = AppKit.NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 420, height: 60),
                          styleMask: [.borderless], backing: .buffered, defer: false)
let host = NSHostingView(rootView: PickerView())
win.contentView = host
spin()
guard let field = findField(host) else { print("no field"); exit(2) }
print("visible=\(win.isVisible) placeholder=\(field.placeholderString.debugDescription)")
_ = win.makeFirstResponder(field); spin()
guard let editor = win.firstResponder as? NSTextView, editor.isFieldEditor else { print("no field editor"); exit(3) }
editor.insertText("Lisbon", replacementRange: editor.selectedRange()); spin()
editor.breakUndoCoalescing()
editor.selectAll(nil); editor.deleteBackward(nil); spin()
print("typed Lisbon, cleared: field=\(editor.string.debugDescription) last edit=\((UndoProbe.edits.last ?? "").debugDescription)")
editor.undoManager?.undo(); spin()
let last = UndoProbe.edits.last ?? ""
print("after Undo: field=\(editor.string.debugDescription) last edit (draft, view model, address search)=\(last.debugDescription)")
let ok = editor.string == "Lisbon" && last == "Lisbon"
print((ok ? "PIN ok   " : "PIN FAIL ") + "U24-F1 Undo's text reaches the binding (draft == field)")
exit(ok ? 0 : 1)
