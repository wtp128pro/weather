// U43 harness H4 (U24-F2, F3, F5): the picker's search state machine, old vs new.
import Foundation
import WeatherCore

var failures: [String] = []
func pin(_ ok: Bool, _ what: String) { print((ok ? "PIN ok   " : "PIN FAIL ") + what); if !ok { failures.append(what) } }
func wait(_ ms: Int, _ sim: PickerSim) async { try? await Task.sleep(for: .milliseconds(ms)); sim.render() }
func fresh() -> PickerSim {
    WxAddressGeocoder.calls.removeAll(); WxAddressGeocoder.epoch = .now
    let s = PickerSim(); s.typeInSearchField(""); s.render(); return s
}
func type(_ s: PickerSim, _ text: String) { s.typeInSearchField(text); s.render() }
func calls() -> String { WxAddressGeocoder.calls.map { "\($0.query)@\($0.atMs)ms" }.joined(separator: ", ") }

// ---- U24-F2: a paste (or a refinement) keeps the old query's candidates on screen.
do {
    let s = fresh()
    type(s, "Springfield"); await wait(1000, s)
    s.locationName = "Home"
    type(s, "Portland, OR")                  // paste: never under 2 bytes
    await wait(100, s)
    print("F2 paste, 100 ms later: rows=\(s.rowTitles.prefix(2)) status=\"\(s.statusLine)\"")
    s.returnInLocationName()
    print("F2 Location Name Return before the answer: activated=\(s.activated)")
    pin(s.activated.isEmpty, "F2 Location Name Return does not add an earlier query's candidate")
    pin(s.showsSpinner, "F2 the status line shows the search, not the earlier query's count")
    await wait(800, s)
    s.returnInLocationName()
    print("F2 after the answer: status=\"\(s.statusLine)\" activated=\(s.activated)")
    pin(s.activated == ["Portland OR"], "F2 once answered, Return adds the new query's top row")
}
do {
    let s = fresh()
    type(s, "Springfield"); await wait(1000, s)
    s.locationName = "Home"
    for t in ["Springfield,", "Springfield, ", "Springfield, I", "Springfield, IL"] { type(s, t) }
    await wait(100, s)
    s.returnInLocationName()
    print("F2 refinement 'Springfield' -> 'Springfield, IL', Return before the answer: activated=\(s.activated) status=\"\(s.statusLine)\"")
    pin(s.activated.isEmpty, "F2 refinement: no stale candidate added")
}
do {
    let s = fresh()
    type(s, "Springfield"); await wait(1000, s)
    s.locationName = "Home"
    for t in ["P", "Po", "Por", "Portland"] { type(s, t) }   // select-all and retype: passes 1 byte
    await wait(100, s)
    s.returnInLocationName()
    print("F2 control, retyped from scratch (passes 'P', candidates cleared at the 2-byte guard): rows=\(s.rowTitles) activated=\(s.activated)")
    pin(s.activated.isEmpty, "F2 control: retyping clears the candidates in both versions")
}

// ---- U24-F3: the cursor is a row position.
do {
    let s = fresh()
    type(s, "Springfield"); await wait(1000, s)
    s.cursor = 3; s.render()                 // a click on row 3 (List(selection: $cursor))
    type(s, "Portland, OR"); await wait(1000, s)
    print("F3 paste, new 5 rows landed: cursor=\(String(describing: s.cursor)) rows=\(s.rowTitles)")
    s.returnInLocationName()
    print("F3 Location Name Return: activated=\(s.activated)")
    pin(s.cursor == nil, "F3 a new row set resets the cursor (no highlight on a place never chosen)")
}
do {
    let s = fresh()
    type(s, "Springfield"); await wait(1000, s)
    s.cursor = 3; s.render()
    type(s, "")                              // the clear button: edit("")
    await wait(50, s)
    print("F3 clear button: rows=\(s.rowTitles) cursor=\(String(describing: s.cursor))")
    s.returnInLocationName()
    print("F3 Location Name Return: activated=\(s.activated)")
    pin(s.cursor == nil, "F3 clearing the search resets the cursor")
}
do {
    let s = fresh()
    type(s, "Springfield"); await wait(1000, s)
    s.cursor = 2; s.render(); s.render()
    print("F3 control, arrow keys with unchanged rows: cursor=\(String(describing: s.cursor))")
    pin(s.cursor == 2, "F3 control: the cursor stays while the rows are the same")
}

