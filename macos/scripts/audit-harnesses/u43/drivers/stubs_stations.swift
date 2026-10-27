// In-memory stand-ins for the Stations tab's dependencies (no Security framework).
import WeatherCore

enum StationKeys {
    static func normalized(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
final class StubStore {
    var accepts = false
    func setKey(_ key: String?, for network: String) -> Bool { accepts }
}
struct StubUnits { let units: WxUnits }
struct StubBias {
    func correctionC(placeKey: String, lon: Double, at: Int64, nowS: Int64) -> Double { 1.0 }
    func samples(placeKey: String, lon: Double, at: Int64) -> Int { 3 }
}

/// The shape of Weather/Detail/StationNetworkFetcher.swift's StationNetworkStatus (StationsSettingsText reads it).
struct StationNetworkStatus: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case ok(reports: Int)
        case keyRejected(status: Int)
        case rateLimited
        case failed(status: Int)
        case unreachable
    }
    let outcome: Outcome
    let atS: Int64
    let placeName: String
}
