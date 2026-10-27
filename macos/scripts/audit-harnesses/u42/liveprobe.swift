// U42 live-path probe: drives the app code (compiled into the probe from a scratch copy of the
// sources with StationKeys replaced by an in-memory stub, scratch_build.sh) with every HTTP request
// answered in-process by a URLProtocol stub registered for URLSession.shared (no request leaves the
// machine). run_all.sh builds it from the tree's sources and, with --old DIR, also from the tree with
// DIR's Weather/Detail files; the printed lines differ only where a fix changed behaviour.
@testable import Neginato_Mezora
@testable import WeatherCore
import AppKit
import Foundation

// MARK: - Stub

nonisolated final class Stub: URLProtocol {
    struct Rec { let url: String; let ua: String?; let timeout: TimeInterval }
    static let lock = NSLock()
    nonisolated(unsafe) static var records: [Rec] = []
    nonisolated(unsafe) static var omDelayS: TimeInterval = 0
    nonisolated(unsafe) static var failAQ = false
    nonisolated(unsafe) static var failOM = false
    /// S14: every request but Open-Meteo /v1/forecast and cache.test fails (503 is never cached).
    nonisolated(unsafe) static var onlyOM = false
    nonisolated(unsafe) var stopped = false

    static func count(_ needle: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.url.contains(needle) }.count
    }
    static func last(_ needle: String) -> Rec? {
        lock.lock(); defer { lock.unlock() }
        return records.last { $0.url.contains(needle) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme?.hasPrefix("http") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Stub.lock.lock()
        Stub.records.append(Rec(url: url.absoluteString, ua: request.value(forHTTPHeaderField: "User-Agent"),
                                timeout: request.timeoutInterval))
        Stub.lock.unlock()
        let (status, body, delay) = Stub.route(url)
        let deliver = { [self] in
            Stub.lock.lock(); let gone = stopped; Stub.lock.unlock()
            guard !gone else { return }
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        Stub.lock.lock(); stopped = true; Stub.lock.unlock()
    }

    static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    static func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    static var nowS: Int64 { Int64(Date().timeIntervalSince1970) }

    /// The minutely_15 sums (each over the 15 minutes BEFORE its time, the vendor contract) and
    /// the current 15-minute sum, by the latitude the request was made for.
    static func omProfile(lat: String) -> (current: Double, sums: [Double]) {
        switch lat {
        case "48.1000": return (0.5, [0.5, 0.25, 0, 0, 0.1, 0, 0, 0.2, 0.3, 0, 0, 0])
        case "48.2000": return (0.0, [0, 0, 0.25, 0.25, 0, 0, 0, 0, 0, 0, 0, 0])
        case "48.6000": return (0.0, [0, 0.25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])  // S12: only the quarter in progress is wet
        default: return (0.0, [Double](repeating: 0, count: 12))
        }
    }

    static func route(_ url: URL) -> (Int, Data, TimeInterval) {
        let host = url.host ?? ""
        if onlyOM && !(host == "api.open-meteo.com" && url.path == "/v1/forecast") && host != "cache.test" {
            return (503, Data(), 0)
        }
        if host == "api.open-meteo.com" && url.path == "/v1/forecast" {
            if failOM { return (503, Data(), 0) }
            let n = Int(query(url, "forecast_minutely_15") ?? "0") ?? 0
            let q0 = nowS - nowS % 900
            let p = omProfile(lat: query(url, "latitude") ?? "")
            let body: [String: Any] = [
                "elevation": 40.0,
                "current": ["time": q0, "interval": 900, "temperature_2m": 12.0, "relative_humidity_2m": 80.0,
                            "apparent_temperature": 11.0, "precipitation": p.current, "rain": p.current,
                            "showers": 0.0, "snowfall": 0.0, "weather_code": p.current > 0 ? 61 : 1,
                            "cloud_cover": 20.0, "cloud_cover_low": 10.0, "cloud_cover_mid": 10.0,
                            "cloud_cover_high": 10.0, "wind_speed_10m": 10.0, "wind_gusts_10m": 20.0],
                "minutely_15": ["time": (0..<n).map { q0 + Int64($0) * 900 }, "precipitation": Array(p.sums.prefix(n))],
            ]
            return (200, json(body), omDelayS)
        }
        if host == "air-quality-api.open-meteo.com" {
            if failAQ { return (503, Data(), 0) }
            let h = nowS - nowS % 3600
            return (200, json(["current": ["time": h, "interval": 3600, "us_aqi": 30, "european_aqi": 29,
                                           "pm2_5": 5.7, "nitrogen_dioxide": 16.6],
                               "hourly": ["time": [h], "us_aqi": [30]]]), 0)
        }
        if host.hasSuffix("arcgis.com") {
            if failAQ { return (503, Data(), 0) }
            let g = (query(url, "geometry") ?? "0,0").split(separator: ",").compactMap { Double($0) }
            let h = nowS - nowS % 3600
            return (200, json(["features": [["attributes": ["AQSID": "m1", "SiteName": "Probe Monitor",
                                                            "DataSource": "Probe", "OZONEPM_AQI": 44,
                                                            "ValidTime": h * 1000],
                                             "geometry": ["x": g.first ?? 0, "y": (g.last ?? 0) + 0.09]]]]), 0)
        }
        if host == "api.brightsky.dev" && url.path == "/sources" {
            let lat = Double(query(url, "lat") ?? "0") ?? 0, lon = Double(query(url, "lon") ?? "0") ?? 0
            let f = ISO8601DateFormatter()
            let last = f.string(from: Date(timeIntervalSince1970: TimeInterval(nowS - 600)))
            var sources: [[String: Any]] = []
            for i in 0..<2 {
                var s: [String: Any] = ["id": 1000 + i, "observation_type": "synop", "lon": lon]
                let k = Double(i + 1)
                s["lat"] = lat + 0.02 * k
                s["last_record"] = last
                s["dwd_station_id"] = "0\(4000 + i)"
                s["wmo_station_id"] = "1\(4000 + i)"
                s["station_name"] = "Probe \(i)"
                s["height"] = 40.0
                s["distance"] = 2200.0 * k
                sources.append(s)
            }
            return (200, json(["sources": sources]), 0)
        }
        if host == "api.brightsky.dev" && url.path == "/current_weather" {
            return (503, Data(), 0)  // the per-station endpoint is down
        }
        // S9 (the verifier's): MeteoSwiss station list answers, every per-station CSV fails.
        if host == "data.geo.admin.ch" {
            if url.path.hasSuffix("ogd-smn_meta_stations.csv") {
                return (200, Data("station_abbr;station_name;station_coordinates_wgs84_lat;station_coordinates_wgs84_lon;station_height_masl\nBER;Bern;46.99;7.46;553\nTHU;Thun;46.75;7.62;570\n".utf8), 0)
            }
            return (503, Data(), 0)
        }
        if host == "cache.test" {
            return (200, Data("x".utf8), 0)
        }
        return (404, Data(), 0)
    }
}

// MARK: - Helpers

func wxPlace(_ name: String, _ cc: String, _ lat: Double, _ lon: Double, _ tz: String) -> WxPlace {
    try! WxPlace(name: name, admin1: "", country: cc, countryCode: cc, lat: lat, lon: lon, timezone: tz)
}

/// A forecast with no rain at all (its Rain card headline starts "No rain").
func dryForecast(_ place: WxPlace, nowS: Int64) -> WxForecast {
    let h0 = nowS - nowS % 3600
    let hours: [WxBlendHour] = (0..<72).map { i in
        WxBlendHour(tS: h0 + Int64(i) * 3600, tempC: 12, feelsC: 11, precipMm: 0, precipMmMax: 0, precipProb: 0,
                    cloudPct: 20, windKmh: 10, gustKmh: 20, humidityPct: 70, tempSpreadC: .nan,
                    nMembers: 1, condition: .mostlyClear, isDay: true)
    }
    let d0 = h0 - h0 % 86400
    let days: [WxDay] = (0..<3).map { d in
        WxDay(startS: d0 + Int64(d) * 86400, tempMaxC: 15, tempMinC: 8, precipMm: 0, precipProbMax: 0,
              cloudPct: 20, condition: .mostlyClear)
    }
    let src = try! WxSourceStatus(providerID: "open-meteo", name: "Open-Meteo", attribution: "a",
                                  attributionURL: "https://open-meteo.com/", state: .ok, errorCode: nil, nMembers: 1)
    return try! WxForecast(place: place, generatedS: nowS, hours: hours, quarters: [], days: days, sources: [src])
}

func item(_ p: WxPlace, key: String, units: WxUnits, fetchedS: Int64, forecast: WxForecast? = nil) -> AppModel.Place {
    AppModel.Place(place: p, key: key, forecast: forecast, modelForecast: nil, fetchedS: fetchedS, loading: false,
                   stale: false, offline: false, units: units, nowS: Stub.nowS, errorText: nil)
}

func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "nil" }