// ---- U24-F5: Return restarting an identical search.
do {
    let s = fresh()
    type(s, "Berlin"); await wait(450, s)    // past the 280 ms debounce: the round is in flight
    s.returnInSearchField(); await wait(1200, s)
    print("F5a Return while 'Berlin' is in flight: calls=[\(calls())] rows=\(s.rowTitles.count)")
    pin(WxAddressGeocoder.calls.count == 1 && s.rowTitles.count == 3, "F5a Return does not restart the round in flight")
}
do {
    let s = fresh()
    type(s, "Berlin"); await wait(100, s)    // still in its debounce
    s.returnInSearchField(); await wait(1000, s)
    print("F5b Return during the debounce: calls=[\(calls())]")
    pin(WxAddressGeocoder.calls.count == 1 && WxAddressGeocoder.calls[0].atMs < 250, "F5b Return during the debounce starts the round at once (as before)")
}
do {
    let s = fresh()
    type(s, "Berlin"); await wait(1200, s)   // answered ~780 ms; Return ~420 ms after the answer
    s.returnInSearchField(); await wait(900, s)
    print("F5c Return >300 ms after the answer: calls=[\(calls())]")
    pin(WxAddressGeocoder.calls.count == 2, "F5c Return later than searchDelayMs after the answer retries (as before)")
}
do {
    let s = fresh()
    type(s, "Berlin")
    while s.isSearchingAddresses { await wait(10, s) }
    s.returnInSearchField(); await wait(900, s)
    print("F5d Return <300 ms after the answer: calls=[\(calls())]")
    pin(WxAddressGeocoder.calls.count == 1, "F5d Return within searchDelayMs of the answer does not search again")
}
do {
    let s = fresh()
    type(s, "Berlin"); await wait(450, s)
    type(s, "Berlin ")                       // whitespace only: the same trimmed query
    await wait(1200, s)
    print("F5e whitespace edit while in flight: calls=[\(calls())]")
    pin(WxAddressGeocoder.calls.count == 1, "F5e a whitespace-only edit does not restart the round in flight")
}
do {
    let s = fresh()
    type(s, "Berlin"); await wait(450, s)
    type(s, "Berlinx"); await wait(100, s)   // a different edit cancels the 'Berlin' round
    type(s, "Berlin"); await wait(1300, s)
    print("F5f cancelled by a different edit, then back: calls=[\(calls())] rows=\(s.rowTitles.count) searching=\(s.isSearchingAddresses) answers='\(s.addressCandidatesQuery)'")
    pin(WxAddressGeocoder.calls.map(\.query) == ["Berlin", "Berlin"] && !s.isSearchingAddresses && s.rowTitles.count == 3,
        "F5f a round cancelled by a different edit is not in flight: the query is searched again")
}
do {
    let s = fresh()
    type(s, "Berlin"); await wait(450, s)
    s.disappear()                            // the window closes mid-round
    s.returnInSearchField(); await wait(1000, s)
    print("F5g cancelled by onDisappear, then Return: calls=[\(calls())] rows=\(s.rowTitles.count)")
    pin(WxAddressGeocoder.calls.count == 2 && s.rowTitles.count == 3, "F5g a round cancelled on disappear is not in flight")
}
do {
    let s = fresh()
    type(s, "Berlin")
    while s.isSearchingAddresses { await wait(10, s) }
    type(s, "Berlinx"); type(s, "Berlin")    // within searchDelayMs of the answer: a later search came between
    await wait(1300, s)
    print("F5h answered, then 'Berlinx' and back within 300 ms: calls=[\(calls())] answers='\(s.addressCandidatesQuery)' field='\(s.draft)'")
    pin(s.addressCandidatesQuery == "Berlin" && !WxAddressGeocoder.calls.contains { $0.query == "Berlinx" },
        "F5h only the latest search counts: the pending 'Berlinx' round is cancelled, never answered over 'Berlin'")
}
print("picker: failures=\(failures.count)")
exit(failures.isEmpty ? 0 : 1)
