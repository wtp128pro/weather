// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Registry.swift - WxRegistry: the extension point for weather data sources.
// Port of src/net/wx-registry.{h,c}.
//
// The registry owns the list of providers (in registration order), a
// per-provider "enabled" flag and at most one geocoder. Adding a data source
// to the app is exactly: conform to WxProvider, call `addProvider(_:)` once
// where the application builds its registry, add fixtures and tests. There is
// no removal: providers live as long as the registry.
//
// The change notification (C signal "changed") is delivered synchronously,
// after the registry state has been updated, only when the set of providers
// or an enabled flag really changed (a geocoder change does not count). A
// handler may call any registry function, including one that emits again: the
// nested emission runs the handlers again before the outer one continues (C
// GObject signal semantics, src/net/wx-registry.h:15-17).
//
// A registry is a main-actor object (C: "a main-thread object ... not
// thread-safe", src/net/wx-registry.h:19-21).

/// The provider list, enabled flags and geocoder slot (WxRegistry).
@MainActor
public final class WxRegistry {
    /// Most providers one registry accepts (WX_REGISTRY_MAX_PROVIDERS,
    /// src/net/wx-registry.h:34).
    public nonisolated static let maxProviders = 16

    /// Identifies a change handler for `removeChangeHandler(_:)`.
    public struct ChangeHandlerID: Hashable, Sendable {
        fileprivate let raw: UInt64
    }

    /// One registered provider. The id is copied at registration because the
    /// implementation's `id` is only required to be constant, not trusted
    /// (src/net/wx-registry.c:8-14).
    private struct Entry {
        let provider: any WxProvider
        let id: String
        var enabled: Bool
    }

    private var entries: [Entry] = []
    private var handlers: [(id: ChangeHandlerID, run: @MainActor () -> Void)] = []
    private var nextHandler: UInt64 = 1

    /// The geocoder, or nil when none is set (wx_registry_get_geocoder /
    /// wx_registry_set_geocoder). Setting it never notifies the change
    /// handlers; the registry holds a strong reference to it.
    public var geocoder: (any WxGeocoder)?

    /// An empty registry: no provider, no geocoder (wx_registry_new).
    public init() {}

    /// Registers `provider`, enabled, after the providers already present
    /// (wx_registry_add_provider, src/net/wx-registry.c:174-204).
    ///
    /// The provider's `id` is read once here and must match
    /// `[a-z0-9][a-z0-9_-]{0,31}` (`WxLimits.isValidID` and no '.'). Like the C
    /// string it is, it ends at its first U+0000. On success the registry
    /// holds a strong reference to `provider`, it is last in
    /// `listProviders()` and enabled, and the change handlers have run once.
    ///
    /// - Throws: `WxError` `.invalidArg`, checked in this order: "invalid
    ///   provider id"; "a provider with this id is already registered" (this
    ///   instance or another); "too many providers (limit 16)". Nothing
    ///   changes and no handler runs.
    public func addProvider(_ provider: any WxProvider) throws(WxError) {
        let id = provider.id
        guard Self.isValidProviderID(id) else {
            throw WxError(.invalidArg, "invalid provider id")
        }
        let key = Self.cString(id)
        if entryIndex(forKey: key) != nil {
            throw WxError(.invalidArg, "a provider with this id is already registered")
        }
        if entries.count >= Self.maxProviders {
            throw WxError(.invalidArg, "too many providers (limit \(Self.maxProviders))")
        }
        entries.append(Entry(provider: provider, id: key, enabled: true))
        emitChanged()
    }

    /// The provider registered under `id`, or nil (wx_registry_find_provider).
    /// `id` may be any text; it is only compared (as a C string).
    public func findProvider(id: String) -> (any WxProvider)? {
        entryIndex(forKey: Self.cString(id)).map { entries[$0].provider }
    }

    /// Every provider, enabled or not, in registration order
    /// (wx_registry_list_providers). The array is a snapshot: later additions
    /// do not change it.
    public func listProviders() -> [any WxProvider] {
        entries.map(\.provider)
    }

    /// Enables or disables the provider registered under `id`
    /// (wx_registry_set_enabled, src/net/wx-registry.c:227-242). A disabled
    /// provider stays registered but is skipped by `listCovering(_:)`.
    ///
    /// The change handlers run once if and only if the flag differed before.
    ///
    /// - Returns: true iff a provider is registered under `id` (whether or not
    ///   its flag changed); false for an unknown id (nothing changes).
    @discardableResult
    public func setEnabled(_ enabled: Bool, id: String) -> Bool {
        guard let index = entryIndex(forKey: Self.cString(id)) else {
            return false
        }
        if entries[index].enabled != enabled {
            entries[index].enabled = enabled
            emitChanged()
        }
        return true
    }

    /// True iff a provider is registered under `id` and enabled (new
    /// providers are enabled); false for a disabled or an unknown id
    /// (wx_registry_is_enabled).
    public func isEnabled(id: String) -> Bool {
        entryIndex(forKey: Self.cString(id)).map { entries[$0].enabled } ?? false
    }

    /// The providers that are enabled and whose `covers(_:)` accepts `place`,
    /// in registration order (wx_registry_list_covering,
    /// src/net/wx-registry.c:254-269). No I/O.
    ///
    /// A `covers` implementation may call back into the registry: the walk is
    /// index based and re-reads the count on every step, so a provider added
    /// meanwhile is visited as well (it is last), and a flag changed by a
    /// `covers` call applies to the providers not visited yet.
    public func listCovering(_ place: WxPlace) -> [any WxProvider] {
        var list: [any WxProvider] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            if entry.enabled && entry.provider.covers(place) {
                list.append(entry.provider)
            }
            index += 1
        }
        return list
    }

    /// Adds a change handler (g_signal_connect "changed"). Handlers run in the
    /// order they were added, synchronously, after the state was updated. A
    /// handler added during an emission first runs at the next emission; a
    /// handler removed during an emission does not run afterwards.
    @discardableResult
    public func addChangeHandler(_ handler: @escaping @MainActor () -> Void) -> ChangeHandlerID {
        let id = ChangeHandlerID(raw: nextHandler)
        nextHandler += 1
        handlers.append((id: id, run: handler))
        return id
    }

    /// Removes a change handler (g_signal_handler_disconnect); an unknown id
    /// is ignored.
    public func removeChangeHandler(_ id: ChangeHandlerID) {
        handlers.removeAll { $0.id == id }
    }

    // MARK: - Private

    /// Runs the change handlers registered when the emission starts.
    private func emitChanged() {
        let ids = handlers.map(\.id)
        for id in ids {
            guard let handler = handlers.first(where: { $0.id == id }) else {
                continue
            }
            handler.run()
        }
    }

    /// The index of the entry registered under `key` (find_entry). The
    /// comparison is byte-wise like strcmp, not Unicode canonical equivalence.
    private func entryIndex(forKey key: String) -> Int? {
        entries.firstIndex { $0.id.utf8.elementsEqual(key.utf8) }
    }

    /// The registry's id rule: `WxLimits.isValidID` and no '.'
    /// (provider_id_is_valid, src/net/wx-registry.c:141-145).
    private nonisolated static func isValidProviderID(_ id: String) -> Bool {
        WxLimits.isValidID(bytes: id.utf8) && !cString(id).utf8.contains(0x2E)
    }

    /// `text` up to its first U+0000, as C would read it.
    private nonisolated static func cString(_ text: String) -> String {
        guard let nul = text.utf8.firstIndex(of: 0) else {
            return text
        }
        return String(decoding: text.utf8[..<nul], as: UTF8.self)
    }
}
