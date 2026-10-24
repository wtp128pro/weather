// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ForecastTests.swift - port of the Status/forecast cases of
// src/core/test-core.c (registered at src/core/test-core.c:3522-3541) plus
// the enum-ordinal lines of error-domain and the status/forecast lines of
// id-validation, time-range-edges, error-messages-no-echo and
// place-timezone-shapes. Expected values are the C test literals, cited as
// path:line. C string literals with escapes are written as byte arrays (the
// bytes the C compiler produced), never as Swift escapes.

import Testing
@testable import WeatherCore

@Suite struct ForecastTests {
    /// T0 (src/core/test-core.c:18).
    static let t0: Int64 = 1_791_676_800
    /// GOOD_URL (src/core/test-core.c:21).
    static let goodURL = "https://example.org/"

    private static func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// make_miami (src/core/test-core.c:38-48).
    static func makeMiami() throws -> WxPlace {
        try WxPlace(
            name: "Miami", admin1: "Florida", country: "United States", countryCode: "US",
            lat: 25.7617, lon: -80.1918, timezone: "America/New_York")
    }

    /// good_blend_hour (src/core/test-core.c:90-110).
    static func goodBlendHour(_ t: Int64) -> WxBlendHour {
        WxBlendHour(
            tS: t, tempC: 28.0, feelsC: 31.0, precipMm: 0.2, precipMmMax: 1.0, precipProb: 30.0,
            cloudPct: 55.0, windKmh: 14.0, gustKmh: 30.0, humidityPct: 75.0, tempSpreadC: 1.5,
            nMembers: 4, condition: .partlyCloudy, isDay: true)
    }

    /// good_day (src/core/test-core.c:112-125).
    static func goodDay(_ start: Int64) -> WxDay {
        WxDay(
            startS: start, tempMaxC: 31.0, tempMinC: 23.0, precipMm: 3.0, precipProbMax: 70.0,
            cloudPct: 50.0, condition: .showers)
    }

    /// wx_source_status_new("x", "n", "a", url, WX_SRC_OK, -1, 0)
    /// (src/core/test-core.c:3238-3249).
    static func status(url: [UInt8]?) throws(WxError) -> WxSourceStatus {
        try WxSourceStatus(
            providerIDBytes: b("x"), nameBytes: b("n"), attributionBytes: b("a"),
            attributionURLBytes: url, stateOrdinal: WxSourceState.ok.rawValue,
            errorCodeOrdinal: -1, nMembers: 0)
    }

    /// make_forecast_sized (src/core/test-core.c:1003-1047).
    static func makeForecastSized(_ nHours: Int, _ nQuarters: Int, _ nDays: Int, _ nSources: Int) throws -> WxForecast {
        let hours = (0..<nHours).map { goodBlendHour(t0 + Int64($0) * 3600) }
        let quarters = (0..<nQuarters).map { WxQuarter(tS: t0 + Int64($0) * 900, precipMm: 0.1) }
        let days = (0..<nDays).map { goodDay(t0 + Int64($0) * 86400) }
        let sources = try (0..<nSources).map { i throws(WxError) in
            try WxSourceStatus(
                providerID: "src-\(i)", name: "Name", attribution: "Attribution",
                attributionURL: "https://example.org/", state: .ok, errorCode: nil,
                nMembers: UInt32(i))
        }
        return try WxForecast(
            place: try makeMiami(), generatedS: t0 + 100, hours: hours, quarters: quarters,
            days: days, sources: sources)
    }

