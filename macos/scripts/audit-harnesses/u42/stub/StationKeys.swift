// PROBE STUB (U42 harness builds only; never part of an Xcode target): scratch_build.sh puts it in
// place of Weather/Detail/StationKeys.swift in a temporary copy of the sources, so that no probe can
// reach the user's Keychain. The keys live in memory, nothing is saved, and there is no
// Security-framework call at all. Keep its API in step with the real StationKeys.

import Foundation
import WeatherCore

nonisolated enum StationKeys {
    static let service = "probe.stub.station-keys"
    static let maxLength = 4096
    nonisolated(unsafe) private static var keys: [WxStationNetwork: String] = [:]

    static func key(for network: WxStationNetwork) -> String? {
        keys[network]
    }

    @discardableResult
    static func setKey(_ key: String?, for network: WxStationNetwork) -> Bool {
        keys[network] = normalized(key)
        return true
    }

    /// Copied from StationKeys.swift (no Keychain involved).
    static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength,
              !trimmed.contains(where: { $0.isNewline })
        else {
            return nil
        }
        return trimmed
    }
}
