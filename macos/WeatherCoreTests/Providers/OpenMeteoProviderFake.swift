// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoProviderFake.swift - the path-routed fake Open-Meteo server of the
// provider and geocoder tests (C: test-openmeteo.c:1870-2337: Reply, Script,
// handle_request, synth_body, script_ok, provider_for, geocoder_for, mk_place)
// on the shared LoopbackServer. Differences from the C fake, on purpose: it
// binds 127.0.0.1 only and runs on its own queue (LoopbackServer); the time at
// which the successful answer of request A is written is recorded on
// ContinuousClock (the tests measure their fetches on the same clock).

import Foundation
import Synchronization
import Testing
@testable import WeatherCore

/// Namespace of the Open-Meteo fake server (test bundle only).
enum OpenMeteoProviderFake {

    /// UA (test-openmeteo.c:1873).
    static let ua = "weather-app/0.1 (github.com/wtp128pro/weather)"
    /// T0 (test-openmeteo.c:56): 2026-10-12T00:00:00Z, the first stamp of the fixtures.
    static let t0: Int64 = 1_791_763_200

    /// ReplyKind + Reply (test-openmeteo.c:1875-1888).
    struct Reply: Sendable {
        enum Kind: Sendable {
            /// R_REPLY: status + headers + body (optionally gzip), then close.
            case reply
            /// R_HANG: read the request, never answer.
            case hang
            /// R_CLOSE: close without answering.
            case close
            /// R_CUT: declare 500 bytes more body than is sent, then close.
            case cut
        }

        var kind: Kind
        var status: Int
        /// nil: a forecast body synthesised from the models of the request (synth_body).
        var body: String?
        var gzip: Bool
        var delayMs: Int

        init(_ kind: Kind, _ status: Int = 200, _ body: String? = nil, gzip: Bool = false, delayMs: Int = 0) {
            self.kind = kind
            self.status = status
            self.body = body
            self.gzip = gzip
            self.delayMs = delayMs
        }
    }

    /// Script (test-openmeteo.c:1891-1894): request A, request B (minutely_15), the search.
    struct Script: Sendable {
        var a: Reply
        var b: Reply
        var geo: Reply
        /// The first `aFirstFail` attempts of request A answer 503 at once.
        var aFirstFail = 0

        /// script_ok (test-openmeteo.c:2193-2207): A synthesised, B nowcast_miami.json, the
        /// search geocode_miami.json, all 200.
        static func ok() throws -> Script {
            Script(
                a: Reply(.reply, 200),
                b: Reply(.reply, 200, try Fixtures.string("nowcast_miami.json")),
                geo: Reply(.reply, 200, try Fixtures.string("geocode_miami.json")))
        }
    }

    /// The fake (C: Fake, fake_new, fake_free; test-openmeteo.c:1904-1915, :2015-2155).
    final class Server: Sendable {
        struct State: Sendable {
            var script: Script
            /// a_seen: attempts of request A so far.
            var aSeen = 0
            /// a_answer_us: when the answer that A succeeds with is written.
            var aAnswer: ContinuousClock.Instant?
        }

        let server: LoopbackServer
        let state: LoopbackServer.Shared<State>

        init(_ script: Script) throws {
            let state = LoopbackServer.Shared(State(script: script))
            self.state = state
            server = try LoopbackServer(reply: { _, request in
                Server.handle(request.path, state)
            })
        }

        /// http://127.0.0.1:<port>.
        var baseURL: String { "http://127.0.0.1:\(server.port)" }
        /// fake->requests.
        var requestCount: Int { server.requestCount }
        /// fake->paths.
        var paths: [String] { server.paths }
        /// fake->heads.
        var heads: [String] { server.requests.map(\.head) }
        /// fake->a_seen.
        var aSeen: Int { state.value.aSeen }
        /// fake->a_answer_us.
        var aAnswer: ContinuousClock.Instant? { state.value.aAnswer }

        /// Replaces the script (C: fake2->script = ok).
        func setScript(_ script: Script) {
            state.withLock { $0.script = script }
        }

        func stop() {
            server.stop()
        }

        /// fake_path_with (test-openmeteo.c:2178-2191): the one request whose target contains
        /// `needle` (nil: the one request without "minutely_15"); nil if none; a test failure if
        /// several match.
        func path(with needle: String?) -> String? {
            let matches = paths.filter { needle.map($0.contains) ?? !$0.contains("minutely_15") }
            #expect(matches.count <= 1, "several requests match \(needle ?? "request A")")
            return matches.first
        }

