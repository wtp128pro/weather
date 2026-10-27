#!/usr/bin/env python3
"""extract.py <src_root> <out_dir> [--mutant NAME]
U43 evidence harness generator. Copies VERBATIM regions of the app-target sources under
<src_root> (Weather/..., WeatherCore/...) into Swift files under <out_dir>, each wrapped in a
harness type whose stored properties stand in for SwiftUI @State. Nothing is paraphrased: every
region is cut by marker + bracket matching (a small Swift lexer skips strings, interpolations and
comments) and the generator fails loudly when a marker is missing or ambiguous.
--mutant applies one named breaking edit to the extracted NEW text (non-vacuity runs)."""
import os, re, sys

def lex_skip_string(s, i):
    """s[i] is the opening quote of a string literal; returns the index after its end."""
    if s.startswith('"""', i):
        j = i + 3
        while True:
            k = s.find('"""', j)
            if k < 0: raise SystemExit("unterminated multi-line string")
            if s[k - 1] != '\\': return k + 3
            j = k + 1
    j = i + 1
    while j < len(s):
        c = s[j]
        if c == '\\':
            if s[j + 1] == '(':
                j = match(s, j + 1, '(', ')') + 1
                continue
            j += 2
            continue
        if c == '"': return j + 1
        if c == '\n': raise SystemExit("newline in string literal at %d" % j)
        j += 1
    raise SystemExit("unterminated string")

def match(s, i, open_c, close_c):
    """s[i] == open_c; returns the index of the matching close_c (strings/comments skipped)."""
    assert s[i] == open_c, (s[i:i + 20], open_c)
    depth = 0
    j = i
    while j < len(s):
        if s.startswith('//', j):
            j = s.index('\n', j)
            continue
        if s.startswith('/*', j):
            j = s.index('*/', j) + 2
            continue
        c = s[j]
        if c == '"':
            j = lex_skip_string(s, j)
            continue
        if c == open_c: depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0: return j
        j += 1
    raise SystemExit("no match for %s at %d" % (open_c, i))

def find_once(s, marker, start=0, required=True):
    k = s.find(marker, start)
    if k < 0:
        if required: raise SystemExit("marker not found: %r" % marker)
        return -1
    if s.find(marker, k + 1) >= 0 and start == 0:
        raise SystemExit("marker not unique: %r" % marker)
    return k

def line_start(s, k):
    return s.rfind('\n', 0, k) + 1

def decl(s, marker, opener='{', required=True):
    """The declaration starting at the line holding `marker`, through the bracket that matches
    the first `opener` after the marker."""
    k = find_once(s, marker, required=required)
    if k < 0: return ""
    o = s.index(opener, k + len(marker) - 1 if marker.endswith(opener) else k)
    close = {'{': '}', '[': ']', '(': ')'}[opener]
    e = match(s, o, opener, close)
    return s[line_start(s, k):e + 1] + "\n"

def body(s, marker, after=None):
    """The text between the braces of the closure/block opened at the end of `marker`
    (searched after the `after` marker when given)."""
    start = find_once(s, after) + len(after) if after else (find_once(s, marker) if marker != "{" else 0)
    k = s.find(marker, start)
    if k < 0: raise SystemExit("marker not found: %r" % marker)
    o = s.index('{', k + len(marker) - 1)
    e = match(s, o, '{', '}')
    return s[o + 1:e]

def paren_arg(s, marker, after=None):
    """The text inside the parentheses opened at the end of `marker`."""
    start = find_once(s, after) + len(after) if after else 0
    k = s.find(marker, start)
    if k < 0: raise SystemExit("marker not found: %r" % marker)
    o = k + len(marker) - 1
    e = match(s, o, '(', ')')
    return s[o + 1:e]

def stmt_line(s, marker):
    k = find_once(s, marker)
    e = s.index('\n', k)
    return s[line_start(s, k):e] + "\n"

def cond_after(s, after, nth):
    """The condition of the nth `} else if <cond> {` after the `after` marker."""
    k = find_once(s, after)
    for _ in range(nth):
        k = s.index('} else if ', k) + len('} else if ')
    o = k
    # the condition ends at the `{` that opens the branch (balanced parentheses)
    j = o
    depth = 0
    while True:
        c = s[j]
        if c == '(':
            j = match(s, j, '(', ')') + 1
            continue
        if c == '{': break
        j += 1
    return s[o:j].strip()

def region(s, start_marker, end_marker):
    a = line_start(s, find_once(s, start_marker))
    b = line_start(s, find_once(s, end_marker))
    return s[a:b]

def read(root, rel):
    with open(os.path.join(root, rel)) as f:
        return f.read()

