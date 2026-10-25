// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationSettings.swift - the user's choices for the station layer, kept apart
// from settings.json (whose schema stays the C one, like weights.json):
// whether the learned local corrections are applied to the forecasts, and which
// station networks are turned off. The API keys of the networks that need one
// are not here: the app keeps them in the Keychain.

import Foundation

/// The station-layer preferences ("<config>/weather/station-settings.json").
public struct WxStationSettings: Sendable, Equatable, Codable {
    /// The learned local corrections (WxLocalBias) are applied to the forecasts shown. Learning
    /// goes on either way, so turning them back on needs no new learning.
    public var localCorrectionsEnabled = true
    /// Networks the user turned off: not fetched, not blended.
    public var disabledNetworks: Set<WxStationNetwork> = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localCorrectionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .localCorrectionsEnabled) ?? true
        // a network this version does not know is ignored, not an error
        let names = try c.decodeIfPresent([String].self, forKey: .disabledNetworks) ?? []
        disabledNetworks = Set(names.compactMap(WxStationNetwork.init(rawValue:)))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(localCorrectionsEnabled, forKey: .localCorrectionsEnabled)
        try c.encode(disabledNetworks.map(\.rawValue).sorted(), forKey: .disabledNetworks)
    }

    private enum CodingKeys: String, CodingKey {
        case localCorrectionsEnabled, disabledNetworks
    }

    public func isEnabled(_ network: WxStationNetwork) -> Bool {
        !disabledNetworks.contains(network)
    }

    // MARK: - Persistence

    /// The file, "<config>/weather/station-settings.json".
    public static func defaultPath(configDirectory: String) -> String {
        let base = configDirectory.hasSuffix("/") ? String(configDirectory.dropLast()) : configDirectory
        return "\(base)/weather/station-settings.json"
    }

    /// The saved settings; the defaults when there are none or they cannot be read.
    public static func load(path: String) -> WxStationSettings {
        guard !path.isEmpty,
              let data = try? FileIO.readBounded(path: path, maxBytes: 64 * 1024),
              let value = try? JSONDecoder().decode(WxStationSettings.self, from: data)
        else {
            return WxStationSettings()
        }
        return value
    }

    public func save(path: String) {
        guard !path.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileIO.writeAtomic(path: path, data: data)
    }
}
