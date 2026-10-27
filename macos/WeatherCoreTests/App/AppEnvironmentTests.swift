// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AppEnvironmentTests.swift - the composition cases of src/ui/test-window.c
// (/window/app/default-wiring, /window/app/custom-registry-as-is) and the U27
// composition criteria: the production registry in C order, https origins on
// the four provider hosts only, the stored files loaded, no request made.

import Foundation
import Testing
@testable import WeatherCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AppEnvironmentTests {
    /// The hosts the app may contact (wx-nws.c, wx-openmeteo.c, wx-metno.c, BrightSky, ECCC GeoMet).
    private static let allowedHosts: Set<String> = [
        "api.open-meteo.com", "geocoding-api.open-meteo.com", "api.weather.gov", "api.met.no",
        "api.brightsky.dev", "api.weather.gc.ca",
    ]

    /// The origin of a production provider's HTTP client (the fixed constant it was built from).
    private static func origin(of provider: any WxProvider) -> String? {
        if let p = provider as? NWSProvider {
            return p.http.policy.origin
        }
        if let p = provider as? OpenMeteoProvider {
            return p.http.policy.origin
        }
        if let p = provider as? METNorwayProvider {
            return p.http.policy.origin
        }
        if let p = provider as? BrightSkyProvider {
            return p.http.policy.origin
        }
        if let p = provider as? ECCCProvider {
            return p.http.policy.origin
        }
        return nil
    }

    private static func isAllowedHTTPSOrigin(_ origin: String?) -> Bool {
        guard let origin, let url = URL(string: origin), url.scheme == "https", let host = url.host,
              url.port == nil, url.path.isEmpty || url.path == "/"
        else {
            return false
        }
        return allowedHosts.contains(host)
    }

    private static func outstanding(_ registry: WxRegistry) -> Int {
        var n = 0
        for p in registry.listProviders() {
            if let p = p as? NWSProvider {
                n += p.http.outstandingCount
            } else if let p = p as? OpenMeteoProvider {
                n += p.http.outstandingCount
            } else if let p = p as? METNorwayProvider {
                n += p.http.outstandingCount
            } else if let p = p as? BrightSkyProvider {
                n += p.http.outstandingCount
            } else if let p = p as? ECCCProvider {
                n += p.http.outstandingCount
            }
        }
        if let g = registry.geocoder as? OpenMeteoGeocoder {
            n += g.http.outstandingCount
        }
        return n
    }

    // C: /window/app/default-wiring (test_app_default_wiring, test-window.c:1144-1165), the registry
    // part; build_default_registry, wx-app.c:291-301.
    @Test func defaultWiringRegistersTheProductionSetInCOrder() throws {
        let registry = AppEnvironment.makeRegistry()
        let providers = registry.listProviders()
        #expect(providers.count == 5)
        #expect(providers.map(\.id) == ["nws", "open-meteo", "met-no", "dwd-brightsky", "eccc"])
        for p in providers {
            #expect(registry.isEnabled(id: p.id))  // test-window.c:1156-1157
        }
        #expect(providers[0] is NWSProvider)
        #expect(providers[1] is OpenMeteoProvider)
        #expect(providers[2] is METNorwayProvider)
        #expect(providers[3] is BrightSkyProvider)
        #expect(providers[4] is ECCCProvider)
        let geocoder = try #require(registry.geocoder)  // test-window.c:1158
        #expect(geocoder is OpenMeteoGeocoder)
        // Every production origin is https on one of the allowed hosts.
        let origins = providers.map { Self.origin(of: $0) }
        #expect(origins == [
            "https://api.weather.gov",
            "https://api.open-meteo.com",
            "https://api.met.no",
            "https://api.brightsky.dev",
            "https://api.weather.gc.ca",
        ])
        for o in origins {
            #expect(Self.isAllowedHTTPSOrigin(o), "\(o ?? "nil")")
        }
        let geocoderOrigin = (geocoder as? OpenMeteoGeocoder)?.http.policy.origin
        #expect(geocoderOrigin == "https://geocoding-api.open-meteo.com")
        #expect(Self.isAllowedHTTPSOrigin(geocoderOrigin))
        #expect(Self.outstanding(registry) == 0)
    }

    // C: /window/app/default-wiring (test-window.c:1144-1165), the application part: a new model
    // has its service and empty state (nothing read, no request), before and after an empty load.
    @Test func defaultWiringOfANewModel() async throws {
        let dir = try TemporaryDirectory("environment-new")
        let storage = AppEnvironment.StorageRoot(home: dir.url)
        let m = await AppEnvironment.make(storageRoot: storage)
        #expect(AppModel.appID == "io.github.wtp128pro.Weather")  // WX_APP_ID, test-window.c:1148
        #expect(m.registry.listProviders().map(\.id) == ["nws", "open-meteo", "met-no", "dwd-brightsky", "eccc"])
        #expect(m.registry.geocoder != nil)
        #expect(m.places.isEmpty)  // test-window.c:1160
        #expect(!m.isOffline)  // test-window.c:1161
        #expect(m.units == .imperial)  // test-window.c:1162
        #expect(m.selectedKey == nil)  // test-window.c:1163
        #expect(m.isLoaded)
        #expect(m.requestsStarted == 0)
        #expect(Self.outstanding(m.registry) == 0)
        #expect(await m.flush())
        // An empty first run writes nothing.
        #expect(!FileManager.default.fileExists(atPath: storage.placesPath))
        #expect(!FileManager.default.fileExists(atPath: storage.cachePath))
    }

    // C: /window/app/custom-registry-as-is (test_app_custom_registry_is_used_as_is,
    // test-window.c:1168-1176)
    @Test func customRegistryIsUsedAsIs() async throws {
        let dir = try TemporaryDirectory("environment-custom")
        let registry = WxRegistry()
        let m = AppModel(registry: registry, storage: AppEnvironment.StorageRoot(home: dir.url))
        #expect(m.registry === registry)  // test-window.c:1172
        #expect(registry.listProviders().isEmpty)  // nothing was added behind the caller's back, test-window.c:1174
        #expect(registry.geocoder == nil)  // test-window.c:1175
        await m.load()
        #expect(registry.listProviders().isEmpty)
        #expect(registry.geocoder == nil)
        #expect(await m.flush())
    }

    // U27 COMPOSITION: make(storageRoot:) loads the stored files (places, settings with units,
    // a disabled provider and the selection, the forecast cache), applies them to the production
    // registry and makes no network request.
    // C: none - contract test of wx-app.h:34-45 and the U27 COMPOSITION criterion (nearest: /window/refresh/cached-at-once)
    @Test func makeLoadsTheStoredFilesAndMakesNoRequest() async throws {
        let dir = try TemporaryDirectory("environment-load")
        let storage = AppEnvironment.StorageRoot(home: dir.url)
        let miami = try WxPlace(name: "Miami", admin1: "Florida", country: "United States", countryCode: "US",
                                lat: 25.7743, lon: -80.1937, timezone: "America/New_York")  // test-window.c:176
        let orlando = try WxPlace(name: "Orlando", admin1: "Florida", country: "United States", countryCode: "US",
                                  lat: 28.5383, lon: -81.3792, timezone: "America/New_York")  // test-window.c:182
        let places = try #require(WxPlaces(path: storage.placesPath))
        #expect(places.add(miami) && places.add(orlando))
        try places.save()
        let settings = try #require(WxSettings(path: storage.settingsPath))
        #expect(settings.setUnits(.metric))
        #expect(settings.setProviderDisabled("open-meteo", true))
        #expect(settings.setSelected(orlando.key))
        try settings.save()
        let cache = try #require(WxForecastCache(path: storage.cachePath))
        let now = SystemClock().wallSeconds
        let forecast = try WxForecast(place: miami, generatedS: now)
        #expect(cache.put(forecast, fetchedAtMs: (now - 3 * 3600) * 1000))  // prime_cache(fx, 3 * 3600), test-window.c:1507
        try cache.save()

        let m = await AppEnvironment.make(storageRoot: dir.url, online: true)
        #expect(m.storage == storage)
        #expect(m.isLoaded)
        #expect(m.places.map(\.place.name) == ["Miami", "Orlando"])
        #expect(m.units == .metric)
        #expect(!m.registry.isEnabled(id: "open-meteo"))
        #expect(m.registry.isEnabled(id: "nws") && m.registry.isEnabled(id: "met-no"))
        #expect(m.sources.map(\.enabled) == [true, false, true, true, true])
        #expect(m.selectedKey == orlando.key)
        let item = try #require(m.place(forKey: miami.key))
        #expect(item.forecast?.generatedS == now)
        let age = SystemClock().wallSeconds - item.fetchedS
        #expect(age >= 3 * 3600 && age <= 3 * 3600 + 5)
        #expect(m.place(forKey: orlando.key)?.forecast == nil)
        // No request: the window has not reported itself visible.
        #expect(m.requestsStarted == 0)
        #expect(m.requestsInFlight == 0)
        #expect(Self.outstanding(m.registry) == 0)
        #expect(m.places.allSatisfy { !$0.loading })
        #expect(await m.flush())
        #expect(m.requestsStarted == 0)
    }

    // U51 AC4: the production model from make() holds the AlertsService that makeAlerts built
    // (not the inert default, not a stand-in), fetching through that call's WxAlertsFetchers,
    // whose five clients are pinned each to its own issuer's https origin; the model's service
    // alone keeps those fetchers alive (its fetch closure). Nothing is fetched: the window never
    // reports itself visible and no refresh runs.
    // C: none - contract test of the U51 production wiring (executor-added)
    @Test func productionModelHasRealAlertsService() async throws {
        let dir = try TemporaryDirectory("environment-alerts")
        let origins: [WxAlert.Source: String] = [
            .nws: "https://api.weather.gov", .dwd: "https://api.brightsky.dev", .metNorway: "https://api.met.no",
            .eccc: "https://api.weather.gc.ca", .meteoAlarm: "https://feeds.meteoalarm.org",
        ]
        #expect(Set(WxAlert.Source.allCases) == Set(origins.keys))
        weak var weakFetchers: WxAlertsFetchers?
        weak var weakModel: AppModel?
        do {
            let m = await AppEnvironment.make(storageRoot: AppEnvironment.StorageRoot(home: dir.url), online: false)
            weakModel = m
            #expect(!(m.alertsService is InertAlertsService))
            let service = try #require(m.alertsService as? AlertsService)
            let built = try #require(AppEnvironment.builtAlerts.first { $0.service === service },
                                     "the model's alerts service is not the one makeAlerts built")
            let fetchers = try #require(built.fetchers)
            weakFetchers = fetchers
            for source in WxAlert.Source.allCases {
                #expect(fetchers.client(for: source).policy.origin == origins[source], "\(source)")
            }
            #expect(m.requestsStarted == 0)
            #expect(await m.flush())
        }
        for _ in 0 ..< 1_000 where weakModel != nil {
            await Task.yield()
        }
        #expect(weakModel == nil)
        #expect(weakFetchers == nil)  // the production model's service held them
    }

    // DECISIONS #11 storage roots; wx-places.c:219, wx-settings.c:248, wx-cache.c:172: the C file
    // names under "<dir>/weather/", Application Support and Caches inside the container home.
    // C: none - contract test of DECISIONS #11 and wx-places.c:219, wx-settings.c:248, wx-cache.c:172 (executor-added)
    @Test func storageRootLayout() {
        let root = AppEnvironment.StorageRoot(home: URL(fileURLWithPath: "/c/Data", isDirectory: true))
        #expect(root.configDirectory == "/c/Data/Library/Application Support")
        #expect(root.cacheDirectory == "/c/Data/Library/Caches")
        #expect(root.placesPath == "/c/Data/Library/Application Support/weather/places.json")
        #expect(root.settingsPath == "/c/Data/Library/Application Support/weather/settings.json")
        #expect(root.cachePath == "/c/Data/Library/Caches/weather/forecasts.json")
        let explicit = AppEnvironment.StorageRoot(configDirectory: "/cfg", cacheDirectory: "/cache")
        #expect(explicit.placesPath == "/cfg/weather/places.json")
        #expect(explicit.cachePath == "/cache/weather/forecasts.json")
    }
}