// MARK: - Scenarios

@MainActor func run() async {
    URLProtocol.registerClass(Stub.self)
    let store = LiveStationStore()
    let now = Stub.nowS
    let q0 = now - now % 900

    // S1 (U20-F1, U20-F12): the Open-Meteo current sum and the minutely_15 sums as the app reads them.
    do {
        let p = wxPlace("S1", "FR", 48.1, 2.35, "Europe/Paris")
        let snap = await LiveStationFetcher.fetch(place: item(p, key: "s1", units: .metric, fetchedS: 1), store: store)
        print("S1 F12 current.precipitation 0.5 mm per 900 s -> snapshot.precipMmH =", fmt(snap?.precipMmH),
              "(true rate 2.00 mm/h)")
        print("S1 F1 forecast_minutely_15 asked =", Stub.last("v1/forecast?latitude=48.1000").map {
            Stub.query(URL(string: $0.url)!, "forecast_minutely_15") ?? "?" } ?? "?")
        let qs = (snap?.radarQuarters ?? []).map { "\(($0.tS - q0) / 900):\(fmt($0.precipMm))" }
        print("S1 F1 radarQuarters (slot from now's quarter : precipMm) =", qs.joined(separator: " "))
        let chart = RainChartData(hours: [], quarters: snap?.radarQuarters ?? [], units: .metric, nowS: now,
                                  view: .nowcast, zone: .utc)
        print("S1 F1 nowcast bars mm/h (8 slots) =", chart.rateMmH.map { $0.isNaN ? "NaN" : fmt($0) }.joined(separator: " "),
              "| truth: slot k = 4 x sum labelled q0+(k+1)*900 = 1.00 0.00 0.00 0.40 0.00 0.00 0.80 1.20")
        let rec = Stub.last("v1/forecast?latitude=48.1000")
        print("S2 F2 Open-Meteo request User-Agent =", rec?.ua ?? "nil (CFNetwork default added later)",
              "| timeoutInterval =", rec?.timeout ?? -1)
    }

    // S1b (U20-F1): the "Rain starting in N minutes" headline on a dry page.
    do {
        let p = wxPlace("S1b", "FR", 48.2, 2.35, "Europe/Paris")
        let place = item(p, key: "s1b", units: .metric, fetchedS: 1, forecast: dryForecast(p, nowS: now))
        let snap = await LiveStationFetcher.fetch(place: place, store: store)
        let detail = DetailViewModel()
        detail.show(DetailViewModel.Item(place: p, forecast: place.forecast, fetchedS: 1, loading: false, stale: false,
                                         offline: false, units: .metric, nowS: now, errorText: nil))
        if case .forecast(let page) = detail.page, let snap {
            let applied = snap.apply(to: page, place: place)
            let onset = q0 + 900  // the sum labelled q0+1800 covers [q0+900, q0+1800)
            print("S1b F1 page headline =", page.rain.headline, "| live headline =", applied.rain.headline,
                  "| true onset in", max(1, (onset - now + 59) / 60), "min")
        } else {
            print("S1b F1 no forecast page / snapshot")
        }
    }

    // S2 (U20-F2 + the verifier's missed cancellation path): the owner of the flight is cancelled
    // while Open-Meteo is still answering (1.5 s); CAMS answers at once.
    do {
        Stub.omDelayS = 1.5
        let p = wxPlace("S2", "FR", 48.3, 2.35, "Europe/Paris")
        let place = item(p, key: "s2", units: .metric, fetchedS: 1)
        let t = Task { await store.refreshIfNeeded(for: place) }
        try? await Task.sleep(for: .milliseconds(300))
        t.cancel()
        await t.value
        try? await Task.sleep(for: .milliseconds(1800))
        Stub.omDelayS = 0
        let s = store.snapshot(for: place)
        print("S2 F2 cancelled owner -> stored snapshot:", s == nil ? "none" : "yes",
              "| radarQuarters =", s?.radarQuarters.count ?? -1, "| precipMmH =", fmt(s?.precipMmH),
              "| AQ card =", s?.airQuality != nil)
        let before = Stub.count("v1/forecast?latitude=48.3000")
        await store.refreshIfNeeded(for: place)
        print("S2 F2 same place again -> refetched:", Stub.count("v1/forecast?latitude=48.3000") > before,
              "(the stored snapshot is marked fresh)")
    }

    // S3 (U20-F3): an AirNow card fetched in metric, then a units change while both AQ sources fail.
    do {
        let p1 = wxPlace("S3", "US", 40.70, -74.0, "America/New_York")
        await store.refreshIfNeeded(for: item(p1, key: "s3", units: .metric, fetchedS: 1))
        print("S3 F3 round 1 (metric) AQ source =", store.snapshots["s3"]?.airQuality?.source ?? "nil")
        Stub.failAQ = true
        let p2 = wxPlace("S3", "US", 40.75, -74.0, "America/New_York")  // new URLs: no cache hit
        let place2 = item(p2, key: "s3", units: .imperial, fetchedS: 2)
        await store.refreshIfNeeded(for: place2)
        Stub.failAQ = false
        print("S3 F3 round 2 (imperial, AQ down) AQ source =", store.snapshots["s3"]?.airQuality?.source ?? "nil")
    }

    // S4 (U20-F5): units change while the place's fetch is in flight.
    do {
        Stub.omDelayS = 1.0
        let p = wxPlace("S4", "US", 40.80, -74.0, "America/New_York")
        async let first: Void = store.refreshIfNeeded(for: item(p, key: "s4", units: .metric, fetchedS: 1))
        try? await Task.sleep(for: .milliseconds(200))
        await store.refreshIfNeeded(for: item(p, key: "s4", units: .imperial, fetchedS: 1))
        await first
        Stub.omDelayS = 0
        try? await Task.sleep(for: .milliseconds(2500))
        print("S4 F5 after the flight (units now imperial) AQ source =",
              store.snapshots["s4"]?.airQuality?.source ?? "nil")
    }

    // S5 (U20-F8): a later refresh in which every live source fails.
    do {
        let p1 = wxPlace("S5", "FR", 48.40, 2.35, "Europe/Paris")
        let place1 = item(p1, key: "s5", units: .metric, fetchedS: 1)
        await store.refreshIfNeeded(for: place1)
        print("S5 F8 round 1 snapshot present:", store.snapshot(for: place1) != nil)
        Stub.failOM = true; Stub.failAQ = true
        let place2 = item(wxPlace("S5", "FR", 48.45, 2.35, "Europe/Paris"), key: "s5", units: .metric, fetchedS: 2)
        await store.refreshIfNeeded(for: place2)
        Stub.failOM = false; Stub.failAQ = false
        print("S5 F8 round 2 (all live sources down) snapshot still shown:", store.snapshot(for: place2) != nil)
    }

    // S6 (U20-F7): Forget All Stations, then the app quits before the 60 s debounced save.
    do {
        let dir = NSTemporaryDirectory() + "u42-f7-\(getpid())"
        try? FileManager.default.removeItem(atPath: dir)
        let model = AppModel(registry: WxRegistry(),
                             storage: AppEnvironment.StorageRoot(configDirectory: dir + "/config",
                                                                 cacheDirectory: dir + "/cache"),
                             online: false, log: { _, _ in })
        let quitStore = LiveStationStore()
        await quitStore.attach(model)
        let path = WxStationCatalog.defaultPath(configDirectory: model.storage.configDirectory)
        quitStore.forgetAllStations()
        let before = FileManager.default.fileExists(atPath: path)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        print("S6 F7 catalog file written: before quit =", before, "| right after willTerminate =",
              FileManager.default.fileExists(atPath: path))
    }

    // S7 (U21-F1): Bright Sky's station list answers, every per-station current_weather fails.
    do {
        let p = wxPlace("Berlin", "DE", 52.52, 13.40, "Europe/Berlin")
        let earlier = Stub.count("current_weather?source_id=")
        let obs = await StationNetworkFetcher.gather(lat: p.lat, lon: p.lon, region: WxGeo.region(for: p), wfo: nil,
                                                     placeName: "Berlin", store: store)
        print("S7 U21-F1 per-station requests:", Stub.count("current_weather?source_id=") - earlier,
              "| dwdSYNOP status =", store.networkStatus[.dwdSYNOP].map { "\($0.outcome)" } ?? "nil",
              "| observations =", obs.count)
    }

    // S8 (U21-F2): the StationHTTP cache filled with 400 unexpired entries, then one more.
    do {
        let http = StationHTTP()
        for i in 0..<50 { _ = await http.fetch("https://cache.test/day/\(i)", ttlS: 86_400) }
        for i in 0..<350 { _ = await http.fetch("https://cache.test/short/\(i)", ttlS: 600) }
        _ = await http.fetch("https://cache.test/new", ttlS: 600)
        _ = await http.fetch("https://cache.test/day/0", ttlS: 86_400)
        _ = await http.fetch("https://cache.test/new", ttlS: 600)
        print("S8 U21-F2 GETs of day-long day/0 =", Stub.count("cache.test/day/0"),
              "| of the new entry =", Stub.count("cache.test/new"), "(1 each: served from the cache)")
    }

    // S9-S13 are the U42 iteration-1 verifier's scenarios (its liveprobe.swift),
    // adopted unchanged; S14 is new in iteration 2.

    // S9 (U21-F1, MeteoSwiss site): the station list answers, every per-station request fails.
    do {
        let ms = await StationNetworkFetcher.meteoSwiss(lat: 46.95, lon: 7.44)
        print("S9 U21-F1 meteoSwiss per-station requests:", Stub.count("_t_now.csv"),
              "| observations =", ms.observations.map { "\($0.count)" } ?? "nil")
    }

    // S10 (U21-F1, nwsUpgrades site): one K airport from METAR, its NWS latest observation fails (404).
    do {
        let metar = WxStationObservation(network: .metar, id: "KJFK", lat: 40.64, lon: -73.78, tempC: 10)
        let up = await StationNetworkFetcher.nwsUpgrades([metar], lat: 40.70, lon: -74.0)
        print("S10 U21-F1 nwsUpgrades per-airport requests:", Stub.count("api.weather.gov/stations/KJFK"),
              "| observations =", up.observations.map { "\($0.count)" } ?? "nil")
    }

    // S11 (U20-F2, the cache): two live fetches of one place, back to back.
    do {
        let p = wxPlace("S11", "FR", 48.5, 2.35, "Europe/Paris")
        _ = await LiveStationFetcher.fetch(place: item(p, key: "s11", units: .metric, fetchedS: 1), store: store)
        _ = await LiveStationFetcher.fetch(place: item(p, key: "s11", units: .metric, fetchedS: 2), store: store)
        print("S11 U20-F2 Open-Meteo GETs for two live fetches of one place =", Stub.count("v1/forecast?latitude=48.5000"))
    }

    // S13 (U20-F5 under cancellation): the owner of the metric flight (a .task(id:) keyed on units)
    // is cancelled when the units change; the imperial refresh asked meanwhile must still land.
    do {
        Stub.omDelayS = 1.0
        let p = wxPlace("S13", "US", 40.85, -74.0, "America/New_York")
        let owner = Task { await store.refreshIfNeeded(for: item(p, key: "s13", units: .metric, fetchedS: 1)) }
        try? await Task.sleep(for: .milliseconds(200))
        await store.refreshIfNeeded(for: item(p, key: "s13", units: .imperial, fetchedS: 1))
        owner.cancel()
        await owner.value
        Stub.omDelayS = 0
        try? await Task.sleep(for: .milliseconds(2500))
        let s = store.snapshots["s13"]
        print("S13 F5-cancelled owner: AQ source =", s?.airQuality?.source ?? "nil",
              "| radarQuarters =", s?.radarQuarters.count ?? -1, "| precipMmH =", fmt(s?.precipMmH))
    }

    // S12 (U20-F1 edge): only the quarter in progress [q0, q0+900) is wet (the sum labelled q0+900).
    do {
        let p = wxPlace("S12", "FR", 48.6, 2.35, "Europe/Paris")
        let place = item(p, key: "s12", units: .metric, fetchedS: 1, forecast: dryForecast(p, nowS: now))
        let snap = await LiveStationFetcher.fetch(place: place, store: store)
        let detail = DetailViewModel()
        detail.show(DetailViewModel.Item(place: p, forecast: place.forecast, fetchedS: 1, loading: false, stale: false,
                                         offline: false, units: .metric, nowS: now, errorText: nil))
        if case .forecast(let page) = detail.page, let snap {
            let applied = snap.apply(to: page, place: place)
            print("S12 F1-edge live headline =", applied.rain.headline,
                  "| nowcast slot 0 mm/h =", applied.rain.nowcast.rateMmH.first.map { fmt($0) } ?? "none")
        } else {
            print("S12 F1-edge no forecast page / snapshot")
        }
    }

    // S14 (U20-F2 TTL vs the refresh cadence): two periodic rounds are at least
    // RefreshScheduler.periodicFreshUS (540 s) apart. StationHTTP.shared is filled with 400 entries
    // that expire 540 s from now; then the place's Open-Meteo answer is cached (only it: every
    // other request fails, and failures are not cached); one more 540 s entry evicts the entry
    // closest to expiry. The Open-Meteo answer is that entry, and the next fetch downloads it
    // again, exactly when its TTL is below 540 s, i.e. when a periodic round can never reuse it.
    do {
        Stub.onlyOM = true
        let spacingS = TimeInterval(RefreshScheduler.periodicFreshUS / 1_000_000)
        for i in 0..<400 { _ = await StationHTTP.shared.fetch("https://cache.test/s14/\(i)", ttlS: spacingS) }
        let p = wxPlace("S14", "FR", 48.7, 2.35, "Europe/Paris")
        _ = await LiveStationFetcher.fetch(place: item(p, key: "s14", units: .metric, fetchedS: 1), store: store)
        _ = await StationHTTP.shared.fetch("https://cache.test/s14/next", ttlS: spacingS)
        _ = await LiveStationFetcher.fetch(place: item(p, key: "s14", units: .metric, fetchedS: 2), store: store)
        Stub.onlyOM = false
        let gets = Stub.count("v1/forecast?latitude=48.7000")
        print("S14 U20-F2 Open-Meteo answer expires before a \(Int(spacingS)) s entry (TTL < periodic spacing):",
              gets == 2, "| GETs =", gets)
    }
}

await run()