MUTANTS = {
    # U22-F2: back to a substring test inside the whole-word rule
    "badge-substring": ("Weather/Shell/ShellRow.swift",
                        "!$0.words.isDisjoint(with: words)",
                        "$0.words.contains(where: { lower.contains($0) })"),
    # U23-F1: rebuild the open window's views again
    "settings-rebuild": ("Weather/Settings/SettingsView.swift",
                         "if !window.isVisible && !window.isMiniaturized {", "if true {"),
    # U23-F3: Cancel no longer resets the error
    "f3-cancel": ("Weather/Settings/StationsSettingsTab.swift",
                  'Button("Cancel") { replacing = false; draft = ""; saveFailed = false }',
                  'Button("Cancel") { replacing = false; draft = "" }'),
    # U23-F5: signed caption again
    "f5-signed": ("Weather/Settings/StationsSettingsTab.swift",
                  "by up to ±\\(StationsSettingsText.amount(", "by up to \\(StationsSettingsText.delta("),
    # U23-F6 + ruling: drop the tS == 0 guard
    "f6-ts0": ("Weather/Settings/StationsSettingsTab.swift",
               "let isNow = h.tS != 0 && h.hour == nowHour", "let isNow = h.hour == nowHour"),
    # U23-F6 + ruling: read the hour from tS (maps tS 0 to a 1970 hour)
    "f6-hour-from-tS": ("Weather/Settings/StationsSettingsTab.swift",
                        "let isNow = h.tS != 0 && h.hour == nowHour",
                        "let isNow = Self.localHour(h.tS, timeZone: timeZone) == nowHour"),
    # U24-F1: the guard compares with the view model's placeholder again
    "f1-guard": ("Weather/Picker/PickerView.swift",
                 "field.placeholderString == PickerView.searchFieldPlaceholder",
                 "field.placeholderString == PickerViewModel.searchPlaceholder"),
    # U24-F2: Location Name Return no longer skips stale candidates
    "f2-guard": ("Weather/Picker/PickerView.swift",
                 "guard !addressCandidatesAreStale else {", "guard true else {"),
    # U24-F3: count-only reset again
    "f3-count": ("Weather/Picker/PickerView.swift",
                 ".onChange(of: displayedRows.map(\\.place.key)) {", ".onChange(of: displayedRows.count) {"),
    # U24-F5: a search cancelled by a different edit keeps counting as in flight
    "f5-inflight": ("Weather/Picker/PickerView.swift",
                    "        addressSearchTask?.cancel()\n        addressQueryInFlight = nil\n",
                    "        addressSearchTask?.cancel()\n"),
    # U24-F5: an answer still counts as the latest search after a later one started
    "f5-answered": ("Weather/Picker/PickerView.swift",
                    "        addressQueryInFlight = nil\n        addressQueryAnswered = nil\n",
                    "        addressQueryInFlight = nil\n"),
    # U24-F5: no dedupe at all
    "f5-nodedupe": ("Weather/Picker/PickerView.swift",
                    "guard !repeatsLatestSearch(query) else {".replace("repeatsLatestSearch", "repeatsLatestAddressSearch"),
                    "guard true else {"),
}