    /// assert_forecast_rejected (src/core/test-core.c:1188-1197).
    static func expectRejected(
        _ body: () throws -> Void, _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            try body()
            Issue.record("accepted: \(what)", sourceLocation: sourceLocation)
        } catch {
            #expect((error as? WxError)?.code == .invalidArg, "\(what)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - TYPES: C ordinals

    // C: /core/types/error-domain, enum lines (src/core/test-core.c:152-155)
    // and the ordinals of src/core/wx-types.h:629-646,669-673,774-779,793-796.
    @Test("/core/types/error-domain (enum ordinals)") func enumOrdinals() {
        #expect(WxCondition.count == 15)  // src/core/test-core.c:152
        #expect(WxCondition.allCases.count == 15)
        #expect(WxCondition.allCases.map(\.rawValue) == Array(0...14))
        let conditionOrder: [WxCondition] = [
            .unknown, .clear, .mostlyClear, .partlyCloudy, .mostlyCloudy, .overcast, .fog,
            .drizzle, .lightRain, .rain, .heavyRain, .showers, .thunderstorm, .snow, .sleet,
        ]
        #expect(conditionOrder.map(\.rawValue) == Array(0...14))  // wx-types.h:629-646
        #expect(WxCondition(rawValue: 15) == nil)
        #expect(WxCondition(rawValue: -1) == nil)
        #expect(WxSourceState.skipped.rawValue == 2)  // src/core/test-core.c:153
        #expect(WxSourceState.ok.rawValue == 0)  // wx-types.h:670
        #expect(WxSourceState.failed.rawValue == 1)  // wx-types.h:671
        #expect(WxSourceState(rawValue: 3) == nil)
        #expect(WxUnits.metric.rawValue != WxUnits.imperial.rawValue)  // src/core/test-core.c:154
        #expect(WxUnits.imperial.rawValue == 0)  // wx-types.h:794
        #expect(WxUnits.metric.rawValue == 1)  // wx-types.h:795
        #expect(WxRainState.possible.rawValue == 3)  // src/core/test-core.c:155
        #expect([WxRainState.dry, .now, .expected, .possible].map(\.rawValue) == [0, 1, 2, 3])  // wx-types.h:774-779
        // persisted ordinals round-trip (the cache stores rawValue)
        for c in WxCondition.allCases { #expect(WxCondition(rawValue: c.rawValue) == c) }
        for s in WxSourceState.allCases { #expect(WxSourceState(rawValue: s.rawValue) == s) }
        for r in WxRainState.allCases { #expect(WxRainState(rawValue: r.rawValue) == r) }
        for u in WxUnits.allCases { #expect(WxUnits(rawValue: u.rawValue) == u) }
    }

    // MARK: - Source status

    // C: /core/types/source-status (src/core/test-core.c:935-1001)
    @Test("/core/types/source-status") func sourceStatus() throws {
        let s = try WxSourceStatus(
            providerID: "nws", name: "National Weather Service",
            attribution: "Source: NOAA/National Weather Service",
            attributionURL: "https://www.weather.gov/", state: .ok, errorCode: nil, nMembers: 3)
        #expect(s.providerID == "nws")
        #expect(s.name == "National Weather Service")
        #expect(s.attributionURL == "https://www.weather.gov/")
        #expect(s.state == .ok)
        #expect(s.errorCodeOrdinal == -1)
        #expect(s.errorCode == nil)
        #expect(s.nMembers == 3)

        let c = try s.copy()
        #expect(c.attribution == s.attribution)
        #expect(c.nMembers == 3)
        #expect(c.name == "National Weather Service")

        // NULL texts become "", hostile text is sanitised, long text truncated (:964-980)
        let t = try WxSourceStatus(
            providerIDBytes: Self.b("x"), nameBytes: nil,
            attributionBytes: [0x41, 0x0A, 0x42, 0xE2, 0x80, 0xAE, 0x43, 0xFF],
            attributionURLBytes: nil, stateOrdinal: WxSourceState.failed.rawValue,
            errorCodeOrdinal: WxError.Code.timeout.rawValue, nMembers: 0)
        #expect(t.name == "")
        #expect(Array(t.attribution.utf8) == [0x41, 0x42, 0x43, 0xEF, 0xBF, 0xBD])
        #expect(t.attributionURL == "")
        #expect(t.errorCode == .timeout)
        #expect(t.errorCodeOrdinal == 1)
        let longName = String(repeating: "n", count: 1000)
        let lng = try WxSourceStatus(
            providerID: "x", name: longName, attribution: longName, attributionURL: "",
            state: .ok, errorCode: nil, nMembers: 0)
        #expect(lng.name.utf8.count == WxLimits.sourceTextMax)
        #expect(lng.attribution.utf8.count == WxLimits.sourceTextMax)
        #expect(lng.attributionURL == "")

        _ = try WxSourceStatus(
            providerID: "x", name: "n", attribution: "a", attributionURL: Self.goodURL,
            state: .skipped, errorCode: .unsupported, nMembers: 0)

        // rejects (:986-995), through the C-ordinal initialiser the cache uses
        let rejects: [(id: [UInt8]?, state: Int, error: Int)] = [
            (Self.b("Bad Id"), 0, -1), (nil, 0, -1), (Self.b("x"), 3, -1), (Self.b("x"), -1, -1),
            (Self.b("x"), 0, -2), (Self.b("x"), 0, WxError.Code.unsupported.rawValue + 1),
        ]
        for r in rejects {
            Self.expectRejected({ () throws in
                _ = try WxSourceStatus(
                    providerIDBytes: r.id, nameBytes: Self.b("n"), attributionBytes: Self.b("a"),
                    attributionURLBytes: Self.b(Self.goodURL), stateOrdinal: r.state,
                    errorCodeOrdinal: r.error, nMembers: 0)
            }, "status \(r)")
        }
        // A hand-built invalid status (:996-998) and the NULL critical cannot
        // exist in Swift: every WxSourceStatus is validated at construction.
    }

    // C: /core/types/source-status-url (src/core/test-core.c:3251-3387)
    @Test("/core/types/source-status-url") func sourceStatusURL() throws {
        let good = [  // src/core/test-core.c:3254-3267
            "https://open-meteo.com/", "https://www.weather.gov/", "https://api.met.no/",
            "https://example.org/a?b=c&d=e#f", "https://example.org:8443/x", "https://[::1]/",
            "https://a", "https://example.org/%20x", "https://example.org/a_b-c.d~e",
            "https://example.org/a@b", "https://example.org?q=a@b", "https://example.org#a@b",
            "https://xn--bcher-kva.example/", "https://example.org/(x)*!$'+,;=",
            "https://api.met.no/weatherapi/", "https://example.org:8443/x?y=1#z", "https://1.2.3.4/",
            "https://255.255.255.255:65535/", "https://0.0.0.0/", "https://[2001:db8::1]:8443/x",
            "https://[::ffff:1.2.3.4]/", "https://[::1]:1/", "https://[::]/",
            "https://[1:2:3:4:5:6:7:8]/", "https://a:1/", "https://a:65535/", "https://A.B-c.D9/",
            "https://a-b.c-d.example/", "https://example.org/%C3%A9", "https://a/?q=%20&r=%7e",
            "https://example.org/a/b/c?d#e/f?g", "https://example.org/a:b@c", "https://a.b.c.d.e/",
            "https://a1.example/", "https://1a.example/", "https://example.org?", "https://example.org#",
            "https://example.org/?#", "https://1.2.3.4a/",
        ]
        for url in good {
            let s = try Self.status(url: Self.b(url))
            #expect(s.attributionURL == url)
        }
        #expect(try Self.status(url: nil).attributionURL == "")  // :3274-3275
        #expect(try Self.status(url: []).attributionURL == "")  // :3276-3277

        let e = Self.b("https://example.org/")
        let plainBad = [  // src/core/test-core.c:3279-3326, the entries without C escapes
            "http://example.org/", "HTTPS://example.org/", "Https://example.org/", "https:/example.org/",
            "https:example.org", "https://", "https:///x", "https://?x", "https://#x",
            "file:///etc/passwd", "javascript:alert(1)", "ftp://example.org/", "data:text/html,x",
            "//example.org/", "example.org", "mailto:a@b", " https://example.org/",
            "https://example.org/ x", "https://example.org/<x>",
            "https://example.org/`x`", "https://example.org/{x}",
            "https://example.org/|x", "https://example.org/^x",
            "https://good.example@evil.example/", "https://user:pw@example.org/", "https://@example.org/",
            "https://good.example@evil.example", "https://good.example@", "https://a@b?x",
            "https://:443/", "https://:/", "https://a:b/", "https://a.b:99999999/", "https://a:/",
            "https://a:65536/", "https://a:0/", "https://a:08/", "https://a:80:80/", "https://a:-1/",
            "https://a:+1/", "https://a:1 /", "https://a:/x", "https://:", "https://:0",
            "https://-a/", "https://a-/", "https://a..b/", "https://.a/", "https://a./", "https://a_b/",
            "https://a%20b/", "https://%zz/", "https://%00/", "https://%41/", "https://a b/",
            "https://a!b/", "https://a$b/", "https://a'b/", "https://a(b)/", "https://a,b/",
            "https://a;b/", "https://a=b/", "https://a*b/", "https://a+b/", "https://a~b/",
            "https://1.2.3/", "https://1.2.3.4.5/", "https://256.1.1.1/", "https://01.2.3.4/",
            "https://1.2.3.4./", "https://123/", "https://a.123/", "https://1..2.3/",
            "https://0x7f.0.0.1/", "https://1.2.3.1000/",
            "https://[]/", "https://[/", "https://[::1/", "https://[::1]x/", "https://[::1]:/",
            "https://[::1]:0/", "https://[::1]:65536/", "https://[::1]]/", "https://[::1%25eth0]/",
            "https://[::1%eth0]/", "https://[::1%25a]/", "https://[::1%a]/", "https://[::1%25ab]/",
            "https://[1.2.3.4]/", "https://[v1.a]/", "https://[:::]/",
            "https://[12345::]/", "https://[::g]/", "https://[1::2::3]/", "https://[::1:]/",
            "https://[ ::1]/", "https://[::1] /", "https://[a]/", "https://[:]/", "https://[.]/",
            "https://[::1]:80:80/", "https://[::1]@a/",
            "https://a/%", "https://a/%0", "https://a/%zz", "https://a/%0g", "https://a/%g0",
            "https://a/%00", "https://a/%FF", "https://a/%C3", "https://a/%80", "https://a/x%2",
            "https://a/?q=%", "https://a/#%z",
            "https://a/[x]", "https://a/?q=[x]", "https://a/#[x]", "https://a/#a#b", "https://a/b#c#d",
            "https://a/b c", "https://a/b%",
        ]
        // The entries of :3279-3326 that carry C escapes, as the bytes the C compiler produced.
        let escapedBad: [[UInt8]] = [
            e + [0x0A],  // "https://example.org/\n"
            e + [0x09],  // "https://example.org/\t"
            e + [0x0D, 0x0A] + Self.b("Set-Cookie:x"),  // "...\r\nSet-Cookie:x"
            Self.b("https://exa") + [0x22] + Self.b("mple.org/"),  // exa\"mple
            e + [0x5C, 0x78],  // "https://example.org/\\x"
            e + [0xC3, 0xA9],  // "https://example.org/\xc3\xa9"
            Self.b("https://") + [0xC3, 0xA9] + Self.b(".example/"),
            e + [0x7F], e + [0x01],
            e + [0xE2, 0x80, 0xAE],
            Self.b("https://a/b") + [0x22, 0x63],  // "https://a/b\"c"
            Self.b("https://a/b") + [0x7F],
        ]
        for url in plainBad.map(Self.b) + escapedBad {
            do {
                _ = try Self.status(url: url)
                Issue.record("accepted URL bytes \(url)")
            } catch {
                #expect(error.code == .invalidArg)
                #expect(!error.message.contains("javascript"))  // :3245
                #expect(!error.message.contains("evil"))  // :3246
            }
        }

        // host length (:3329-3345): 253 bytes accepted, 254 not; labels up to 63 bytes
        let l63 = String(repeating: "a", count: 63)
        let l61 = String(repeating: "b", count: 61)
        let l64 = String(repeating: "a", count: 64)
        let host253 = [l63, l63, l63, l61].joined(separator: ".")
        #expect(host253.utf8.count == 253)
        _ = try Self.status(url: Self.b("https://" + host253 + "/"))
        Self.expectRejected({ () throws in _ = try Self.status(url: Self.b("https://" + host253 + "c/")) }, "host 254")
        Self.expectRejected({ () throws in _ = try Self.status(url: Self.b("https://" + l64 + ".example/")) }, "label 64")
        _ = try Self.status(url: Self.b("https://" + l63 + ".example/"))
        // IPv6 literals longer than 45 bytes (:3347-3349)
        let longV6 = String(repeating: "1", count: 46)
        Self.expectRejected({ () throws in _ = try Self.status(url: Self.b("https://[" + longV6 + "::]/")) }, "long v6")

        // length (:3351-3365): WX_SOURCE_URL_MAX bytes accepted, one more is not
        #expect(WxLimits.sourceURLMax == 512)
        let pad = String(repeating: "a", count: WxLimits.sourceURLMax - "https://example.org/".utf8.count)
        let maxURL = "https://example.org/" + pad
        #expect(maxURL.utf8.count == WxLimits.sourceURLMax)
        let atMax = try Self.status(url: Self.b(maxURL))
        #expect(atMax.attributionURL == maxURL)
        Self.expectRejected({ () throws in _ = try Self.status(url: Self.b(maxURL + "a")) }, "513 bytes")
        // an unterminated buffer (:3361-3365)
        var raw = [UInt8](repeating: 0x61, count: WxLimits.sourceURLMax * 2)
        raw.replaceSubrange(0..<8, with: Self.b("https://"))
        Self.expectRejected({ () throws in _ = try Self.status(url: raw) }, "unterminated")

        // statuses built from a rejected URL never reach a forecast; a good one does (:3367-3386)
        Self.expectRejected({ () throws in _ = try Self.status(url: Self.b("file:///etc/passwd")) }, "file URL")
        let ok = try Self.status(url: Self.b("https://example.org/ok"))
        #expect(try ok.copy().attributionURL == "https://example.org/ok")
        let fc = try WxForecast(place: try Self.makeMiami(), generatedS: Self.t0, sources: [ok])
        #expect(fc.sources[0].attributionURL == "https://example.org/ok")
    }

    // C: /core/types/status-resanitised (src/core/test-core.c:2478-2497)
    @Test("/core/types/status-resanitised") func statusResanitised() throws {
        let nameIn: [UInt8] = [0x4E, 0x61, 0x0A, 0x6D, 0x65, 0xE2, 0x80, 0xAE, 0x58]  // "Na\nme\xe2\x80\xae" "X"
        let attrIn: [UInt8] = [0x41, 0x74, 0x01, 0x74, 0x72, 0xFF]  // "At\x01tr\xff"
        let hand = try WxSourceStatus(
            providerIDBytes: Self.b("nws"), nameBytes: nameIn, attributionBytes: attrIn,
            attributionURLBytes: Self.b(Self.goodURL), stateOrdinal: WxSourceState.failed.rawValue,
            errorCodeOrdinal: WxError.Code.http.rawValue, nMembers: 7)
        let copy = try hand.copy()
        #expect(copy.name == "NameX")
        #expect(Array(copy.attribution.utf8) == [0x41, 0x74, 0x74, 0x72, 0xEF, 0xBF, 0xBD])
        #expect(copy.state == .failed)
        #expect(copy.errorCode == .http)
        #expect(copy.nMembers == 7)
        let fc = try WxForecast(place: try Self.makeMiami(), generatedS: Self.t0, sources: [hand])
        #expect(fc.sources[0].name == "NameX")
        #expect(Array(fc.sources[0].attribution.utf8) == [0x41, 0x74, 0x74, 0x72, 0xEF, 0xBF, 0xBD])
        #expect(nameIn == [0x4E, 0x61, 0x0A, 0x6D, 0x65, 0xE2, 0x80, 0xAE, 0x58])  // input untouched
    }

    // MARK: - Forecast

    // C: /core/types/forecast-new (src/core/test-core.c:1049-1081)
    @Test("/core/types/forecast-new") func forecastNew() throws {
        let fc = try Self.makeForecastSized(48, 8, 7, 3)
        #expect(fc.generatedS == Self.t0 + 100)
        #expect(fc.place.name == "Miami")
        #expect(fc.place.countryCode == "US")
        #expect(fc.hours.count == 48)
        #expect(fc.hours[47].tS == Self.t0 + 47 * 3600)
        #expect(fc.hours[0].tempC == 28.0)
        #expect(fc.hours[0].precipMmMax == 1.0)
        #expect(fc.hours[0].tempSpreadC == 1.5)
        #expect(fc.hours[0].nMembers == 4)
        #expect(fc.hours[0].condition == .partlyCloudy)
        #expect(fc.hours[0].isDay)
        #expect(fc.quarters.count == 8)
        #expect(fc.quarters[7].tS == Self.t0 + 7 * 900)
        #expect(fc.days.count == 7)
        #expect(fc.days[6].startS == Self.t0 + 6 * 86400)
        #expect(fc.days[0].condition == .showers)
        #expect(fc.sources.count == 3)
        #expect(fc.sources[2].providerID == "src-2")
        #expect(fc.sources[2].nMembers == 2)
        // fc->ref_count (:1080) is GLIB-INTERNAL.
    }

    // C: /core/types/forecast-copies (src/core/test-core.c:1084-1113)
    @Test("/core/types/forecast-copies") func forecastCopies() throws {
        var hours = [Self.goodBlendHour(Self.t0), Self.goodBlendHour(Self.t0 + 3600)]
        var quarters = [WxQuarter(tS: Self.t0, precipMm: 0.3)]
        var days = [Self.goodDay(Self.t0)]
        let src = try WxSourceStatus(
            providerID: "nws", name: "N", attribution: "A", attributionURL: Self.goodURL,
            state: .ok, errorCode: nil, nMembers: 5)
        let fc = try WxForecast(
            place: try Self.makeMiami(), generatedS: Self.t0, hours: hours, quarters: quarters,
            days: days, sources: [src])
        hours[0].tempC = -1.0
        quarters[0].precipMm = 99.0
        days[0].tempMaxC = -1.0
        #expect(fc.hours[0].tempC == 28.0)
        #expect(fc.quarters[0].precipMm == 0.3)
        #expect(fc.days[0].tempMaxC == 31.0)
        #expect(fc.sources[0].providerID == "nws")
        #expect(fc.sources[0].name == "N")
        #expect(fc.place.name == "Miami")
        #expect(hours[0].tempC == -1.0 && quarters[0].precipMm == 99.0 && days[0].tempMaxC == -1.0)
    }

    // C: /core/types/forecast-empty-max (src/core/test-core.c:1115-1134)
    @Test("/core/types/forecast-empty-max") func forecastEmptyMax() throws {
        let empty = try Self.makeForecastSized(0, 0, 0, 0)
        #expect(empty.hours.isEmpty && empty.quarters.isEmpty && empty.days.isEmpty && empty.sources.isEmpty)
        let full = try Self.makeForecastSized(
            WxLimits.forecastMaxHours, WxLimits.forecastMaxQuarters, WxLimits.forecastMaxDays,
            WxLimits.forecastMaxSources)
        #expect(full.hours.count == 400)
        #expect(full.quarters.count == 1536)
        #expect(full.days.count == 16)
        #expect(full.sources.count == 16)
    }

    // C: /core/types/forecast-normalises (src/core/test-core.c:1136-1186)
    @Test("/core/types/forecast-normalises") func forecastNormalises() throws {
        let place = try Self.makeMiami()
        var h = Self.goodBlendHour(Self.t0)
        h.tempC = 1000
        h.feelsC = -1000
        h.precipMm = -1
        h.precipMmMax = .infinity
        h.precipProb = 101
        h.cloudPct = .nan
        h.windKmh = 501
        h.gustKmh = -1
        h.humidityPct = 200
        h.tempSpreadC = 171
        h.isDay = true  // C sets 7 (:1151); a Swift Bool is already normalised
        var d = Self.goodDay(Self.t0)
        d.tempMaxC = 80
        d.tempMinC = -101
        d.precipMm = -1
        d.precipProbMax = 101
        d.cloudPct = -1
        let fc = try WxForecast(place: place, generatedS: Self.t0, hours: [h], days: [d])
        let o = fc.hours[0]
        for v in [o.tempC, o.feelsC, o.precipMm, o.precipMmMax, o.precipProb, o.cloudPct,
                  o.windKmh, o.gustKmh, o.humidityPct, o.tempSpreadC] {
            expectNaN(v)
        }
        #expect(o.isDay == true)
        let od = fc.days[0]
        for v in [od.tempMaxC, od.tempMinC, od.precipMm, od.precipProbMax, od.cloudPct] {
            expectNaN(v)
        }

        // NAN spread (fewer than two members) stays NAN; legitimate values survive
        var one = Self.goodBlendHour(Self.t0)
        one.tempSpreadC = .nan
        one.nMembers = 1
        let f2 = try WxForecast(place: place, generatedS: Self.t0, hours: [one])
        expectNaN(f2.hours[0].tempSpreadC)
        #expect(f2.hours[0].nMembers == 1)
    }

    // C: /core/types/forecast-rejects (src/core/test-core.c:1200-1305)
    @Test("/core/types/forecast-rejects") func forecastRejects() throws {
        let place = try Self.makeMiami()
        let t0 = Self.t0
        let hs = [Self.goodBlendHour(t0), Self.goodBlendHour(t0 + 3600), Self.goodBlendHour(t0 + 7200)]
        let qs = [WxQuarter(tS: t0, precipMm: 0.1), WxQuarter(tS: t0 + 900, precipMm: 0.1), WxQuarter(tS: t0 + 1800, precipMm: 0.1)]
        let ds = [Self.goodDay(t0), Self.goodDay(t0 + 86400)]
        // assert_forecast_rejected(place, gen ?? T0, hours ?? hs, ...) with the C defaults
        func rejected(
            gen: Int64? = nil, hours: [WxBlendHour]? = nil, quarters: [WxQuarter] = [],
            days: [WxDay] = [], sources: [WxSourceStatus] = [], _ what: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            Self.expectRejected({ () throws in
                _ = try WxForecast(
                    place: place, generatedS: gen ?? t0, hours: hours ?? hs, quarters: quarters,
                    days: days, sources: sources)
            }, what, sourceLocation: sourceLocation)
        }
        // generation time
        rejected(gen: 0, "gen 0")
        rejected(gen: WxLimits.timeMaxS, "gen max")
        rejected(gen: -5, "gen -5")
        // counts above the maxima (the NULL-array-with-count and G_MAXUINT
        // lines cannot be expressed: a Swift array carries its own count)
        rejected(hours: (0...WxLimits.forecastMaxHours).map { Self.goodBlendHour(t0 + Int64($0) * 3600) }, "401 hours")
        rejected(quarters: (0...WxLimits.forecastMaxQuarters).map { WxQuarter(tS: t0 + Int64($0) * 900, precipMm: 0.1) }, "1537 quarters")
        rejected(days: (0...WxLimits.forecastMaxDays).map { Self.goodDay(t0 + Int64($0) * 86400) }, "17 days")
        let src = try Self.status(url: Self.b(Self.goodURL))
        rejected(sources: Array(repeating: src, count: WxLimits.forecastMaxSources + 1), "17 sources")

        // hours
        var bad = hs
        bad[1].tS = t0
        rejected(hours: bad, "duplicate hour")
        bad = hs
        bad[2].tS = t0 + 1800
        rejected(hours: bad, "descending hour")
        bad = hs
        bad[1].tS = t0 + 3601
        rejected(hours: bad, "unaligned hour")
        bad = hs
        bad[0].tS = 0
        rejected(hours: bad, "hour 0")
        // condition WX_COND_COUNT / -1 (:1240-1245): unrepresentable; the
        // cache maps its stored ordinal through WxCondition(rawValue:).
        #expect(WxCondition(rawValue: WxCondition.count) == nil)
        #expect(WxCondition(rawValue: -1) == nil)

        // quarters
        var bq = qs
        bq[1].tS = t0
        rejected(quarters: bq, "duplicate quarter")
        bq = qs
        bq[1].tS = t0 + 901
        rejected(quarters: bq, "unaligned quarter")
        bq = qs
        bq[2].precipMm = .nan
        rejected(quarters: bq, "NaN quarter")
        bq = qs
        bq[0].precipMm = -0.5
        rejected(quarters: bq, "negative quarter")

        // days
        var bd = ds
        bd[1].startS = t0
        rejected(days: bd, "duplicate day")
        bd = ds
        bd[0].startS = 5
        rejected(days: bd, "day 5")

        // sources: bad id / state / error code (:1275-1290) cannot form a
        // WxSourceStatus, so they never reach a forecast.
        for (id, state, err) in [(Self.b("Bad Id"), 0, -1), (nil, 0, -1), (Self.b("nws"), 9, -1), (Self.b("nws"), 0, 99)] as [([UInt8]?, Int, Int)] {
            Self.expectRejected({ () throws in
                _ = try WxSourceStatus(
                    providerIDBytes: id, nameBytes: Self.b("N"), attributionBytes: Self.b("A"),
                    attributionURLBytes: Self.b(Self.goodURL), stateOrdinal: state,
                    errorCodeOrdinal: err, nMembers: 0)
            }, "source \(String(describing: id)) \(state) \(err)")
        }
        // hand-built hostile place (:1292-1301): such a WxPlace cannot be built.
        Self.expectRejected({ () throws in _ = try WxPlace(name: nil, lat: 0, lon: 0) }, "place {0}")
        Self.expectRejected({ () throws in
            _ = try WxPlace(nameBytes: [0x78, 0x0A, 0x78], admin1Bytes: [], countryBytes: [], lat: 0, lon: 0, timezoneBytes: [])
        }, "place x\\nx")
        Self.expectRejected({ () throws in _ = try WxPlace(name: "ok", lat: 100.0, lon: 0) }, "place lat 100")
    }

    // C: /core/types/forecast-normalise-limits (src/core/test-core.c:2293-2395)
    @Test("/core/types/forecast-normalise-limits") func forecastNormaliseLimits() throws {
        let place = try Self.makeMiami()
        let t0 = Self.t0
        var hs = [Self.goodBlendHour(t0), Self.goodBlendHour(t0 + 3600), Self.goodBlendHour(t0 + 7200), Self.goodBlendHour(t0 + 10800)]
        hs[0].tempC = -100.0
        hs[0].feelsC = 70.0
        hs[0].precipMm = 500.0
        hs[0].precipMmMax = 500.0
        hs[0].precipProb = 100.0
        hs[0].cloudPct = 0.0
        hs[0].windKmh = 500.0
        hs[0].gustKmh = 0.0
        hs[0].humidityPct = 100.0
        hs[0].tempSpreadC = WxLimits.tempSpreadMaxC
        hs[0].nMembers = 255
        hs[0].isDay = false
        hs[1].tempC = -100.001
        hs[1].feelsC = 70.001
        hs[1].precipMm = 500.001
        hs[1].precipMmMax = 500.001
        hs[1].precipProb = 100.001
        hs[1].cloudPct = -0.001
        hs[1].windKmh = 500.001
        hs[1].gustKmh = -0.001
        hs[1].humidityPct = 100.001
        hs[1].tempSpreadC = WxLimits.tempSpreadMaxC + 0.001
        hs[2].tempSpreadC = -0.001
        hs[3].tempSpreadC = 0.0
        hs[3].tempC = .infinity
        hs[3].windKmh = -.infinity
        hs[3].isDay = true  // C: 7, normalised to TRUE (:2328)
        var ds = [Self.goodDay(t0), Self.goodDay(t0 + 86400)]
        ds[0].tempMaxC = 70.0
        ds[0].tempMinC = -100.0
        ds[0].precipMm = WxLimits.precipMaxMmDay
        ds[0].precipProbMax = 100.0
        ds[0].cloudPct = 0.0
        ds[1].tempMaxC = 70.001
        ds[1].tempMinC = -100.001
        ds[1].precipMm = WxLimits.precipMaxMmDay + 0.001
        ds[1].precipProbMax = 100.001
        ds[1].cloudPct = -0.001
        #expect(WxLimits.precipMaxMmDay == 12000.0)  // :2340
        #expect(WxLimits.tempSpreadMaxC == 170.0)  // :2341

        let fc = try WxForecast(place: place, generatedS: t0, hours: hs, days: ds)
        let o = fc.hours
        #expect(o[0].tempC == -100.0)
        #expect(o[0].feelsC == 70.0)
        #expect(o[0].precipMm == 500.0)
        #expect(o[0].precipMmMax == 500.0)
        #expect(o[0].precipProb == 100.0)
        #expect(o[0].cloudPct == 0.0)
        #expect(o[0].windKmh == 500.0)
        #expect(o[0].gustKmh == 0.0)
        #expect(o[0].humidityPct == 100.0)
        #expect(o[0].tempSpreadC == 170.0)
        #expect(o[0].nMembers == 255)
        #expect(o[0].isDay == false)
        for v in [o[1].tempC, o[1].feelsC, o[1].precipMm, o[1].precipMmMax, o[1].precipProb,
                  o[1].cloudPct, o[1].windKmh, o[1].gustKmh, o[1].humidityPct, o[1].tempSpreadC] {
            expectNaN(v)
        }
        expectNaN(o[2].tempSpreadC)
        #expect(o[3].tempSpreadC == 0.0)
        expectNaN(o[3].tempC)
        expectNaN(o[3].windKmh)
        #expect(o[3].isDay == true)
        #expect(fc.days[0].tempMaxC == 70.0)
        #expect(fc.days[0].tempMinC == -100.0)
        #expect(fc.days[0].precipMm == 12000.0)
        #expect(fc.days[0].precipProbMax == 100.0)
        #expect(fc.days[0].cloudPct == 0.0)
        for v in [fc.days[1].tempMaxC, fc.days[1].tempMinC, fc.days[1].precipMm,
                  fc.days[1].precipProbMax, fc.days[1].cloudPct] {
            expectNaN(v)
        }

        // every condition below WX_COND_COUNT is accepted and copied as given
        for c in 0..<WxCondition.count {
            let cond = try #require(WxCondition(rawValue: c))
            var one = Self.goodBlendHour(t0)
            one.condition = cond
            var day = Self.goodDay(t0)
            day.condition = cond
            let f = try WxForecast(place: place, generatedS: t0, hours: [one], days: [day])
            #expect(f.hours[0].condition.rawValue == c)
            #expect(f.days[0].condition.rawValue == c)
        }
    }

    // C: /core/types/time-range-edges, forecast lines (src/core/test-core.c:2527-2570)
    @Test("/core/types/time-range-edges (forecasts)") func timeRangeEdgesForecasts() throws {
        let place = try Self.makeMiami()
        var bh = Self.goodBlendHour(WxLimits.timeMinS)
        var bq = WxQuarter(tS: WxLimits.timeMinS, precipMm: 0.1)
        var bd = Self.goodDay(WxLimits.timeMinS)
        _ = try WxForecast(place: place, generatedS: WxLimits.timeMinS, hours: [bh], quarters: [bq], days: [bd])
        bh.tS = WxLimits.timeMaxS - 3600
        bq.tS = WxLimits.timeMaxS - 900
        bd.startS = WxLimits.timeMaxS - 1
        _ = try WxForecast(place: place, generatedS: WxLimits.timeMaxS - 1, hours: [bh], quarters: [bq], days: [bd])
        let cases: [(Int64, [WxBlendHour], [WxQuarter], [WxDay], String)] = [
            (WxLimits.timeMinS - 1, [bh], [bq], [bd], "gen min-1"),
            (WxLimits.timeMaxS, [bh], [bq], [bd], "gen max"),
            (Self.t0, [WxBlendHour(tS: WxLimits.timeMaxS)], [], [], "hour max"),
            (Self.t0, [WxBlendHour(tS: WxLimits.timeMinS - 3600)], [], [], "hour min-3600"),
            (Self.t0, [], [WxQuarter(tS: WxLimits.timeMaxS, precipMm: 0.1)], [], "quarter max"),
            (Self.t0, [], [WxQuarter(tS: WxLimits.timeMinS - 900, precipMm: 0.1)], [], "quarter min-900"),
            (Self.t0, [], [], [WxDay(startS: WxLimits.timeMaxS)], "day max"),
            (Self.t0, [], [], [WxDay(startS: WxLimits.timeMinS - 1)], "day min-1"),
        ]
        for (gen, h, q, d, what) in cases {
            Self.expectRejected({ () throws in
                _ = try WxForecast(place: place, generatedS: gen, hours: h, quarters: q, days: d)
            }, what)
        }
    }

    // C: /core/types/id-validation, status line (src/core/test-core.c:239)
    @Test("/core/types/id-validation (source status)") func idValidationStatus() {
        Self.expectRejected({ () throws in
            _ = try WxSourceStatus(
                providerID: "..", name: "n", attribution: "a", attributionURL: Self.goodURL,
                state: .ok, errorCode: nil, nMembers: 0)
        }, "status id ..")
    }

    // C: /core/types/error-messages-no-echo, status lines (src/core/test-core.c:2432-2437)
    @Test("/core/types/error-messages-no-echo (source status)") func errorMessagesNoEchoStatus() {
        let secret = "SECRETZZ"  // :2400
        let evilURL = "javascript:" + secret  // :2403
        let attempts: [() throws -> Void] = [
            { () throws in
                _ = try WxSourceStatus(providerID: secret, name: "n", attribution: "a", attributionURL: "", state: .ok, errorCode: nil, nMembers: 0)
            },
            { () throws in
                _ = try WxSourceStatus(providerID: "x", name: "n", attribution: "a", attributionURL: evilURL, state: .ok, errorCode: nil, nMembers: 0)
            },
        ]
        for attempt in attempts {
            do {
                try attempt()
                Issue.record("a hostile status was accepted")
            } catch {
                #expect((error as? WxError)?.code == .invalidArg)
                #expect(!String(describing: error).contains(secret))
            }
        }
    }

    // C: /core/types/place-timezone-shapes, forecast line (src/core/test-core.c:3230-3235):
    // a place with timezone "/etc/passwd" cannot be built, so no forecast carries it.
    @Test("/core/types/place-timezone-shapes (forecast)") func placeTimezoneForecast() {
        Self.expectRejected({ () throws in
            _ = try WxPlace(
                name: "Miami", admin1: "Florida", country: "United States", countryCode: "US",
                lat: 25.7617, lon: -80.1918, timezone: "/etc/passwd")
        }, "timezone /etc/passwd")
    }
}
