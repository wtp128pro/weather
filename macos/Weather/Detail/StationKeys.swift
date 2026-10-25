// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationKeys.swift - the personal API keys of the station networks that need
// one (Settings > Stations). They live in the user's login Keychain as generic
// passwords of this app, never in a file, and are sent only to their own
// network's server over HTTPS.

import Foundation
import Security
import WeatherCore

/// Keychain storage of the station networks' keys.
nonisolated enum StationKeys {
    /// The Keychain service of every key; the account is the network's raw value.
    static let service = "io.github.wtp128pro.Weather.station-keys"
    /// Longer pasted text is not a key.
    static let maxLength = 4096

    /// The saved key of a network, nil when there is none.
    static func key(for network: WxStationNetwork) -> String? {
        var query = baseQuery(network)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            return nil
        }
        return key
    }

    /// Saves (or, for nil or blank text, removes) a network's key; false when the Keychain refused.
    @discardableResult
    static func setKey(_ key: String?, for network: WxStationNetwork) -> Bool {
        let clean = normalized(key)
        let query = baseQuery(network)
        guard let clean else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(clean.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            return true
        }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Neginato Mezora: \(network.displayName) key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// The text as a key: surrounding whitespace and line breaks removed; nil when blank or too long.
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

    private static func baseQuery(_ network: WxStationNetwork) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: network.rawValue,
        ]
    }
}