def main():
    root, out = sys.argv[1], sys.argv[2]
    mutant = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == "--mutant" else None
    os.makedirs(out, exist_ok=True)
    src = {}
    for rel in ["Weather/Shell/ShellRow.swift", "Weather/Settings/SettingsView.swift",
                "Weather/Settings/StationsSettingsTab.swift", "Weather/Picker/PickerView.swift"]:
        src[rel] = read(root, rel)
    if mutant:
        rel, a, b = MUTANTS[mutant]
        if src[rel].count(a) != 1: raise SystemExit("mutant %s: anchor count %d" % (mutant, src[rel].count(a)))
        src[rel] = src[rel].replace(a, b)
    # AppModel's hour rows always come from the REPO copy (U32's tS == 0 is in it)
    appmodel = read(os.environ["REPO"], "WeatherCore/App/AppModel.swift")

    # ---- H1 badge (ShellRow.swift)
    row = src["Weather/Shell/ShellRow.swift"]
    words = ""
    if "private static let badgeWords" in row:
        k = find_once(row, "private static let badgeWords")
        o = row.index("= [", k) + 2
        words = row[line_start(row, k):match(row, o, '[', ']') + 1] + "\n"
    sym = decl(row, "static func symbolForPlace(_ place: WxPlace) -> String? {")
    with open(os.path.join(out, "badge_extract.swift"), "w") as f:
        f.write("import WeatherCore\n\n/// VERBATIM from Weather/Shell/ShellRow.swift\nenum ShellRow {\n" + words + sym + "}\n")

    # ---- H2 settings window (SettingsView.swift: manager, tab enum, selection, SettingsView)
    sv = src["Weather/Settings/SettingsView.swift"]
    reg = region(sv, "/// Manages a standalone NSWindow", "// MARK: - Tab 1")
    with open(os.path.join(out, "settings_extract.swift"), "w") as f:
        f.write("import AppKit\nimport SwiftUI\nimport WeatherCore\n\n// VERBATIM from Weather/Settings/SettingsView.swift\n" + reg)

    # ---- H3 stations tab (StationsSettingsTab.swift)
    st = src["Weather/Settings/StationsSettingsTab.swift"]
    text_enum = decl(st, "enum StationsSettingsText {")
    caption = paren_arg(st, 'Text("For each place and hour'[:5], after='Text("Correct forecasts with what nearby stations measure")')
    replace_body = body(st, 'Button("Replace…") {')
    cancel_body = body(st, 'Button("Cancel") {')
    save_fn = decl(st, "private func save() {")
    editor_cond = st[find_once(st, "private func keyEditor"):]
    editor_cond = editor_cond[editor_cond.index("        if ") + len("        if "):]
    editor_cond = editor_cond[:editor_cond.index(" {")]
    local_hour = decl(st, "static func localHour(", required=False) if "static func localHour(" in st else ""
    is_now = stmt_line(st, "let isNow = ")
    now_hour = stmt_line(st, "let nowHour = ") if "let nowHour = " in st else ""
    lc = appmodel[find_once(appmodel, "public var localCorrections: [LocalCorrection] {"):]
    hours_stmt = lc[line_start(lc, lc.index("var calendar = Calendar(identifier: .gregorian)")):]
    hours_stmt = hours_stmt[:hours_stmt.index("\n", match(hours_stmt, hours_stmt.index("{", hours_stmt.index("let hours = (0..<24).map {")), "{", "}")) + 1]
    with open(os.path.join(out, "stations_extract.swift"), "w") as f:
        f.write("""@testable import WeatherCore
import Foundation

// VERBATIM from Weather/Settings/StationsSettingsTab.swift
""" + text_enum + """
/// NetworkRow's key editor state: its three @State values, its button actions and save().
final class NetworkRowSim {
    var draft = ""
    var replacing = false
    var saveFailed = false
    var hasKey: Bool
    let network = "met-office"
    let store: StubStore
    init(hasKey: Bool, store: StubStore) { self.hasKey = hasKey; self.store = store }
    func pressReplace() {""" + replace_body + """}
    func pressCancel() {""" + cancel_body + """}
    func pressSave() { save() }
""" + save_fn + """
    /// keyEditor's branch: the editor (with the error line when saveFailed) unless this holds.
    var showsSavedLabel: Bool { """ + editor_cond + """ }
    var showsKeychainError: Bool { !showsSavedLabel && saveFailed }
}

struct CaptionSim {
    let appModel: StubUnits
    /// LocalCorrectionsSection's `let units = StationsSettingsText.units(of: appModel)` (newer trees).
    var units: WxUnits { appModel.units }
    var caption: String { """ + caption + """ }
}

/// HourlyCorrectionBars' "now" test: its stored nowS/timeZone and the isNow statement.
struct BarsSim {
    let nowS: Int64
    let timeZone: String
""" + local_hour + """
    func isNow(_ h: AppModel.LocalCorrection.Hour) -> Bool {
""" + now_hour + is_now + """        return isNow
    }
}

/// AppModel.localCorrections' 24 hour rows of one place (VERBATIM from WeatherCore/App/AppModel.swift).
func hourRows(timezone: String, nowS: Int64) -> [AppModel.LocalCorrection.Hour] {
    typealias LocalCorrection = AppModel.LocalCorrection
    let p = (timezone: timezone, lon: 0.0)
    let item = (key: "k", place: p)
    let localBias = StubBias()
    _ = item
""" + hours_stmt + """    return hours
}
""")

    # ---- H4 picker logic + H5 undo bridge (PickerView.swift)
    pv = src["Weather/Picker/PickerView.swift"]
    parts = []
    for m in ["private var trimmedQuery: String {", "private var trimmedLocationName: String {",
              "private var isShowingAddressResults: Bool {", "fileprivate struct DisplayedRow: Identifiable {",
              "private var displayedRows: [DisplayedRow] {", "private func edit(_ newText: String) {",
              "private func triggerAddressSearch(immediate: Bool) {"]:
        parts.append(decl(pv, m))
    for m in ["private var addressCandidatesAreStale: Bool {", "private func repeatsLatestAddressSearch("]:
        if m in pv: parts.append(decl(pv, m))
    search_submit = body(pv, ".onSubmit {", after=".accessibilityLabel(PickerViewModel.searchAccessibilityLabel)")
    name_submit = body(pv, ".onSubmit {", after=".focused($focus, equals: .locationName)")
    spinner_cond = cond_after(pv, "// 3. Status line", 1)
    count_cond = cond_after(pv, "// 3. Status line", 2)
    oc_k = pv.index(".onChange(of: ", find_once(pv, ".contextMenu(forSelectionType:"))
    onchange_expr = pv[oc_k + len(".onChange(of: "):match(pv, oc_k + len(".onChange"), "(", ")")]
    onchange_body = body(pv[oc_k:], "{")
    disappear_body = body(pv, ".onDisappear {")
    with open(os.path.join(out, "picker_extract.swift"), "w") as f:
        f.write("""import Foundation
import WeatherCore

/// PickerView's search state: its @State values as stored properties, and VERBATIM members,
/// closures and conditions from Weather/Picker/PickerView.swift.
final class PickerSim {
    var cursor: Int?
    var draft = ""
    var locationName = ""
    var addressCandidates: [WxAddressCandidate] = []
    var addressCandidatesQuery = ""
    var addressQueryInFlight: String? = nil
    var addressQueryAnswered: (query: String, at: ContinuousClock.Instant)? = nil
    var isSearchingAddresses = false
    var addressErrorText: String? = nil
    var addressSearchTask: Task<Void, Never>? = nil
    let viewModel = StubPickerVM()
    var activated: [String] = []
    private var lastOnChange: AnyHashable? = nil
    // Newer trees: the units preselection state the list's onChange also updates (not modelled here).
    enum Focus: Hashable { case search, locationName, results }
    var focus: Focus? = .search
    var unitsFollowPointer = false
    private func syncUnitsHighlight() {}

    private func isCandidateAlreadySaved(_ place: WxPlace, defaultIsAdded: Bool = false) -> Bool { defaultIsAdded }
    private func activateDisplayedRow(at index: Int) {
        let rows = displayedRows
        guard index >= 0, index < rows.count else { return }
        activated.append(rows[index].title)
    }

""" + "".join(parts) + """
    func typeInSearchField(_ text: String) { edit(text) }
    func returnInSearchField() {""" + search_submit + """}
    func returnInLocationName() {""" + name_submit + """}
    func disappear() {""" + disappear_body + """}
    /// The status line's spinner and count branches.
    var showsSpinner: Bool { addressErrorText == nil && (""" + spinner_cond + """) }
    var showsCount: Bool { addressErrorText == nil && !showsSpinner && (""" + count_cond + """) }
    var statusLine: String {
        showsSpinner ? "Searching addresses and weather locations…"
            : showsCount ? "Matching addresses & locations (\\(displayedRows.count))" : "-"
    }
    var rowTitles: [String] { displayedRows.map(\\.title) }
    /// One SwiftUI update: the list's onChange runs when its value changed since the last one.
    func render() {
        let value = AnyHashable(""" + onchange_expr + """)
        if let last = lastOnChange, last != value { onChangeBody() }
        lastOnChange = value
    }
    private func onChangeBody() {""" + onchange_body + """}
}
""")
    # H5: the search TextField as PickerView declares it, and the FieldAnchor extension
    tf_a = find_once(pv, "                    TextField(\n")
    tf_b = pv.index("\n", find_once(pv, ".focused($focus, equals: .search)")) + 1
    textfield = pv[line_start(pv, tf_a):tf_b]
    placeholder = stmt_line(pv, "static let searchFieldPlaceholder") if "static let searchFieldPlaceholder" in pv else ""
    # the first PickerView extension: FieldAnchor and FieldAnchorView
    ek = pv.index("extension PickerView {")
    if "FieldAnchor" not in pv[ek:pv.index("extension PickerView {", ek + 1)]: raise SystemExit("FieldAnchor block moved")
    ext = pv[line_start(pv, ek):match(pv, pv.index("{", ek), "{", "}") + 1] + "\n"
    with open(os.path.join(out, "undo_extract.swift"), "w") as f:
        f.write("""import AppKit
import SwiftUI
import WeatherCore

/// The search field of PickerView, as declared there (VERBATIM), in a host with the members it uses.
struct PickerView: View {
    enum Focus: Hashable { case search }
    @FocusState private var focus: Focus?
    @State private var draft = ""
    @State private var fieldAnchor = FieldAnchor()
""" + placeholder + """
    private func edit(_ newText: String) {
        draft = newText
        UndoProbe.edits.append(newText)
    }

    var body: some View {
        HStack {
""" + textfield + """        }
        .frame(width: 400)
    }
}

// VERBATIM from Weather/Picker/PickerView.swift
""" + ext)
    print("extracted into", out, "mutant", mutant)

main()