        /// handle_request (test-openmeteo.c:2015-2075), run on the server's queue.
        private static func handle(_ path: String, _ state: LoopbackServer.Shared<State>) -> LoopbackServer.Step {
            let reply: Reply = state.withLock { s in
                if path.hasPrefix("/v1/search") {
                    return s.script.geo
                }
                if path.contains("minutely_15") {
                    return s.script.b
                }
                let seen = s.aSeen
                s.aSeen += 1
                if seen < s.script.aFirstFail {
                    return Reply(.reply, 503, "{}")  // refused attempts of A (the client retries them)
                }
                if s.script.a.kind == .reply || s.script.a.kind == .cut {
                    s.aAnswer = ContinuousClock.now + .milliseconds(s.script.a.delayMs)
                }
                return s.script.a
            }
            switch reply.kind {
            case .hang:
                return .hang
            case .close:
                return .close
            case .reply, .cut:
                let text = reply.body ?? synthBody(path)
                if reply.kind == .cut {
                    let payload = Data(text.utf8)
                    return .truncated(
                        status: reply.status, body: payload + Data(repeating: 0x20, count: 500), sent: payload.count)
                }
                if reply.gzip {
                    precondition(reply.status == 200 && reply.delayMs == 0, "gzip replies are immediate 200s")
                    return .gzip(body: Data(text.utf8))
                }
                return .respond(status: reply.status, body: Data(text.utf8), delay: .milliseconds(reply.delayMs))
            }
        }

        /// synth_body (test-openmeteo.c:1980-2013): 4 hourly stamps from T0 for every model named
        /// in the "models=" parameter of `path`; value = base + model index + stamp index.
        static func synthBody(_ path: String) -> String {
            guard let m = path.range(of: "models=") else {
                return "{}"
            }
            let rest = path[m.upperBound...]
            let list = rest.prefix { $0 != "&" }
            let names = list.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let vars: [(String, Double)] = [
                ("temperature_2m", 20), ("apparent_temperature", 21), ("relative_humidity_2m", 60),
                ("precipitation", 0.5), ("precipitation_probability", 30), ("cloud_cover", 40),
                ("wind_speed_10m", 10), ("wind_gusts_10m", 15), ("weather_code", 3),
            ]
            var s = "{\"hourly\":{\"time\":["
            s += (0..<4).map { String(t0 + Int64($0) * 3600) }.joined(separator: ",")
            s += "]"
            for (mi, name) in names.enumerated() {
                for (key, base) in vars {
                    s += ",\"" + key + (names.count > 1 ? "_" + name : "") + "\":["
                    s += (0..<4).map { String(format: "%.17g", locale: nil, base + Double(mi) + Double($0)) }
                        .joined(separator: ",")
                    s += "]"
                }
            }
            return s + "}}"
        }
    }

    /// provider_for (test-openmeteo.c:2209-2218).
    static func provider(_ fake: Server, timeoutMs: Int, backoffMs: Int) throws -> OpenMeteoProvider {
        try OpenMeteoProvider(customBaseURL: fake.baseURL, timeoutMs: timeoutMs, backoffBaseMs: backoffMs)
    }

    /// geocoder_for (test-openmeteo.c:2220-2229).
    static func geocoder(_ fake: Server, timeoutMs: Int, backoffMs: Int) throws -> OpenMeteoGeocoder {
        try OpenMeteoGeocoder(customBaseURL: fake.baseURL, timeoutMs: timeoutMs, backoffBaseMs: backoffMs)
    }

    /// mk_place (test-openmeteo.c:2231-2239).
    static func place(_ name: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
        try WxPlace(name: name, admin1: "", country: "", countryCode: "", lat: lat, lon: lon, timezone: "")
    }

    /// The outcome of one fetch or search and its duration on ContinuousClock (C: Op).
    struct Op<Value: Sendable>: Sendable {
        let outcome: Result<Value, any Error>
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant

        /// elapsed_ms (test-openmeteo.c:2319-2323).
        var elapsedMs: Int64 {
            let d = (end - start).components
            return d.seconds * 1000 + d.attoseconds / 1_000_000_000_000_000
        }
        var value: Value? { try? outcome.get() }
        var wxError: WxError? {
            if case .failure(let error as WxError) = outcome { return error }
            return nil
        }
        var isCancelled: Bool {
            if case .failure(let error) = outcome { return error is CancellationError }
            return false
        }
    }

    /// fetch_start + op_wait: one fetch, timed.
    static func fetch(_ provider: OpenMeteoProvider, _ place: WxPlace) async -> Op<WxSourceResult> {
        let start = ContinuousClock.now
        let outcome: Result<WxSourceResult, any Error>
        do {
            outcome = .success(try await provider.fetch(place))
        } catch {
            outcome = .failure(error)
        }
        return Op(outcome: outcome, start: start, end: ContinuousClock.now)
    }

    /// search_start + op_wait: one search of raw bytes, timed.
    static func search(_ geocoder: OpenMeteoGeocoder, _ bytes: [UInt8]) async -> Op<[WxPlace]> {
        let start = ContinuousClock.now
        let outcome: Result<[WxPlace], any Error>
        do {
            outcome = .success(try await geocoder.search(textBytes: bytes))
        } catch {
            outcome = .failure(error)
        }
        return Op(outcome: outcome, start: start, end: ContinuousClock.now)
    }

    /// The model ids of a result's members, in order.
    static func memberIDs(_ result: WxSourceResult?) -> [String] {
        result?.members.map(\.modelID) ?? []
    }
}
