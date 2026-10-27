// Stand-ins for the picker harness. WxAddressGeocoder is SHADOWED in this module: the extracted
// triggerAddressSearch calls this scripted, network-free search.
import WeatherCore

func wxPlace(_ name: String, _ lat: Double, _ lon: Double) -> WxPlace {
    try! WxPlace(name: name, admin1: "Region", country: "United States", countryCode: "US", lat: lat, lon: lon,
                 timezone: "America/Chicago")
}
func candidates(_ names: [String], lat0: Double) -> [WxAddressCandidate] {
    names.enumerated().map { i, n in
        WxAddressCandidate(primaryTitle: n, subtitle: "Region", fullAddress: "", place: wxPlace(n, lat0 + Double(i), -90), kind: .city)
    }
}

enum WxAddressGeocoder {
    static var latencyMs = 500
    static var calls: [(query: String, atMs: Int)] = []
    static var epoch = ContinuousClock.now
    static let table: [String: [WxAddressCandidate]] = [
        "Springfield": candidates(["Springfield IL", "Springfield MO", "Springfield MA", "Springfield OR", "Springfield OH"], lat0: 30),
        "Springfield, IL": candidates(["Springfield IL (Sangamon)", "Springfield IL Airport", "Springfield IL Station",
                                       "Springfield IL Capitol", "Springfield IL Lake"], lat0: 36),
        "Portland, OR": candidates(["Portland OR", "Portland Multnomah", "Portland Airport", "Portland State Univ",
                                    "Portland Zoo"], lat0: 42),
        "Portland": candidates(["Portland OR", "Portland ME"], lat0: 42),
        "Berlin": candidates(["Berlin DE", "Berlin NH", "Berlin WI"], lat0: 20),
    ]
    static func search(query: String) async -> [WxAddressCandidate] {
        calls.append((query, nowMs()))
        try? await Task.sleep(for: .milliseconds(latencyMs))
        return table[query] ?? []
    }
    static func nowMs() -> Int {
        let d = ContinuousClock.now - epoch
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

struct StubRow {
    let id: Int
    let place: WxPlace
    let isAdded: Bool
    let tooltip: String
}
/// PickerViewModel's rows: the empty-query suggestions, nothing for a typed query (its own city
/// search is not modelled).
final class StubPickerVM {
    var rows: [StubRow] = []
    func textChanged(to text: String) {
        rows = text.isEmpty
            ? ["Miami", "New York", "London", "Tokyo", "Jacksonville"].enumerated().map {
                StubRow(id: $0, place: wxPlace($1, 10 + Double($0), 10), isAdded: false, tooltip: $1)
            }
            : []
    }
    func submit() {}
}
