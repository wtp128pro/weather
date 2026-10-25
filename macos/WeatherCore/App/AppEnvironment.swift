// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AppEnvironment.swift - the composition root: the ONLY place that constructs
// the concrete providers and the geocoder and registers them (build_default_
// registry, src/ui/wx-app.c:291-301; wx-app.h:10-16), and that wires the
// registry, the service, the stores and the RefreshEngine into an AppModel
// (wx_app_new + wx_app_startup, wx-app.c:1467-1476, 1917-1931, 2134-2140).
//
// Production origins: every provider builds its HTTP client from its own fixed
// https constant (NWSProvider.baseURL https://api.weather.gov, OpenMeteoShared
// https://api.open-meteo.com and https://geocoding-api.open-meteo.com,
// METNorwayParse.baseURL https://api.met.no); no other host is reachable from
// what is built here, and nothing here makes a request.
//
// Storage (DECISIONS #11, roots are passed in): the C app keeps places.json and
// settings.json under g_get_user_config_dir()/weather and forecasts.json under
// g_get_user_cache_dir()/weather. On macOS the sandboxed app passes its
// container: Application Support stands for the config directory and Caches for
// the cache directory. Nothing here resolves ~ or reads the environment.

import Foundation

/// The composition root of the application.
@MainActor
public enum AppEnvironment {
    /// The two directories the stores live in.
    public struct StorageRoot: Sendable, Equatable {
        /// The C g_get_user_config_dir(): places.json and settings.json go to "<dir>/weather/".
        public let configDirectory: String
        /// The C g_get_user_cache_dir(): forecasts.json goes to "<dir>/weather/".
        public let cacheDirectory: String

        /// Explicit directories.
        public init(configDirectory: String, cacheDirectory: String) {
            self.configDirectory = configDirectory
            self.cacheDirectory = cacheDirectory
        }

        /// The layout of a home (in the sandbox: the container's Data directory):
        /// "<home>/Library/Application Support" and "<home>/Library/Caches".
        public init(home: URL) {
            let library = home.appendingPathComponent("Library", isDirectory: true)
            configDirectory = library.appendingPathComponent("Application Support", isDirectory: true).path
            cacheDirectory = library.appendingPathComponent("Caches", isDirectory: true).path
        }

        /// "<config>/weather/places.json" (WxPlaces.defaultPath).
        public var placesPath: String { WxPlaces.defaultPath(configDirectory: configDirectory) }
        /// "<config>/weather/settings.json" (WxSettings.defaultPath).
        public var settingsPath: String { WxSettings.defaultPath(configDirectory: configDirectory) }
        /// "<cache>/weather/forecasts.json" (WxForecastCache.defaultPath).
        public var cachePath: String { WxForecastCache.defaultPath(cacheDirectory: cacheDirectory) }
    }

    /// build_default_registry (wx-app.c:291-301): the registry of the production set, in this
    /// order: the National Weather Service, Open-Meteo and MET Norway (all enabled), with the
    /// Open-Meteo place search as its geocoder. A constructor or registration that fails would
    /// be a wrong constant (C: a critical, nothing registered); it is logged and skipped.
    public static func makeRegistry(log: AppModel.LogSink? = nil) -> WxRegistry {
        let log = log ?? AppModel.systemLog
        let registry = WxRegistry()
        add(registry, log) { () throws(WxError) in try NWSProvider() }
        add(registry, log) { () throws(WxError) in try OpenMeteoProvider() }
        add(registry, log) { () throws(WxError) in METNorwayProvider() }
        add(registry, log) { () throws(WxError) in try BrightSkyProvider() }
        add(registry, log) { () throws(WxError) in try ECCCProvider() }
        do {
            registry.geocoder = try OpenMeteoGeocoder()
        } catch {
            log(.warning, "Could not create the place search: \(error.message)")
        }
        return registry
    }

    /// add_provider (wx-app.c:265-272).
    private static func add(_ registry: WxRegistry, _ log: AppModel.LogSink,
                            _ make: () throws(WxError) -> any WxProvider) {
        do {
            try registry.addProvider(try make())
        } catch {
            log(.warning, "Could not register a data source: \(error.message)")
        }
    }

    /// wx_app_new + start-up: an AppModel over the production registry on `storageRoot`,
    /// loaded (the three files read, the settings applied, the items painted from the cache).
    /// No request is made: fetching starts once the window reports itself visible.
    /// - Parameters:
    ///   - storageRoot: the container directories.
    ///   - online: the network state now (the monitor's first report).
    public static func make(storageRoot: StorageRoot, online: Bool = true) async -> AppModel {
        let model = AppModel(registry: makeRegistry(), storage: storageRoot, clock: SystemClock(), online: online)
        await model.load()
        return model
    }

    /// `make(storageRoot:online:)` for the directories of `home` (StorageRoot(home:)).
    public static func make(storageRoot home: URL, online: Bool = true) async -> AppModel {
        await make(storageRoot: StorageRoot(home: home), online: online)
    }
}
