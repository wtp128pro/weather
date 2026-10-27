// U43 harness H3 (U23-F3, F5, F6): the Stations tab's key editor state, toggle caption and "now" bar.
@testable import WeatherCore
import Foundation

var failures: [String] = []
func pin(_ ok: Bool, _ what: String) { print((ok ? "PIN ok   " : "PIN FAIL ") + what); if !ok { failures.append(what) } }

// F3: Replace… -> Save rejected -> Cancel -> Replace… again.
let store = StubStore()
let row = NetworkRowSim(hasKey: true, store: store)
row.pressReplace(); row.draft = "abc123"; row.pressSave()
print("F3 after rejected save: saveFailed=\(row.saveFailed) error shown=\(row.showsKeychainError)")
row.pressCancel()
print("F3 after Cancel: saveFailed=\(row.saveFailed) error shown=\(row.showsKeychainError)")
row.pressReplace()
print("F3 after Replace… again (no attempt yet): saveFailed=\(row.saveFailed) error shown=\(row.showsKeychainError)")
pin(!row.showsKeychainError, "F3 a fresh Replace… shows no Keychain error before any attempt")
row.draft = "abc123"; row.pressSave()
pin(row.showsKeychainError, "F3 a new rejected save still shows the error")
// Replace… -> Save rejected -> Cancel -> Remove: the empty key editor of a network without a key.
let row2 = NetworkRowSim(hasKey: true, store: StubStore())
row2.pressReplace(); row2.draft = "abc123"; row2.pressSave(); row2.pressCancel()
row2.hasKey = false
print("F3 rejected save, Cancel, Remove: saveFailed=\(row2.saveFailed) error shown=\(row2.showsKeychainError)")
pin(!row2.showsKeychainError, "F3 after Cancel then Remove the empty editor shows no Keychain error")
store.accepts = true; row.draft = "abc123"; row.pressSave()
pin(!row.showsKeychainError && !row.replacing, "F3 a successful save clears it")

// F5: the toggle caption.
for u in [WxUnits.metric, .imperial] {
    let c = CaptionSim(appModel: StubUnits(units: u)).caption
    let tail = c[c.range(of: "by up to")!.lowerBound...]
    print("F5 \(u): \"...\(tail)\"")
}
let metric = CaptionSim(appModel: StubUnits(units: .metric)).caption
let imperial = CaptionSim(appModel: StubUnits(units: .imperial)).caption
pin(metric.contains("by up to ±4.0 °C.") && imperial.contains("by up to ±7.2 °F."), "F5 caption states the symmetric cap ±4.0 °C / ±7.2 °F")
pin(!metric.contains("+4.0") && !imperial.contains("+7.2"), "F5 caption has no '+' sign")

// F6: every minute of a local day, which bars are "now".
func epoch(_ tz: String, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Int64 {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: tz)!
    return Int64(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!.timeIntervalSince1970)
}
let days: [(String, Int, Int, Int, String)] = [
    ("America/New_York", 2026, 3, 8, "spring-forward"), ("America/New_York", 2026, 11, 1, "fall-back"),
    ("Europe/London", 2026, 3, 29, "spring-forward"), ("Europe/London", 2026, 10, 25, "fall-back"),
    ("Australia/Lord_Howe", 2026, 4, 5, "fall-back 30 min"), ("Australia/Lord_Howe", 2026, 10, 4, "spring-forward 30 min"),
    ("America/New_York", 2026, 6, 1, "control"), ("Asia/Kolkata", 2026, 6, 1, "control +05:30"),
]
var allClean = true, ts0Now = 0
for (tz, y, m, d, kind) in days {
    let start = epoch(tz, y, m, d), end = epoch(tz, y, m, d + 1)
    var multi = 0, none = 0, wrongHour = 0, skipped: [Int] = []
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: tz)!
    var s = start
    while s < end {
        let hours = hourRows(timezone: tz, nowS: s)
        skipped = hours.filter { $0.tS == 0 }.map(\.hour)
        let bars = BarsSim(nowS: s, timeZone: tz)
        let now = hours.filter { bars.isNow($0) }
        ts0Now += now.filter { $0.tS == 0 }.count
        if now.count > 1 { multi += 1 }
        if now.isEmpty { none += 1 }
        if now.count == 1 && now[0].hour != cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(s))) { wrongHour += 1 }
        s += 60
    }
    if multi + none + wrongHour > 0 { allClean = false }
    print("F6 \(tz) \(y)-\(m)-\(d) \(kind): minutes=\((end - start) / 60) with >1 now bar=\(multi) with 0=\(none) wrong hour=\(wrongHour) skipped hours(tS 0)=\(skipped)")
}
pin(allClean, "F6 exactly one bar, the local clock hour, is now in every minute of every day")
pin(ts0Now == 0, "F6 a skipped hour (tS 0) is never now (ruling, DECISIONS #24)")
// The ruling's trap: tS 0 read as a time is 1969-12-31 19:00 in New York; at 19:10 local on any day the
// skipped-hour row must not light up, whatever its hour number.
let ny = "America/New_York", at1910 = epoch(ny, 2026, 6, 1, 19, 10)
let synthetic = AppModel.LocalCorrection.Hour(hour: 19, tS: 0, correctionC: 0, samples: 0)
let synthNow = BarsSim(nowS: at1910, timeZone: ny).isNow(synthetic)
print("F6 synthetic Hour(hour: 19, tS: 0) at 2026-06-01 19:10 New York: isNow=\(synthNow)")
pin(!synthNow, "F6 an hour row with tS 0 is not now even when its hour number matches the clock")
print("stations: failures=\(failures.count)")
exit(failures.isEmpty ? 0 : 1)
