// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HTTPClientTests.swift - the behavioural net/ and deadline/ tests of
// src/net/test-http.c (registrations :5126-5182) ported to HTTPClient on the
// U03 LoopbackServer. Each test names its C path. Expected values are the C
// tests' literals (test-http.c:LINE); the only expectations that are not C
// literals are the documented differences of DECISIONS #30 (Accept-Language
// is `*`), the DECISIONS #34 item 1 platform rows (CFNetwork's in-task
// re-sends, resendsAreChargedAgainstTheRequestBudget) and the NEW U13-N9 rows
// of DECISIONS #40 (lastHeaderLine rule (b), which records C's duplicate-row
// literal test-http.c:4611-4612 as a platform row), marked as such. HTTPClientWireTests.swift holds the outcome tests
// that replace the libsoup wire-framing cases and the gzip/coding/TLS tests.
//
// C fake -> LoopbackServer: STEP_RESPOND -> .respond / .text, STEP_HANG ->
// .hang, STEP_CLOSE -> .close, STEP_RAW/STEP_BYTES -> .raw, STEP_BYTES_HANG
// -> .bytesHang, STEP_BYTES_SPLIT -> .bytesSplit, STEP_BIG_* -> .big*,
// STEP_GZIP -> .gzip. GCancellable -> Task cancellation (CancellationError
// stands for G_IO_ERROR_CANCELLED). Real-time tests use SystemClock with the
// C tests' short timings; the 45 s deadline runs on a ManualClock, and so do
// the rows whose outcome would otherwise race loopback delivery against a
// short real-time window (expectHeld, gatedAttempt; DECISIONS #66).

import Foundation
import Testing
@testable import WeatherCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPClientTests {

    // MARK: Fixtures and helpers (C: test-http.c:34-35, :1871-1967)

    /// UA (test-http.c:34).
    static let ua = "weather-app/0.1 (github.com/wtp128pro/weather)"
    /// JSON_ACCEPT (test-http.c:35).
    static let jsonAccept = "application/json"
    /// kBody (test-http.c:1960).
    static let kBody = #"{"ok":true,"SENTINEL-BODY-TEXT":1}"#
    /// kGzipJson (test-http.c:2513-2514).
    static let kGzipJson = #"{"data":null,"status":{"rCode":200},"SENTINEL-BODY-TEXT":[1,2,3,4,5,6,7,8,9,10,11,12]}"#
    /// The If-Modified-Since value of the C tests (test-http.c:2834, :4485).
    static let imsValue = "Sun, 06 Nov 1994 08:49:37 GMT"
    /// 1 + WX_HTTP_MAX_RETRIES requests (test-http.c:2209 and every retried case).
    static let retried = 1 + HTTPPolicy.maxRetries

    typealias Outcome = Result<HTTPClient.Response, any Error>

    /// http_for (test-http.c:1871): a client of `server` with the given timings and the
    /// decoded-body cap `maxBodyBytes` (nil: its host's, HTTPPolicy.maxBodyBytes on loopback).
    static func client(
        _ server: LoopbackServer, timeoutMs: Int, backoffMs: Int, gapMs: Int = 0,
        clock: any WxClock = SystemClock(), totalDeadlineMs: Int = HTTPPolicy.totalDeadlineMs,
        maxBodyBytes: Int? = nil
    ) throws -> HTTPClient {
        let policy = try HTTPClientPolicy(
            baseURL: "http://127.0.0.1:\(server.port)", userAgent: ua, timeoutMs: timeoutMs,
            backoffBaseMs: backoffMs, minGapMs: gapMs)
        return try HTTPClient(
            policy: policy, clock: clock, totalDeadlineMs: totalDeadlineMs, maxBodyBytes: maxBodyBytes)
    }

    /// get (test-http.c:1953): GET `path` with JSON_ACCEPT.
    static func fetch(_ client: HTTPClient, _ path: String = "/x", ims: String? = nil) async -> Outcome {
        do {
            return .success(try await client.get(path, accept: jsonAccept, ifModifiedSince: ims))
        } catch {
            return .failure(error)
        }
    }

    /// Runs `fetch` in a new task and returns it with its start time.
    static func start(_ client: HTTPClient, _ path: String = "/x", ims: String? = nil) -> Task<Outcome, Never> {
        Task { await fetch(client, path, ims: ims) }
    }

    static func wxError(_ outcome: Outcome) -> WxError? {
        if case .failure(let error as WxError) = outcome { return error }
        return nil
    }

    static func isCancelled(_ outcome: Outcome) -> Bool {
        if case .failure(let error) = outcome { return error is CancellationError }
        return false
    }

    static func body(_ outcome: Outcome) -> Data? {
        if case .success(let response) = outcome { return response.body }
        return nil
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    /// run_step_case_ims (test-http.c:2435): serves `step` per request, GET /x
    /// (with If-Modified-Since `ims`) on a client with back-off 5 ms; expects
    /// `code` (nil: success with `okBody`) after exactly `requests` requests.
    /// A failure message never contains body text (assert_no_body_text,
    /// test-http.c:1963) and contains `messageContains` when given.
    static func expectCase(
        _ step: LoopbackServer.Step, ims: String? = nil, code: WxError.Code?, requests: Int,
        okBody: Data? = nil, timeoutMs: Int = 2000, messageContains: String? = nil,
        _ label: String = "", sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let server = try LoopbackServer([step])
        defer { server.stop() }
        let http = try client(server, timeoutMs: timeoutMs, backoffMs: 5)
        let outcome = await fetch(http, ims: ims)
        // The last request can still be on its way into the server's log when the outcome is in; the
        // outcome came after it was made, so a short wait covers the lag (a wrong count fails fast).
        _ = await server.waitForRequests(requests, timeout: .seconds(1))
        if let code {
            guard let error = wxError(outcome) else {
                Issue.record("\(label): expected \(code), got \(outcome)", sourceLocation: sourceLocation)
                return
            }
            #expect(error.code == code, "\(label): \(error.message)", sourceLocation: sourceLocation)
            #expect(!error.message.contains("SENTINEL"), "\(label)", sourceLocation: sourceLocation)
            if let messageContains {
                #expect(error.message.contains(messageContains), "\(label): \(error.message)", sourceLocation: sourceLocation)
            }
        } else {
            #expect(body(outcome) == okBody, "\(label): \(outcome)", sourceLocation: sourceLocation)
        }
        #expect(server.requestCount == requests, "\(label): requests", sourceLocation: sourceLocation)
    }

    /// run_failure_case (test-http.c:2173): timeout 30000, back-off 5.
    static func expectFailure(
        _ step: LoopbackServer.Step, _ code: WxError.Code, requests: Int, _ label: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await expectCase(
            step, code: code, requests: requests, timeoutMs: 30000, label, sourceLocation: sourceLocation)
    }

    // MARK: Request shape

    // C: /http/net/success-request-shape (test-http.c:1969-2029)
    @Test func successRequestShape() async throws {
        let server = try LoopbackServer([.text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 10)
        let outcome = await Self.fetch(http, "/v1/forecast?latitude=25.7617&longitude=-80.1918")
        let response = try outcome.get()
        #expect(response.status == 200)
        #expect(response.body == Data(Self.kBody.utf8))
        #expect(response.expiresS == 0)
        #expect(response.lastModified == nil)
        let arrivals = server.requests.map { Self.milliseconds($0.arrival - server.requests[0].arrival) }
        #expect(server.requestCount == 1,
                "arrivals (ms after the first) \(arrivals), attempts \(http.finishedAttemptCount), closed early \(server.closedEarlyCount)")
        #expect(server.paths.first == "/v1/forecast?latitude=25.7617&longitude=-80.1918")

        let request = try #require(server.requests.first)
        let head = request.head
        #expect(head.hasPrefix("GET /v1/forecast?latitude=25.7617&longitude=-80.1918 HTTP/1.1\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
        let lines = head.components(separatedBy: "\r\n").prefix { !$0.isEmpty }
        #expect(lines.filter { $0.hasPrefix("GET ") || $0.contains(" HTTP/1.") }.count == 1)
        // The C allow-list (test-http.c:2005-2006) plus accept-language, the documented
        // difference of DECISIONS #30 (URLSession adds the user's locale otherwise).
        let allowed: Set<String> = ["host", "user-agent", "accept", "accept-encoding", "connection", "accept-language"]
        var seen: Set<String> = []
        for line in lines.dropFirst() {
            let colon = try #require(line.firstIndex(of: ":"), "header line without a colon: \(line)")
            let name = line[..<colon].lowercased()
            #expect(allowed.contains(name), "unexpected request header \(line)")
            seen.insert(name)
        }
        #expect(seen.isSuperset(of: ["user-agent", "accept", "host", "accept-language", "accept-encoding"]))
        #expect(request.header("User-Agent") == Self.ua)                       // test-http.c:2010
        #expect(request.header("Accept") == Self.jsonAccept)                   // test-http.c:2013
        #expect(request.header("Host") == "127.0.0.1:\(server.port)")          // test-http.c:2017
        #expect(request.header("Accept-Encoding") == "gzip")                   // test-http.c:2542
        // Documented difference (DECISIONS #30, not a C literal): one constant value, never
        // the user's locale, also under the de_DE test locale.
        #expect(request.headers("Accept-Language") == ["*"])
        for forbidden in ["Cookie", "Authorization", "Referer", "Origin", "Mozilla", "If-Modified-Since",
                          "Proxy-Authorization", "X-"] {                     // test-http.c:2022-2023
            #expect(!head.contains(forbidden), "request head contains \(forbidden)")
        }
    }

    // C: /http/net/invalid-args (test-http.c:2032-2102)
    @Test func invalidArgumentsMakeNoRequest() async throws {
        let server = try LoopbackServer([.text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 10)
        let ja = Self.jsonAccept
        let cases: [(String, String, String?)] = [                            // test-http.c:2045-2061
            ("//x", ja, nil), ("/a b", ja, nil), ("/a#b", ja, nil), ("/a\u{01}", ja, nil),
            ("/a\r\nHost: evil", ja, nil), ("", ja, nil), ("relative", ja, nil), ("/a%zz", ja, nil),
            ("/a%", ja, nil), ("/ok", "", nil), ("/ok", "application/json\r\nCookie: x=1", nil),
            ("/ok", "application/json\n", nil), ("/ok", "application/\u{E9}", nil), ("/ok", ja, ""),
            ("/ok", ja, "Sun, 06 Nov 1994 08:49:37 GMT\r\nX: y"), ("/ok", ja, "\u{E9}"),
        ]
        for (path, accept, ims) in cases {
            do {
                _ = try await http.get(path, accept: accept, ifModifiedSince: ims)
                Issue.record("accepted \(path.debugDescription) \(accept.debugDescription)")
            } catch let error as WxError {
                #expect(error.code == .invalidArg, "\(path.debugDescription)")
                #expect(!error.message.contains("evil"))
                #expect(!error.message.contains("Cookie"))
            }
        }
        let longPath = "/" + String(repeating: "a", count: HTTPPolicy.pathMax)  // test-http.c:2037-2038
        let longIMS = String(repeating: "a", count: HTTPPolicy.validatorMax + 1)
        let longAccept = String(repeating: "a", count: HTTPPolicy.headerValueMax + 1)
        for (path, accept, ims) in [(longPath, ja, nil), ("/ok", longAccept, nil), ("/ok", ja, longIMS)] {
            let error = await #expect(throws: WxError.self) {
                _ = try await http.get(path, accept: accept, ifModifiedSince: ims)
            }
            #expect(error?.code == .invalidArg)
        }
        #expect(server.requestCount == 0)                                       // test-http.c:2087
        // The boundary lengths are fine (test-http.c:2089-2100).
        let maxPath = "/" + String(repeating: "a", count: HTTPPolicy.pathMax - 1)
        let maxIMS = String(repeating: "a", count: HTTPPolicy.validatorMax)
        let maxAccept = String(repeating: "a", count: HTTPPolicy.headerValueMax)
        _ = try await http.get(maxPath, accept: maxAccept, ifModifiedSince: maxIMS)
        #expect(server.requestCount == 1)
    }

    // C: /http/net/callback-never-before-return (test-http.c:2117-2140). With async/await
    // there is no callback; the behavioural part is that an invalid argument and a
    // pre-cancelled caller are reported without traffic.
    @Test func invalidAndPreCancelledReportedWithoutTraffic() async throws {
        let server = try LoopbackServer([.text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 10)
        #expect(Self.wxError(await Self.fetch(http, "//bad"))?.code == .invalidArg)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.fetch(http)
        }.value
        #expect(Self.isCancelled(cancelled))
        #expect(server.requestCount == 0)
    }

    // C: none (executor addition for the TRANSPORT criterion).
    // TRANSPORT criterion: no Cookie header after Set-Cookie (wx-http.h:9-12 "No ... cookie
    // ... is ever sent"; the C head check forbids "Cookie", test-http.c:2022). Cookies that a
    // jar would accept for 127.0.0.1 are offered and must never come back.
    @Test func noCookieIsSentAfterSetCookie() async throws {
        let server = try LoopbackServer([
            .respond(headers: ["Set-Cookie: session=abc; Path=/", "Set-Cookie: id=1; Max-Age=3600; Path=/"],
                     body: Data(Self.kBody.utf8)),
        ])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        for path in ["/a", "/a", "/b"] {
            #expect(Self.body(await Self.fetch(http, path)) == Data(Self.kBody.utf8))
        }
        #expect(server.requestCount == 3)
        for request in server.requests {
            #expect(request.header("Cookie") == nil, "\(request.head)")
            #expect(!request.head.contains("Cookie"))
        }
    }

    // C: none (executor addition for the TRANSPORT criterion).
    // TRANSPORT criterion: no URL cache (wx-http.c:364-366, no cache feature). A response that
    // invites caching is never replayed: every GET reaches the server, unconditionally.
    @Test func responsesAreNeverServedFromAURLCache() async throws {
        let cacheable = ["Cache-Control: public, max-age=3600", "ETag: \"v1\"",
                         "Last-Modified: Sun, 06 Nov 1994 08:49:37 GMT", "Expires: Thu, 01 Jan 2099 00:00:00 GMT"]
        let server = try LoopbackServer([
            .respond(headers: cacheable, body: Data(#"{"n":1}"#.utf8)),
            .respond(headers: cacheable, body: Data(#"{"n":2}"#.utf8)),
            .respond(headers: cacheable, body: Data(#"{"n":3}"#.utf8)),
        ])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        for n in 1...3 {
            #expect(Self.body(await Self.fetch(http, "/same?x=1")) == Data(#"{"n":\#(n)}"#.utf8), "GET \(n)")
        }
        #expect(server.requestCount == 3)
        for request in server.requests {
            #expect(request.header("If-None-Match") == nil)
            #expect(request.header("If-Modified-Since") == nil)
        }
    }

    // C: none (executor addition for the DELEGATE criterion). C anchors: wx-http.h:25-30 (the
    // per-attempt and whole-operation deadlines are the client's own timers; in C the GLib
    // main-context sources of wx-http.c:1598-1600 and :1856-1858) and wx-http.h:259-262 (the
    // instance and its callbacks belong to one main context).
    // DELEGATE criterion (brief U13; cartography macos-platform.md:99-128): every URLSession
    // delegate method of the client has its completion-handler form (no async @objc
    // requirement), and the client waits only on the injected WxClock (no other clock, timer
    // or sleeper). Checked on the source files next to this test's source.
    @Test func delegateSignaturesAndClockUse() throws {
        let netDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WeatherCore/Net")
        var code = ""
        for name in ["HTTPClient.swift", "HTTPClientTransfer.swift"] {
            let text = try String(contentsOf: netDirectory.appendingPathComponent(name), encoding: .utf8)
            // Without comments, so documentation cannot satisfy or trip the checks.
            code += text.components(separatedBy: "\n").map { line in
                line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
            }.joined(separator: "\n")
        }
        var declarations: [String] = []
        var rest = Substring(code)
        while let start = rest.range(of: "func urlSession(") {
            let tail = rest[start.lowerBound...]
            let end = tail.firstIndex(of: "{") ?? tail.endIndex
            declarations.append(String(tail[..<end]))
            rest = tail[end...]
        }
        #expect(declarations.count >= 8, "delegate methods found: \(declarations.count)")
        for declaration in declarations {
            #expect(!declaration.contains("async"), "async delegate method: \(declaration)")
        }
        for selector in ["willPerformHTTPRedirection", "didReceive challenge", "didReceive response"] {
            let matching = declarations.filter { $0.contains(selector) }
            #expect(matching.count >= 1, "\(selector) not implemented")
            #expect(matching.allSatisfy { $0.contains("completionHandler: @escaping") }, "\(selector)")
        }
        for forbidden in ["Task.sleep", "ContinuousClock", "SuspendingClock", "asyncAfter", "Timer", "usleep(",
                          "nanosleep", "DispatchTime", ": Clock", "RandomNumberGenerator", "Date()"] {
            #expect(!code.contains(forbidden), "the client uses \(forbidden)")
        }
        #expect(code.contains("clock.sleep(until:"))
        #expect(code.contains("any WxClock"))
    }

    // MARK: Status mapping, redirects, retries

    // C: /http/net/status-mapping (test-http.c:2190-2228)
    @Test func statusMapping() async throws {
        let body = Data(Self.kBody.utf8)
        let final: [(Int, WxError.Code)] = [                                   // test-http.c:2193-2203
            (404, .notFound), (429, .rateLimited), (400, .http), (401, .http), (403, .http), (410, .http),
            (422, .http), (301, .http), (302, .http), (307, .http),
        ]
        for (status, code) in final {
            try await Self.expectFailure(.respond(status: status, body: body), code, requests: 1, "\(status)")
        }
        try await Self.expectFailure(.respond(status: 304), .http, requests: 1, "304 without IMS")  // :2203
        try await Self.expectFailure(                                                              // :2204-2207
            .rawText("HTTP/1.1 600 X\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"), .http, requests: 1, "600")
        try await Self.expectFailure(
            .rawText("HTTP/1.1 999 X\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"), .http, requests: 1, "999")
        for status in [500, 503, 599] {                                                            // :2209-2211
            try await Self.expectFailure(.respond(status: status, body: body), .http, requests: Self.retried, "\(status)")
        }
        try await Self.expectFailure(.close, .network, requests: Self.retried, "close")            // :2212
        for status in [200, 201, 202, 204, 206, 299] {                                             // :2214
            let server = try LoopbackServer([.respond(status: status, body: status == 204 ? Data() : body)])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let response = try await Self.fetch(http).get()
            #expect(response.status == status)
        }
    }

    /// GET /x with JSON_ACCEPT, reading the `answering` statuses as answers (U69; C has no such
    /// option).
    static func fetch(_ client: HTTPClient, answering: Set<Int>) async -> Outcome {
        do {
            return .success(try await client.get("/x", accept: jsonAccept, answering: answering))
        } catch {
            return .failure(error)
        }
    }

    // U69: a status the caller declares (get's `answering`; the alert sources' "not covered"
    // NWS 400 and Bright Sky 404) is an answer: its status and body come back after 1 request,
    // a declared 5xx too (never retried), a gzip body decoded on both gzip paths; the body is
    // bounded by the client's cap like a 2xx's: one byte over is PARSE x1 (declared
    // Content-Length or streamed), the cap itself passes.
    @Test func declaredStatusIsAnsweredWithItsBody() async throws {
        let body = Data(Self.kBody.utf8)
        for status in [400, 404, 503] {
            let server = try LoopbackServer([.respond(status: status, body: body)])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let outcome = await Self.fetch(http, answering: [status])
            #expect((try? outcome.get()) == HTTPClient.Response(status: status, body: body, expiresS: 0, lastModified: nil),
                    "\(status): \(outcome)")
            _ = await server.waitForRequests(2, timeout: .milliseconds(200))
            #expect(server.requestCount == 1, "\(status)")
        }
        for coding in ["gzip", "identity, gzip"] {
            try await Self.expectDeclared(
                .raw(Self.framed(404, .contentLength, "Content-Encoding: \(coding)\r\n", Self.gzipJSON,
                                 sendLen: Self.gzipJSON.count, declared: Self.gzipJSON.count)),
                status: 404, bodyCount: Self.kGzipJson.utf8.count, "404 \(coding)")
        }
        let cap = HTTPPolicy.maxBodyBytes
        let spaces = [UInt8](repeating: 0x20, count: cap + 1)
        try await Self.expectDeclared(
            .raw(Self.framed(404, .contentLength, "", Array("{}".utf8), sendLen: 2, declared: cap + 1)),
            status: 404, bodyCount: nil, "declared cap + 1")
        try await Self.expectDeclared(
            .raw(Self.framed(404, .close, "", spaces, sendLen: cap + 1, declared: 0)), status: 404, bodyCount: nil,
            "streamed cap + 1")
        try await Self.expectDeclared(
            .respond(status: 404, body: Data(spaces.prefix(cap))), status: 404, bodyCount: cap, "the cap")
    }

    /// Serves `step` to a client answering `status`: expects that status with a body of
    /// `bodyCount` bytes, or (nil) PARSE "response too large", after 1 request.
    static func expectDeclared(
        _ step: LoopbackServer.Step, status: Int, bodyCount: Int?, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let server = try LoopbackServer([step])
        defer { server.stop() }
        let http = try client(server, timeoutMs: 30000, backoffMs: 5)
        let outcome = await fetch(http, answering: [status])
        _ = await server.waitForRequests(1, timeout: .seconds(1))
        if let bodyCount {
            let response = try? outcome.get()
            #expect(response?.status == status && response?.body.count == bodyCount, "\(label): \(outcome)",
                    sourceLocation: sourceLocation)
        } else {
            #expect(wxError(outcome) == WxError(.parse, HTTPPolicy.Message.responseTooLarge), "\(label): \(outcome)",
                    sourceLocation: sourceLocation)
        }
        #expect(server.requestCount == 1, "\(label): requests", sourceLocation: sourceLocation)
    }

    // U69: a declared status's body is held to the 2xx's framing. A body cut short (Content-Length
    // 100, 10 bytes sent, then close; Content-Length 50, 2 bytes sent on a kept-alive connection,
    // then close; chunked, cut inside a chunk) is NETWORK "the connection was lost" after
    // 1 + maxRetries requests for a 200 (CFNetwork's -1005), and the same error after the same
    // requests for a declared 400, 404 or 503, never the bytes before the cut as the answer
    // (CFNetwork completes a cut Content-Length body of those without an error; the transfer
    // reads the cut from the wire count).
    @Test func declaredStatusCutBodyFailsLikeA2xx() async throws {
        let lost = WxError(.network, "network error: the connection was lost (NSURLErrorDomain -1005)")
        let body = Data(repeating: 0x41, count: 100)
        let head = { (status: Int, framing: String) in
            "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n\(framing)\r\n"
        }
        // A gzip member cut half way under its Content-Length, as gzip and as "identity, gzip": the
        // cut rule comes before every coding rule (U69 iteration-2 handoff), so a declared status
        // reads like the 200 (the connection was lost), never "compressed body ended before its
        // end marker".
        let gz = LoopbackServer.gzip(Data((#"{"detail":"# + String(repeating: "x", count: 400) + #""}"#).utf8))
        let gzipCut = { (status: Int, coding: String) -> LoopbackServer.Step in
            .raw(Data(head(status, "Content-Encoding: \(coding)\r\nContent-Length: \(gz.count)\r\nConnection: close\r\n").utf8)
                 + gz.prefix(gz.count / 2))
        }
        let shapes: [(label: String, step: (Int) -> LoopbackServer.Step)] = [
            ("Content-Length 100, 10 sent, close", { .truncated(status: $0, body: body, sent: 10) }),
            ("Content-Length 50, 2 sent, kept alive", { .rawText(head($0, "Content-Length: 50\r\n") + "{}") }),
            ("chunked, cut inside a chunk", {
                .rawText(head($0, "Transfer-Encoding: chunked\r\nConnection: close\r\n") + "32\r\n{\"a\"")
            }),
            ("gzip, Content-Length, half the member sent, close", { gzipCut($0, "gzip") }),
            ("identity, gzip, Content-Length, half the member sent, close", { gzipCut($0, "identity, gzip") }),
        ]
        for (label, step) in shapes {
            let (twoxx, twoxxRequests) = try await Self.served(step(200), answering: [])
            #expect(Self.wxError(twoxx) == lost && twoxxRequests == Self.retried, "200, \(label): \(twoxx) x\(twoxxRequests)")
            for status in [400, 404, 503] {
                let (outcome, requests) = try await Self.served(step(status), answering: [status])
                #expect(Self.wxError(outcome) == Self.wxError(twoxx) && requests == twoxxRequests,
                        "declared \(status), \(label): \(outcome) x\(requests)")
            }
        }
        // NEW U13-N17 platform row (DECISIONS #57), declared: CFNetwork completes a 401's chunked
        // body cut inside a chunk without an error and no count measures that cut
        // (bodyFirstStatusOutcomes), so a declared 401 is answered with the bytes before the cut
        // after 1 request (a 200: NETWORK x3, above).
        let (outcome, requests) = try await Self.served(shapes[2].step(401), answering: [401])
        #expect((try? outcome.get()) == HTTPClient.Response(status: 401, body: Data(#"{"a""#.utf8), expiresS: 0, lastModified: nil)
                    && requests == 1, "declared 401, chunked, cut inside a chunk: \(outcome) x\(requests)")
    }

    /// GET /x answering `answering`, from a server serving `step` to every request (back-off
    /// 5 ms): the outcome and the requests made.
    static func served(_ step: LoopbackServer.Step, answering: Set<Int>) async throws -> (Outcome, Int) {
        let server = try LoopbackServer([step])
        defer { server.stop() }
        let http = try client(server, timeoutMs: 2000, backoffMs: 5)
        let outcome = await fetch(http, answering: answering)
        _ = await server.waitForRequests(retried, timeout: .milliseconds(300))
        return (outcome, server.requestCount)
    }

    // U69: a declaration covers only its own statuses. Every other status keeps C's outcome for
    // that caller: its error, retried as C retries it (400 HTTP x1 for a caller answering 404,
    // 404 NOT_FOUND x1 for one answering 400, 429 RATE_LIMITED x1, 401 HTTP x1, 503 HTTP x3).
    @Test func undeclaredStatusIsStillThrown() async throws {
        let body = Data(Self.kBody.utf8)
        let cases: [(status: Int, answering: Set<Int>, requests: Int)] = [
            (400, [404], 1), (404, [400], 1), (429, [400, 404], 1), (401, [404], 1), (503, [400, 404], Self.retried),
        ]
        for (status, answering, requests) in cases {
            let server = try LoopbackServer([.respond(status: status, body: body)])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let outcome = await Self.fetch(http, answering: answering)
            _ = await server.waitForRequests(requests, timeout: .seconds(1))
            #expect(Self.wxError(outcome) == HTTPPolicy.statusError(status), "\(status) answering \(answering): \(outcome)")
            #expect(server.requestCount == requests, "\(status) answering \(answering): requests")
        }
    }

    // C: /http/net/redirects-not-followed (test-http.c:2231-2253)
    @Test func redirectIsNeverFollowed() async throws {
        let other = try LoopbackServer([.text(Self.kBody)])
        defer { other.stop() }
        let location = "Location: http://127.0.0.1:\(other.port)/stolen"
        for status in [301, 302, 303, 307, 308] {                                   // test-http.c:2236
            let server = try LoopbackServer([.respond(status: status, headers: [location])])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let outcome = await Self.fetch(http)
            #expect(Self.wxError(outcome)?.code == .http, "\(status): \(outcome)")
            #expect(server.requestCount == 1)
        }
        #expect(other.requestCount == 0)                                           // test-http.c:2251
    }

    // C: /http/net/retry-backoff (test-http.c:2256-2275) with a CHANGED C script. C fails the
    // second attempt with STEP_CLOSE (:2258); CFNetwork re-sends such a request by itself, at
    // once, inside the same attempt (DECISIONS #34 item 1; C's own script is run unchanged by
    // closedConnectionIsResentWithinTheAttempt), which would skip the second back-off. Here the
    // second attempt fails with a body cut short of its Content-Length instead (also
    // WX_ERROR_NETWORK, /http/net/truncated-body, test-http.c:2361-2370), so the C assertions
    // on requests and timing can be checked: 3 requests, 100 ms then 200 ms of back-off.
    @Test func retryThenSuccessWithBackoff() async throws {
        let cut = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{\"data\":"
        let server = try LoopbackServer([.respond(status: 503, body: Data(Self.kBody.utf8)), .rawText(cut), .text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 100)       // 100 ms, then 200 ms
        let begin = ContinuousClock.now
        let outcome = await Self.fetch(http)
        let elapsed = Self.milliseconds(ContinuousClock.now - begin)
        #expect(Self.body(outcome) == Data(Self.kBody.utf8), "\(outcome)")
        #expect(server.requestCount == 3)                                          // test-http.c:2268
        #expect(elapsed >= 295)                                                    // test-http.c:2269
        let arrivals = server.requests.map(\.arrival)
        try #require(arrivals.count == 3)
        #expect(Self.milliseconds(arrivals[1] - arrivals[0]) >= 95)                // test-http.c:2271
        #expect(Self.milliseconds(arrivals[2] - arrivals[1]) >= 195)               // test-http.c:2272
    }

    // C: /http/net/retry-backoff with C's own script (503, STEP_CLOSE, 200; test-http.c:2258-
    // 2259): success after 3 requests (:2268) in 2 client attempts. DECISIONS #34 item 1: the
    // request after STEP_CLOSE is CFNetwork's own re-send inside the second attempt, so the 200
    // arrives without the second back-off (C's timing literals :2269 and :2271-2272 do not hold
    // for this script; see retryThenSuccessWithBackoff).
    @Test func closedConnectionIsResentWithinTheAttempt() async throws {
        let server = try LoopbackServer([.respond(status: 503, body: Data(Self.kBody.utf8)), .close, .text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 100)
        let outcome = await Self.fetch(http)
        #expect(Self.body(outcome) == Data(Self.kBody.utf8), "\(outcome)")
        #expect(server.requestCount == 3)                                          // test-http.c:2268
        #expect(http.finishedAttemptCount == 2)
    }

    // C: at most 1 + WX_HTTP_MAX_RETRIES = 3 client attempts per operation, with back-off
    // between them (src/net/wx-http.h:31-35; test-http.c:2209, :2212, :2268). CFNetwork re-sends
    // a request whose connection closed before any response byte at once, inside ONE task (3
    // requests per task on HTTP/1.1; 9 on h2, probe only, not testable on loopback), and no
    // public setting changes that. In every probe each re-send was one entry of the task's
    // URLSessionTaskMetrics.transactionMetrics (the count equalled the server's request count
    // for every task, a deadline-cancelled one included, on http/1.1, https/1.1 and h2) and the
    // metrics arrived before the task completed: observed behaviour, not an Apple guarantee.
    // The client charges them against the budget: C's attempt number is "wire requests so far
    // - 1", so no attempt starts once 3 requests were made, the outcome is the last request's,
    // and after an attempt that held a re-send the next back-off is 2B, not B. The 3-attempt
    // bound holds whatever the metrics say.
    // (A) What the charging keeps at C's outcome (without it: 9 requests for [close], and a
    // success after 4 requests for [close, close, close, 200]).
    // (B) DECISIONS #34 item 1 platform rows: the charging cannot stop the re-sends of a task
    // already running, so a re-send series inside a LATER attempt makes 4-5 wire requests per
    // operation (C: 3), with no back-off between the re-sends.
    @Test func resendsAreChargedAgainstTheRequestBudget() async throws {
        let r503 = LoopbackServer.Step.respond(status: 503, body: Data(Self.kBody.utf8))
        let ok = LoopbackServer.Step.text(Self.kBody)
        let cases: [([LoopbackServer.Step], WxError.Code?, Int, Int, String)] = [
            // (A)
            ([.close], .network, 3, 1, "[close]"),                                          // test-http.c:2212
            ([.close, .close, ok], nil, 3, 1, "[close, close, 200]"),
            ([.close, .close, .close, ok], .network, 3, 1, "[close, close, close, 200]"),
            ([r503, r503, r503, ok], .http, 3, 3, "[503, 503, 503, 200]"),                  // test-http.c:2209
            // (B) DECISIONS #34 item 1 platform rows (C: 3 requests, test-http.c:2209, :2212)
            ([r503, .close], .network, 4, 2, "DECISIONS #34 item 1 platform row [503, close]"),
            ([r503, r503, .close], .network, 5, 3, "DECISIONS #34 item 1 platform row [503, 503, close]"),
            ([.hang, .close], .network, 4, 2, "DECISIONS #34 item 1 platform row [hang, close]"),
        ]
        for (steps, code, requests, attempts, label) in cases {
            let server = try LoopbackServer(steps)
            defer { server.stop() }
            // The 503s are decided at once; a 1 s back-off keeps the re-send check below clear of
            // loopback delays (DECISIONS #76).
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 1000)
            let outcome = await Self.fetch(http)
            if let code {
                #expect(Self.wxError(outcome)?.code == code, "\(label): \(outcome)")
            } else {
                #expect(Self.body(outcome) == Data(Self.kBody.utf8), "\(label): \(outcome)")
            }
            #expect(server.requestCount == requests, "\(label): requests")
            #expect(http.finishedAttemptCount == attempts, "\(label): attempts")
            // The re-sends of one task follow each other without the back-off (1000 ms << attempt):
            // the last three requests come less than one back-off apart (a platform-row bound).
            let arrivals = server.requests.map(\.arrival)
            if requests > 3 && arrivals.count == requests {
                let last = Self.milliseconds(arrivals[requests - 1] - arrivals[requests - 3])
                #expect(last < 1000, "\(label): the last three requests \(last) ms apart")
            }
        }
    }

    // C: /http/net/backoff-doubles (test-http.c:2278-2293)
    @Test func backoffDoublesAndFailureIsFinal() async throws {
        let server = try LoopbackServer([.respond(status: 502, body: Data(Self.kBody.utf8))])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 80)
        let begin = ContinuousClock.now
        let outcome = await Self.fetch(http)
        let elapsed = Self.milliseconds(ContinuousClock.now - begin)
        #expect(Self.wxError(outcome)?.code == .http)
        #expect(server.requestCount == 3)
        #expect(elapsed >= 235)                                                    // test-http.c:2289
        #expect(elapsed < 2000)                                                    // test-http.c:2290
    }

    // C: /http/net/refused (test-http.c:2296-2311)
    @Test func connectionRefusedIsNetworkError() async throws {
        let server = try LoopbackServer([.text(Self.kBody)])
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        server.stop()  // connections are refused
        let outcome = await Self.fetch(http)
        #expect(Self.wxError(outcome)?.code == .network, "\(outcome)")
        #expect(server.requestCount == 0)
    }

    // MARK: Deadlines

    // C: /http/net/per-attempt-timeout (test-http.c:2314-2330)
    @Test func perAttemptTimeout() async throws {
        let server = try LoopbackServer([.hang])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 150, backoffMs: 5)
        let begin = ContinuousClock.now
        let outcome = await Self.fetch(http)
        let elapsed = Self.milliseconds(ContinuousClock.now - begin)
        let error = try #require(Self.wxError(outcome))
        #expect(error.code == .timeout)
        #expect(error.message == HTTPPolicy.Message.requestTimedOut)
        _ = await server.waitForRequests(Self.retried, timeout: .seconds(1))  // the last request may still be on its way into the log
        #expect(server.requestCount == Self.retried)
        #expect(elapsed >= 3 * 140)                                                // test-http.c:2326
        #expect(elapsed < 3000)                                                    // test-http.c:2327
    }

    // C: /http/net/timeout-covers-body (test-http.c:4049-4054): the head and part of the
    // body arrive, then silence; the per-attempt deadline covers the body.
    @Test func timeoutCoversBody() async throws {
        let response = Self.framed(200, .contentLength, "", Array(#"{"a":"#.utf8), sendLen: 5, declared: 100)
        // On a ManualClock (expectHeld): each deadline is played once the head and part of the body have
        // been sent (DECISIONS #66).
        try await Self.expectHeld(response, code: .timeout, requests: Self.retried, atDeadline: true, "timeout covers the body")
    }

    // C: /http/net/timeout-covers-body - DEADLINES criterion: a body drip-fed one byte every
    // 40 ms (far below any idle threshold) that needs longer than the per-attempt deadline
    // in total fails with TIMEOUT; the same drip within the deadline succeeds (control).
    @Test func dripFedBodyIsBoundedByTheAttemptDeadline() async throws {
        let payload = Array(Self.kBody.utf8)                                       // test-http.c:1960
        let raw = Self.framed(200, .contentLength, "", payload, sendLen: payload.count, declared: payload.count)
        let headLength = raw.count - payload.count
        let cuts = Array(headLength..<raw.count)
        // 34 pieces x 40 ms = 1.36 s of drip against a 400 ms attempt deadline.
        try await Self.expectCase(
            .bytesSplit(raw, at: cuts, interval: .milliseconds(40)), code: .timeout, requests: Self.retried,
            timeoutMs: 400, messageContains: HTTPPolicy.Message.requestTimedOut)
        // Control: the same drip with a 5 s deadline is a complete body.
        try await Self.expectCase(
            .bytesSplit(raw, at: cuts, interval: .milliseconds(40)), code: nil, requests: 1,
            okBody: Data(payload), timeoutMs: 5000)
    }

    // C: /http/deadline/total (test-http.c:5037-5092) with the real 45 s
    // WX_HTTP_TOTAL_DEADLINE_MS on a ManualClock: (a) an attempt that never finishes,
    // (b) a back-off longer than the deadline, (c) a request queued behind the pacing gap,
    // (d) 20 s + 1 s + 20 s + 2 s then the deadline, (e) a cancel long before it, and (f) case
    // (a) on a client made by the PUBLIC initialiser (the production 45 s). Each case first
    // stops at C's lower bound 45 s - 300 ms (test-http.c:5073), where the operation must
    // still be running with no further request or attempt, then crosses the deadline.
    @Test func totalDeadlineOnTheInjectedClock() async throws {
        let loMs = HTTPPolicy.totalDeadlineMs - 300                                  // test-http.c:5073
        let lo = Int64(loMs) * 1000
        let hi = Int64(HTTPPolicy.totalDeadlineMs + 2500) * 1000                     // test-http.c:5073
        func expectDeadline(_ outcome: Outcome?, _ clock: ManualClock, _ label: String) {
            guard let outcome else { return }  // Self.outcome(of:) recorded the issue
            let error = Self.wxError(outcome)
            #expect(error?.code == .timeout, "\(label): \(outcome)")
            #expect(error?.message == HTTPPolicy.Message.deadlineExceeded, "\(label)")
            #expect((lo...hi).contains(clock.monotonicMicroseconds), "\(label): \(clock.monotonicMicroseconds) us")
        }
        /// Moves the clock to `atUs` (just before the deadline): nothing may end there.
        func expectStillRunning(_ http: HTTPClient, _ server: LoopbackServer, _ clock: ManualClock, at atUs: Int64,
                                _ label: String) async {
            let requests = server.requestCount
            let attempts = http.finishedAttemptCount
            await clock.advance(by: atUs - clock.monotonicMicroseconds)
            #expect(clock.monotonicMicroseconds == lo, "\(label)")
            let ended = await Self.waitUntil(timeout: .milliseconds(300)) { http.outstandingCount == 0 }
            #expect(!ended, "\(label): the operation ended before 45 s - 300 ms")
            #expect(server.requestCount == requests, "\(label): a request after 45 s - 300 ms")
            #expect(http.finishedAttemptCount == attempts, "\(label): an attempt ended at 45 s - 300 ms")
        }
        // (a)
        do {
            let server = try LoopbackServer([.hang])
            defer { server.stop() }
            let clock = ManualClock()
            let http = try Self.client(server, timeoutMs: 600_000, backoffMs: 5, clock: clock)
            let task = Self.start(http)
            #expect(await server.waitForRequests(1))
            await clock.waitForSleepers(1)
            await expectStillRunning(http, server, clock, at: lo, "(a)")
            await clock.advance(by: Int64(HTTPPolicy.totalDeadlineMs) * 1000 - lo)
            expectDeadline(await Self.outcome(of: task), clock, "(a)")
            #expect(server.requestCount == 1)                                       // test-http.c:5065
        }
        // (b)
        do {
            let server = try LoopbackServer([.respond(status: 503, body: Data(Self.kBody.utf8))])
            defer { server.stop() }
            let clock = ManualClock()
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 600_000, clock: clock)
            let task = Self.start(http)
            #expect(await Self.waitUntil { http.finishedAttemptCount == 1 })
            await clock.waitForSleepers(1)
            await expectStillRunning(http, server, clock, at: lo, "(b)")
            await clock.advance(by: Int64(HTTPPolicy.totalDeadlineMs) * 1000 - lo)
            let outcome = await Self.outcome(of: task)
            expectDeadline(outcome, clock, "(b)")
            #expect(outcome.flatMap(Self.wxError).map { !$0.message.contains("SENTINEL") } == true)
            #expect(server.requestCount == 1)                                       // test-http.c:5067
        }
        // (c)
        do {
            let server = try LoopbackServer([.text(Self.kBody)])
            defer { server.stop() }
            let clock = ManualClock()
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5, gapMs: 600_000, clock: clock)
            #expect(Self.body(await Self.fetch(http, "/x")) == Data(Self.kBody.utf8))  // test-http.c:5068
            let task = Self.start(http, "/y")
            await clock.waitForSleepers(1)
            await expectStillRunning(http, server, clock, at: lo, "(c)")
            await clock.advance(by: Int64(HTTPPolicy.totalDeadlineMs) * 1000 - lo)
            expectDeadline(await Self.outcome(of: task), clock, "(c)")
            #expect(server.requestCount == 1)                                       // test-http.c:5070
        }
        // (d)
        do {
            let server = try LoopbackServer([.hang])
            defer { server.stop() }
            let clock = ManualClock()
            let http = try Self.client(server, timeoutMs: 20_000, backoffMs: 1000, clock: clock)
            let task = Self.start(http)
            for index in 1...2 {
                #expect(await server.waitForRequests(index), "(d) request \(index)")
                await clock.waitForSleepers(1)  // the attempt's deadline
                await clock.advance(by: 20_000 * 1000)
                #expect(await Self.waitUntil { http.finishedAttemptCount == index })
                await clock.waitForSleepers(1)  // the back-off: 1 s, then 2 s
                await clock.advance(by: Int64(HTTPPolicy.backoffBaseMs << (index - 1)) * 1000)
            }
            // Attempt 3 starts at 43 s and meets the 45 s deadline before its own 20 s.
            #expect(await server.waitForRequests(3), "(d) request 3")
            await clock.waitForSleepers(1)
            await expectStillRunning(http, server, clock, at: lo, "(d)")
            await clock.advance(by: Int64(HTTPPolicy.totalDeadlineMs) * 1000 - lo)
            expectDeadline(await Self.outcome(of: task), clock, "(d)")
            #expect(server.requestCount == 3)                                       // test-http.c:5072
        }
        // (e) control: the user cancels long before the deadline.
        do {
            let server = try LoopbackServer([.hang])
            defer { server.stop() }
            let clock = ManualClock()
            let http = try Self.client(server, timeoutMs: 600_000, backoffMs: 5, clock: clock)
            let task = Self.start(http)
            #expect(await server.waitForRequests(1))
            task.cancel()
            #expect(await Self.outcome(of: task).map(Self.isCancelled) == true)
            #expect(clock.monotonicMicroseconds == 0)
        }
        // (f) case (a) through the public initialiser: its whole-operation deadline is the
        // production WX_HTTP_TOTAL_DEADLINE_MS, not a test injection.
        do {
            let server = try LoopbackServer([.hang])
            defer { server.stop() }
            let clock = ManualClock()
            let http = try HTTPClient(baseURL: "http://127.0.0.1:\(server.port)", userAgent: Self.ua, timeoutMs: 600_000,
                                      backoffBaseMs: 5, minGapMs: 0, clock: clock)
            let task = Self.start(http)
            #expect(await server.waitForRequests(1))
            await clock.waitForSleepers(1)
            await expectStillRunning(http, server, clock, at: lo, "(f)")
            await clock.advance(by: Int64(HTTPPolicy.totalDeadlineMs) * 1000 - lo)
            expectDeadline(await Self.outcome(of: task), clock, "(f)")
            #expect(server.requestCount == 1)
        }
    }

    // C: /http/deadline/total with an injected short whole-operation deadline on the
    // system clock (DEADLINES criterion): 700 ms instead of 45 s, cases (a), (b) and (d).
    @Test func totalDeadlineInjectedShort() async throws {
        let deadline = 700
        let lo = Int64(deadline - 300), hi = Int64(deadline + 2500)                 // test-http.c:5073 slack
        func run(_ step: LoopbackServer.Step, timeoutMs: Int, backoffMs: Int, requests: Int, _ label: String) async throws {
            let server = try LoopbackServer([step])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: timeoutMs, backoffMs: backoffMs, totalDeadlineMs: deadline)
            let begin = ContinuousClock.now
            // Bounded like the ManualClock cases: a deadline that never fires fails here, not at the
            // suite's time limit (which needs an xctest runner restart).
            guard let outcome = await Self.outcome(of: Task { await Self.fetch(http) }) else { return }
            let elapsed = Self.milliseconds(ContinuousClock.now - begin)
            let error = Self.wxError(outcome)
            #expect(error?.code == .timeout, "\(label): \(outcome)")
            #expect(error?.message == HTTPPolicy.Message.deadlineExceeded, "\(label)")
            #expect(elapsed >= lo && elapsed <= hi, "\(label): \(elapsed) ms")
            #expect(elapsed >= Int64(deadline) - 20, "\(label): ended before the deadline: \(elapsed) ms")
            #expect(server.requestCount == requests, "\(label)")
        }
        try await run(.hang, timeoutMs: 600_000, backoffMs: 5, requests: 1, "(a)")
        try await run(.respond(status: 503, body: Data(Self.kBody.utf8)), timeoutMs: 2000, backoffMs: 600_000, requests: 1, "(b)")
        // (d) 200 + 50 + 200 + 100 = 550 ms, then the third attempt meets the deadline.
        try await run(.hang, timeoutMs: 200, backoffMs: 50, requests: 3, "(d)")
    }

    /// A weak reference that can be read from a @Sendable polling closure.
    final class WeakClient: @unchecked Sendable {
        weak var client: HTTPClient?
    }

    /// The outcome of `task`, awaited for at most `limit` of real time: past it the task is
    /// cancelled, an issue is recorded and nil is returned, so a ManualClock deadline that never
    /// fires fails its test instead of holding the runner until the suite's time limit (the
    /// outcome is due at once once the clock has crossed the deadline; 5 s per case keeps the six
    /// cases of totalDeadlineOnTheInjectedClock inside the 60 s per-test limit).
    static func outcome(of task: Task<Outcome, Never>, within limit: Duration = .seconds(5),
                        sourceLocation: SourceLocation = #_sourceLocation) async -> Outcome? {
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await task.value; return true }
            group.addTask { try? await Task.sleep(for: limit); return false }
            let first = await group.next() ?? false
            if !first { task.cancel() }
            group.cancelAll()
            return first
        }
        guard finished else {
            Issue.record("no outcome within \(limit); the operation was cancelled", sourceLocation: sourceLocation)
            return nil
        }
        return await task.value
    }

    /// Polls `condition` every 5 ms for up to `timeout` (real time).
    static func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: Body cap

    // C: /http/net/body-cap (test-http.c:2333-2358)
    @Test func bodyCap() async throws {
        let cap = HTTPPolicy.maxBodyBytes
        try await Self.expectFailure(.bigDeclared(size: cap + 1), .parse, requests: 1, "declared cap+1")       // :2337
        try await Self.expectFailure(.bigDeclared(size: 50 * 1024 * 1024), .parse, requests: 1, "declared 50M") // :2338
        try await Self.expectFailure(.bigStreamed(size: cap + 1), .parse, requests: 1, "streamed cap+1")       // :2340
        try await Self.expectFailure(.bigStreamed(size: 5 * 1024 * 1024), .parse, requests: 1, "streamed 5M")  // :2341
        try await Self.expectFailure(                                                                           // :2342
            .respond(body: Data(repeating: 0x20, count: cap + 1)), .parse, requests: 1, "respond cap+1")
        for step in [LoopbackServer.Step.respond(body: Data(repeating: 0x20, count: cap)), .bigStreamed(size: cap)] {
            let server = try LoopbackServer([step])                                                            // :2344-2356
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 10000, backoffMs: 5)
            let response = try await Self.fetch(http).get()
            #expect(response.body.count == cap)
        }
    }

    // C: /http/net/body-cap-stops-reading (test-http.c:4884-4904)
    @Test func bodyCapStopsReading() async throws {
        let cap = HTTPPolicy.maxBodyBytes
        let offered = 512 * 1024 * 1024
        let server = try LoopbackServer([.bigStreamed(size: offered)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 20000, backoffMs: 5)
        let outcome = await Self.fetch(http)
        #expect(Self.wxError(outcome)?.code == .parse, "\(outcome)")
        #expect(server.requestCount == 1)
        try await Task.sleep(for: .milliseconds(300))
        let sent = server.bigStreamedBytesSent
        #expect(sent > cap)                                                         // test-http.c:4900
        #expect(sent < cap + 64 * 1024 * 1024)                                      // test-http.c:4901
        #expect(sent < offered / 4)                                                 // test-http.c:4902
    }

    // C: /http/net/truncated-body (test-http.c:2361-2370)
    @Test func truncatedBody() async throws {
        let validPrefix = "HTTP/1.1 200 OK\r\nContent-Length: 536\r\nConnection: close\r\n\r\n{\"data\":null,\"status\":{\"rCode\":200}}"
        let cutJSON = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{\"data\":"
        for raw in [validPrefix, cutJSON] {
            try await Self.expectFailure(.rawText(raw), .network, requests: Self.retried, raw)
        }
    }

    // MARK: Validators

    // C: /http/net/if-modified-since-304 (test-http.c:4471-4514)
    @Test func ifModifiedSinceAnd304() async throws {
        let server = try LoopbackServer([.text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        _ = try await Self.fetch(http, "/a").get()
        #expect(server.requests[0].head.contains("If-Modified-Since") == false)     // test-http.c:4482
        let second = try await Self.fetch(http, "/b", ims: Self.imsValue).get()
        #expect(server.requests[1].head.contains("If-Modified-Since: Sun, 06 Nov 1994 08:49:37 GMT\r\n"))  // :4488
        #expect(second.status == 200)

        let now = SystemClock().wallSeconds
        let expires = "Expires: " + Self.httpDate(now + 3600)
        let notModified = try LoopbackServer([.respond(status: 304, headers: [expires, "Last-Modified: Mon, 07 Nov 1994 08:49:37 GMT"])])
        defer { notModified.stop() }
        let http2 = try Self.client(notModified, timeoutMs: 2000, backoffMs: 5)
        let response = try await Self.fetch(http2, "/c", ims: Self.imsValue).get()
        #expect(response.status == 304)                                             // test-http.c:4505
        #expect(response.body.isEmpty)
        #expect(response.expiresS >= now + 3600 - 2)                                // test-http.c:4508
        #expect(response.expiresS <= now + 3600 + 2)
        #expect(response.lastModified == "Mon, 07 Nov 1994 08:49:37 GMT")           // test-http.c:4510
        #expect(notModified.requestCount == 1)
    }

    /// "%a, %d %b %Y %H:%M:%S GMT" of a UTC instant (the C tests' g_date_time_format).
    static func httpDate(_ seconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    // C: /http/net/expires-last-modified (test-http.c:4517-4615)
    @Test func expiresAndLastModifiedHeaders() async throws {
        let now = SystemClock().wallSeconds
        let expiresCases: [(Int64?, Bool)] = [                                       // test-http.c:4524-4525
            (3600, true), (60, true), (86400 - 120, true), (86400 + 120, false), (-3600, false), (-1, false),
            (100 * 86400, false), (nil, false), (Int64.max, false),
        ]
        for (offset, valid) in expiresCases {
            var headers: [String] = []
            if let offset {
                headers = [offset == Int64.max ? "Expires: not a date" : "Expires: " + Self.httpDate(now + offset)]
            }
            let server = try LoopbackServer([.respond(headers: headers, body: Data(Self.kBody.utf8))])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let response = try await Self.fetch(http).get()
            if valid, let offset {
                #expect(response.expiresS >= now + offset - 2, "\(offset)")
                #expect(response.expiresS <= now + offset + 2, "\(offset)")
            } else {
                #expect(response.expiresS == 0, "\(String(describing: offset))")
            }
        }
        let lm64 = String(repeating: "a", count: HTTPPolicy.validatorMax)
        let lm65 = String(repeating: "a", count: HTTPPolicy.validatorMax + 1)
        let lmCases: [(String?, String?)] = [                                        // test-http.c:4561-4569
            (nil, nil), ("Sun, 06 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 08:49:37 GMT"), ("x", "x"), ("", nil),
            ("caf\u{E9}", nil), ("a\u{01}b", nil), ("a\u{7F}b", nil), (lm64, lm64), (lm65, nil),
        ]
        for (value, expected) in lmCases {
            let headers = value.map { ["Last-Modified: \($0)"] } ?? []
            let server = try LoopbackServer([.respond(headers: headers, body: Data(Self.kBody.utf8))])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let response = try await Self.fetch(http).get()
            #expect(response.lastModified == expected, "\(String(describing: value?.debugDescription))")
        }
        // Duplicate headers must not confuse the parsing (test-http.c:4599-4613).
        // C: g_assert_true(o.response->last_modified == NULL || g_str_equal(o.response->last_modified, "a") ||
        //                  g_str_equal(o.response->last_modified, "b"));  (test-http.c:4611-4612: C accepts NULL, "a" or "b")
        // NEW U13-N9 platform row (DECISIONS #40, rule (b), which trades this C literal): URLSession joins
        // the two lines and a value not made only of HTTP dates is kept as it came, "a, b".
        let e1 = "Expires: " + Self.httpDate(now + 600)
        let server = try LoopbackServer([.respond(headers: [e1, e1, "Last-Modified: a", "Last-Modified: b"], body: Data(Self.kBody.utf8))])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        let response = try await Self.fetch(http).get()
        #expect(response.lastModified == "a, b",
                "NEW U13-N9 platform row (test-http.c:4611-4612; C: NULL, \"a\" or \"b\"): \(String(describing: response.lastModified))")
        #expect(response.expiresS >= now + 600 - 2 && response.expiresS <= now + 600 + 2)  // two equal date lines, test-http.c:4601-4602
    }

    // C: /http/net/expires-last-modified, repeated lines that are HTTP dates. C reads the LAST
    // line of each (wx-http.h:205-208; record_validators, wx-http.c:1403-1407, through
    // soup_message_headers_get_one). URLSession joins repeated lines with ", "; the client
    // recovers the last date from the joined value, so it is never sent back as a joined
    // If-Modified-Since.
    @Test func repeatedDateValidatorsUseTheLastLine() async throws {
        let now = SystemClock().wallSeconds
        let lm1 = "Sun, 06 Nov 1994 08:49:37 GMT", lm2 = "Mon, 07 Nov 1994 08:49:37 GMT"   // test-http.c:2834, :4510
        let asctime1 = "Sun Nov  6 08:49:37 1994", asctime2 = "Mon Nov  7 08:49:37 1994"
        let cases: [([String], String?, Int64?)] = [
            (["Last-Modified: \(lm1)", "Last-Modified: \(lm2)", "Expires: " + Self.httpDate(now + 600),
              "Expires: " + Self.httpDate(now + 1200)], lm2, 1200),
            (["Last-Modified: \(lm2)", "Last-Modified: \(lm2)", "Last-Modified: \(lm1)",
              "Expires: " + Self.httpDate(now + 1200), "Expires: " + Self.httpDate(now + 600),
              "Expires: " + Self.httpDate(now + 900)], lm1, 900),
            (["Last-Modified: \(asctime1)", "Last-Modified: \(lm2)", "Expires: " + Self.httpDate(now - 60),
              "Expires: " + Self.httpDate(now + 600)], lm2, 600),
            (["Last-Modified: \(lm1)", "Last-Modified: \(asctime2)"], asctime2, nil),
            // The last line is not usable: C keeps nothing (0 / the last line only).
            (["Expires: " + Self.httpDate(now + 600), "Expires: " + Self.httpDate(now + 100 * 86400)], nil, 0),
        ]
        for (index, (headers, lastModified, expiresOffset)) in cases.enumerated() {
            let server = try LoopbackServer([.respond(headers: headers, body: Data(Self.kBody.utf8))])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let response = try await Self.fetch(http).get()
            #expect(response.lastModified == lastModified, "case \(index): \(String(describing: response.lastModified))")
            if let expiresOffset, expiresOffset > 0 {
                #expect(abs(response.expiresS - (now + expiresOffset)) <= 2, "case \(index): \(response.expiresS)")
            } else if expiresOffset == 0 {
                #expect(response.expiresS == 0, "case \(index): \(response.expiresS)")
            }
            // The recovered value goes back on the wire as one date, never the joined text.
            if let lastModified {
                _ = try await Self.fetch(http, ims: response.lastModified).get()
                #expect(server.requests.last?.headers("If-Modified-Since") == [lastModified], "case \(index)")
            }
        }
    }

    // C: /http/net/expires-last-modified (test-http.c:4517-4615) with record_validators
    // (src/net/wx-http.c:1400-1408): C reads ONE line of each, the last (libsoup
    // soup_message_headers_get_one; wx-http.h:205-209, :214-217), keeps a Last-Modified line
    // verbatim when it is printable ASCII of at most 64 bytes (C test "Last-Modified: x" -> "x",
    // :4564; a line is "sent back as it came", test-metno.c:4041-4056), and parses Expires with
    // libsoup's lenient date parser, which reads a date and ignores what follows it (U09
    // HTTPDate, a port of parse_textual_date). URLSession joins repeated lines with ", ";
    // HTTPClient.lastHeaderLine applies rule (b) of DECISIONS #40 (amending #36 N9): the last
    // item when the value is two or more items that are all HTTP dates, otherwise the value as it
    // came. NEW documented difference U13-N9 (platform rows below): once joined, one line cannot
    // be told from several, so repeated lines with a line that is not a date give the joined
    // value (C: the last line), and a single line made only of HTTP dates gives its last date
    // (C: the whole line).
    @Test func joinedValidatorValues() async throws {
        let now = SystemClock().wallSeconds
        let soon = Self.httpDate(now + 600)
        let lm1 = "Sun, 06 Nov 1994 08:49:37 GMT"                                     // test-http.c:2834
        func fetchHeaders(_ headers: [String]) async throws -> HTTPClient.Response {
            let server = try LoopbackServer([.respond(headers: headers, body: Data(Self.kBody.utf8))])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            return try await Self.fetch(http).get()
        }
        // C outcomes (record_validators on the last line; a single line kept as it came).
        let lastModifiedRows: [([String], String?)] = [
            (["Last-Modified: Mon, 1 Jan 2024"], "Mon, 1 Jan 2024"),                   // one line, kept verbatim
            (["Last-Modified: \(lm1), extra"], "\(lm1), extra"),                        // one line, kept verbatim
            (["Last-Modified: W/x"], "W/x"),
            (["Last-Modified: x, y"], "x, y"),                                            // one line, wx-http.c:1405-1407
        ]
        for (headers, expected) in lastModifiedRows {
            #expect(try await fetchHeaders(headers).lastModified == expected, "\(headers)")
        }
        let expiresRows: [([String], Int64)] = [
            (["Expires: \(soon), extra"], now + 600),                                     // one line: the date
            (["Expires: \(soon)", "Expires: \(soon)"], now + 600),                        // test-http.c:4601-4602
        ]
        for (headers, expected) in expiresRows {
            let expires = try await fetchHeaders(headers).expiresS
            #expect(abs(expires - expected) <= 2, "\(headers): \(expires)")
        }
        // NEW documented difference U13-N9 platform rows (DECISIONS #40, rule (b)): repeated lines
        // with a line that is not a date give the joined value; C takes the last line.
        let n9 = "NEW U13-N9 platform row (record_validators, wx-http.c:1403-1407; DECISIONS #40)"
        // C: g_assert_true(last_modified == NULL || "a" || "b") (test-http.c:4602, :4611-4612)
        #expect(try await fetchHeaders(["Last-Modified: a", "Last-Modified: b"]).lastModified == "a, b",
                "\(n9): lines 'a' + 'b' (C: NULL, 'a' or 'b')")
        // C: the last line, lm1
        #expect(try await fetchHeaders(["Last-Modified: x", "Last-Modified: \(lm1)"]).lastModified == "x, \(lm1)",
                "\(n9): lines 'x' + '<date>' (C: '<date>')")
        // C: the last line, "y"
        #expect(try await fetchHeaders(["Last-Modified: caf\u{E9}, x", "Last-Modified: y"]).lastModified == nil,
                "\(n9): lines 'caf\u{E9}, x' + 'y', joined value not ASCII (C: 'y')")
        // C: the last line, 'x'
        #expect(try await fetchHeaders(["Last-Modified: \(lm1)", "Last-Modified: x"]).lastModified == "\(lm1), x",
                "\(n9): lines '<date>' + 'x' (C: 'x')")
        // C: the last line, soon (wx_http_parse_expires, wx-http.c:1403-1404)
        for first in ["0", "not a date"] {
            let expires = try await fetchHeaders(["Expires: \(first)", "Expires: \(soon)"]).expiresS
            #expect(expires == 0, "\(n9): Expires lines '\(first)' + '<date>' (C: the date): \(expires)")
        }
        // C: 0, the last line "Mon" is not a date
        let joinedExpires = try await fetchHeaders(["Expires: \(soon)", "Expires: Mon"]).expiresS
        #expect(abs(joinedExpires - (now + 600)) <= 2, "\(n9): Expires lines '<date>' + 'Mon' (C: 0): \(joinedExpires)")
        // Residual: ONE line made only of HTTP dates joined by ", " gives its last date.
        // C: the whole line, "<lm1>, <lm2>" (60 bytes, printable ASCII, kept), and for Expires the
        // lenient parser's first date.
        let lm2 = "Mon, 07 Nov 1994 08:49:37 GMT"                                     // test-http.c:4510
        #expect(try await fetchHeaders(["Last-Modified: \(lm1), \(lm2)"]).lastModified == lm2,
                "\(n9): one line '<lm1>, <lm2>' (C: the whole line)")
        let later = Self.httpDate(now + 1200)
        let oneLineExpires = try await fetchHeaders(["Expires: \(soon), \(later)"]).expiresS
        #expect(abs(oneLineExpires - (now + 1200)) <= 2, "\(n9): one Expires line '<soon>, <later>' (C: soon): \(oneLineExpires)")
    }

    // MARK: Host pinning

    /// normalise_target (test-http.c:4620-4659), the C test's oracle: RFC 3986 5.2.4
    /// remove_dot_segments on the path, query untouched; followed by the escape
    /// normalisation GLib's parser applies to an encoded path and query (glib/guri.c
    /// uri_decoder with just_normalize: an escape of an unreserved character is decoded,
    /// any other escape keeps its % and gets upper-case hex digits).
    static func normaliseTarget(_ target: [UInt8]) -> [UInt8] {
        let queryAt = target.firstIndex(of: UInt8(ascii: "?"))
        var input = Array(target[..<(queryAt ?? target.count)])
        var out: [UInt8] = []
        func starts(_ p: String) -> Bool { input.starts(with: Array(p.utf8)) }
        func equals(_ p: String) -> Bool { input == Array(p.utf8) }
        func dropLastSegment() {
            if let slash = out.lastIndex(of: UInt8(ascii: "/")) { out.removeSubrange(slash...) }
        }
        while !input.isEmpty {
            if starts("../") { input.removeFirst(3) }
            else if starts("./") { input.removeFirst(2) }
            else if starts("/./") { input.removeFirst(2) }
            else if equals("/.") { input = [UInt8(ascii: "/")] }
            else if starts("/../") { input.removeFirst(3); dropLastSegment() }
            else if equals("/..") { input = [UInt8(ascii: "/")]; dropLastSegment() }
            else if equals(".") || equals("..") { input.removeAll() }
            else {
                let from = input.first == UInt8(ascii: "/") ? 1 : 0
                let next = input[from...].firstIndex(of: UInt8(ascii: "/")) ?? input.count
                out += input[..<next]
                input.removeFirst(next)
            }
        }
        if let queryAt { out += target[queryAt...] }
        // GLib escape normalisation.
        var normalised: [UInt8] = []
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < out.count {
            if out[i] == UInt8(ascii: "%"), i + 2 < out.count, let h = hex(out[i + 1]), let l = hex(out[i + 2]) {
                let c = h << 4 | l
                let unreserved = (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0x30...0x39).contains(c)
                    || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || c == UInt8(ascii: "_") || c == UInt8(ascii: "~")
                if unreserved {
                    normalised.append(c)
                } else {
                    let upper = { (b: UInt8) in (0x61...0x7A).contains(b) ? b - 0x20 : b }
                    normalised += [UInt8(ascii: "%"), upper(out[i + 1]), upper(out[i + 2])]
                }
                i += 3
            } else {
                normalised.append(out[i])
                i += 1
            }
        }
        return normalised
    }

    // C: /http/net/host-pinning-fuzz (test-http.c:4662-4706), SeededRNG(seed: 11) in place
    // of g_rand_new_with_seed(11) (DECISIONS #10).
    @Test func hostPinningFuzz() async throws {
        let server = try LoopbackServer([.text("{}")])
        let other = try LoopbackServer([.text("{}")])
        defer { server.stop(); other.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        var rng = SeededRNG(seed: 11)
        let alphabet = Array("/?&=%@:.~-_+!$'()*,;[]{}|^\"<> \\#\t".utf8) + [0xC3, 0xA9] + Array("aZ09".utf8)  // :4669
        var sent = 0
        for i in 0..<600 {                                                           // test-http.c:4671
            let n = Int.random(in: 1..<14, using: &rng)
            var path: [UInt8] = [UInt8(ascii: "/")]
            for _ in 1..<n { path.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]) }
            let target = i % 7 == 0 ? Array("/@127.0.0.1:\(other.port)/x".utf8) : path
            let text = String(decoding: target, as: UTF8.self)
            let outcome = await Self.fetch(http, text)
            if !HTTPPolicy.isValidPath(bytes: target) {
                #expect(Self.wxError(outcome)?.code == .invalidArg, "\(text.debugDescription)")
            } else if case .failure(let error) = outcome {
                // Accepted by the validator but refused by the URI parser: a bad %-escape.
                #expect((error as? WxError)?.code == .invalidArg, "\(text.debugDescription): \(error)")
                #expect(target.contains(UInt8(ascii: "%")))
            } else {
                let expected = String(decoding: Self.normaliseTarget(target), as: UTF8.self)
                #expect(server.paths.count > sent && server.paths[sent] == expected,
                        "\(text.debugDescription) arrived as \(server.paths.last ?? "-") expected \(expected)")
                sent += 1
            }
        }
        #expect(server.requestCount == sent)                                         // test-http.c:4696
        #expect(sent > 100)                                                          // test-http.c:4697
        #expect(other.requestCount == 0)                                             // test-http.c:4698
        for request in server.requests {
            #expect(request.head.contains("\r\nHost: 127.0.0.1:\(server.port)\r\n"))  // test-http.c:4700
        }
    }

    // C: none (executor addition for the brief's PINNING rule; /http/net/host-pinning-fuzz is ported above).
    // C anchors: wx-http.h:15-21 (host pinning: a path-and-query can never change the
    // authority) and :225-228 (the path is validated and the origin is pinned).
    // Brief PINNING rule (U09 verifier finding): "/.//evil.com" normalises to "//evil.com"
    // (as in GLib); it must reach the pinned server as that path, never host evil.com.
    // Also the authority-looking targets of the fuzz alphabet.
    @Test func doubleSlashTargetStaysOnThePinnedOrigin() async throws {
        let server = try LoopbackServer([.text("{}")])
        let other = try LoopbackServer([.text("{}")])
        defer { server.stop(); other.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        let otherAuthority = "127.0.0.1:\(other.port)"
        let cases: [(String, String)] = [
            ("/.//evil.com", "//evil.com"),
            ("/.//evil.com/x?y=1", "//evil.com/x?y=1"),
            ("/./\(otherAuthority)/x", "/\(otherAuthority)/x"),
            ("/.//\(otherAuthority)/x", "//\(otherAuthority)/x"),
            ("/a/..//\(otherAuthority)/x", "//\(otherAuthority)/x"),
            ("/@\(otherAuthority)/x", "/@\(otherAuthority)/x"),
        ]
        for (index, (target, expected)) in cases.enumerated() {
            let outcome = await Self.fetch(http, target)
            #expect(Self.body(outcome) == Data("{}".utf8), "\(target): \(outcome)")
            #expect(server.paths.count == index + 1 && server.paths[index] == expected, "\(target) -> \(server.paths.last ?? "-")")
            #expect(server.requests.last?.header("Host") == "127.0.0.1:\(server.port)")
        }
        #expect(other.requestCount == 0)
    }

    // C: none (executor addition, the verify's derived case U13-RT16). C anchors: request_uri
    // (wx-http.c:2019-2041) joins the base URL and the path-and-query and parses it with
    // SOUP_HTTP_URI_FLAGS; the encoded path and query keep reserved escapes (%2C, %2F, %20, %3D,
    // %26, %3B, %2B) and separators ('?', '&', '=', ';', '+') as they are, upper-case the hex digits
    // and decode escapes of unreserved characters, and libsoup writes soup_uri_get_path_and_query on
    // the request line. Expected targets: GLib's g_uri_parse with those flags (the verifier's oracle
    // verify/U13-p7-v1/uri/oracle.c; its output for these inputs in work/fp3/rt-oracle.txt).
    @Test func reservedEscapesReachTheWireAsCWritesThem() async throws {
        let server = try LoopbackServer([.text("{}")])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        let cases: [(String, String)] = [
            ("/v1/x%2Cy%2Fz%20w?a=%2C&b=%20c%2F", "/v1/x%2Cy%2Fz%20w?a=%2C&b=%20c%2F"),
            ("/a%2fb%2c?q=%3D%26x", "/a%2Fb%2C?q=%3D%26x"),
            ("/%41%7e?x=%61", "/A~?x=a"),
            ("/p;a=1/b?x=1&y=2;z=%3B", "/p;a=1/b?x=1&y=2;z=%3B"),
            ("/sp%20ace?q=a%2Bb+c", "/sp%20ace?q=a%2Bb+c"),
        ]
        for (index, (target, expected)) in cases.enumerated() {
            let plan = try http.policy.plan(pathAndQuery: target, accept: Self.jsonAccept)
            #expect(plan.target == expected, "\(target): planned \(plan.target)")
            let outcome = await Self.fetch(http, target)
            #expect(Self.body(outcome) == Data("{}".utf8), "\(target): \(outcome)")
            #expect(server.paths.count == index + 1 && server.paths[index] == expected, "\(target) -> \(server.paths.last ?? "-")")
        }
    }

    // C: /http/net/base-url-normalisation (test-http.c:4710-4734)
    @Test func baseURLNormalisationOnTheWire() async throws {
        let server = try LoopbackServer([.text("{}")])
        defer { server.stop() }
        let forms = [("http://LOCALHOST:", ""), ("http://localhost:", "/"), ("HTTP://127.0.0.1:", ""),
                     ("http://%6C%6F%63alhost:", "")]                               // test-http.c:4717-4718
        for (index, (prefix, suffix)) in forms.enumerated() {
            let http = try HTTPClient(baseURL: "\(prefix)\(server.port)\(suffix)", userAgent: Self.ua, timeoutMs: 2000, backoffBaseMs: 5)
            _ = try await Self.fetch(http, "/n").get()
            let host = "\r\nHost: \(index == 2 ? "127.0.0.1" : "localhost"):\(server.port)\r\n"  // test-http.c:4731
            #expect(server.requests.count > index && server.requests[index].head.contains(host), "\(prefix)")
        }
    }

    // MARK: Admission

    // C: /http/net/inflight-cap (test-http.c:4299-4352)
    @Test func inflightCap() async throws {
        let server = try LoopbackServer([.hang])
        defer { server.stop() }
        let weakClient = WeakClient()
        do {
            let http = try Self.client(server, timeoutMs: 10000, backoffMs: 5)
            weakClient.client = http
            var tasks: [Task<Outcome, Never>] = []
            for _ in 0..<(HTTPPolicy.maxInflight - 1) { tasks.append(Self.start(http)) }
            #expect(await Self.waitUntil { http.outstandingCount == HTTPPolicy.maxInflight - 1 })
            // Invalid arguments are still reported as such (validation first).
            #expect(Self.wxError(await Self.fetch(http, "//bad"))?.code == .invalidArg)
            tasks.append(Self.start(http))                                         // one slot left: accepted
            #expect(await Self.waitUntil { http.outstandingCount == HTTPPolicy.maxInflight })
            let sentBefore = server.requestCount
            let begin = ContinuousClock.now
            let refused = await Self.fetch(http)
            let error = try #require(Self.wxError(refused))
            #expect(error.code == .rateLimited)
            #expect(error.message == "too many outstanding requests (limit 16)")    // wx-http.c:2065-2066
            #expect(Self.milliseconds(ContinuousClock.now - begin) < 1000)         // test-http.c:4329
            #expect(server.requestCount == sentBefore)                              // test-http.c:4331
            #expect(server.requestCount <= HTTPPolicy.maxInflight)                  // test-http.c:4332
            // A pre-cancelled caller at the cap gets CancellationError, not RATE_LIMITED (wx-http.c:2054, 2080).
            let cancelledAtCap = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await Self.fetch(http)
            }.value
            #expect(Self.isCancelled(cancelledAtCap))
            #expect(server.requestCount == sentBefore)
            for task in tasks { task.cancel() }
            for task in tasks { #expect(Self.isCancelled(await task.value)) }
            let again = Self.start(http)
            again.cancel()
            #expect(Self.isCancelled(await again.value))                            // not RATE_LIMITED
        }
        #expect(await Self.waitUntil { weakClient.client == nil })                  // released_within 2000
    }

    // MARK: Cancellation

    // C: /http/net/cancel-request (test-http.c:4057-4074)
    @Test func cancelDuringRequest() async throws {
        let server = try LoopbackServer([.hang])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 10000, backoffMs: 5)
        let begin = ContinuousClock.now
        let task = Self.start(http)
        // The cancel must land while the request is on the wire (test-http.c:4057-4074): wait for
        // the server to record it instead of a fixed real-time sleep (U28-F5; the .hang server
        // never answers, so the request stays on the wire for as long as the poll takes).
        #expect(await server.waitForRequests(1))
        task.cancel()
        let outcome = await task.value
        #expect(Self.isCancelled(outcome), "\(outcome)")
        #expect(server.requestCount == 1)
        #expect(Self.milliseconds(ContinuousClock.now - begin) < 2000)              // test-http.c:4071
    }

    // C: /http/net/cancel-backoff (test-http.c:4077-4094)
    @Test func cancelDuringBackoff() async throws {
        let server = try LoopbackServer([.respond(status: 503, body: Data(Self.kBody.utf8))])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 30000)     // would wait 30 s
        let begin = ContinuousClock.now
        let task = Self.start(http)
        // The cancel must land in the 30 s back-off, not on the wire: wait for the first attempt to
        // end (its 503 left the wire) instead of a fixed real-time sleep (U28-F6).
        #expect(await Self.waitUntil { http.finishedAttemptCount == 1 })
        task.cancel()
        let outcome = await task.value
        #expect(Self.isCancelled(outcome), "\(outcome)")
        #expect(server.requestCount == 1)
        #expect(Self.milliseconds(ContinuousClock.now - begin) < 3000)              // test-http.c:4091
    }

    // C: /http/net/pre-cancelled (test-http.c:4097-4113)
    @Test func preCancelled() async throws {
        let server = try LoopbackServer([.text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.fetch(http)
        }.value
        #expect(Self.isCancelled(outcome))
        #expect(server.requestCount == 0)
    }

    // C: /http/net/cancel-before-finish (test-http.c:4116-4133): the request reached the server
    // and its answer is on the way when the caller cancels; cancellation wins over the answer
    // (requests == 1, CANCELLED). The client also re-checks the caller's cancellation after
    // every attempt, before it returns any outcome; with async/await the window between "the
    // outcome exists" and "get() returns" has no external hook, so the answer is held while
    // the caller cancels and released afterwards.
    @Test func cancelWhileTheAnswerIsOnItsWay() async throws {
        let server = try LoopbackServer([.hold(body: Data(Self.kBody.utf8))])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        let task = Self.start(http)
        #expect(await server.waitUntil { $0.heldCount == 1 })
        task.cancel()
        _ = server.release()
        #expect(Self.isCancelled(await task.value))
        #expect(server.requestCount == 1)                                           // test-http.c:4130
    }

    // C: /http/net/cancel-queued (test-http.c:4798-4818)
    @Test func cancelWhileQueued() async throws {
        let server = try LoopbackServer([.text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 5000, backoffMs: 5, gapMs: 600_000)  // 10 minutes
        _ = try await Self.fetch(http, "/a").get()
        let begin = ContinuousClock.now
        let task = Self.start(http, "/b")
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(Self.isCancelled(await task.value))
        #expect(Self.milliseconds(ContinuousClock.now - begin) < 3000)              // test-http.c:4814
        #expect(server.requestCount == 1)                                           // test-http.c:4815
    }

    // C: /http/net/cancel-queued-from-callback (test-http.c:4830-4850): the queued request is
    // cancelled right when the first one completes.
    @Test func cancelQueuedWhenThePreviousCompletes() async throws {
        let server = try LoopbackServer([.text(Self.kBody)])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 5000, backoffMs: 5, gapMs: 600_000)
        let begin = ContinuousClock.now
        let first = Self.start(http, "/a")
        #expect(await server.waitForRequests(1))
        let second = Self.start(http, "/b")
        let firstOutcome = await first.value
        second.cancel()
        #expect(Self.body(firstOutcome) == Data(Self.kBody.utf8))
        #expect(Self.isCancelled(await second.value))
        #expect(server.requestCount == 1)
        #expect(Self.milliseconds(ContinuousClock.now - begin) < 3000)              // test-http.c:4846
    }

    // C: /http/net/dropped-in-flight (test-http.c:4192-4250): an operation keeps the client
    // alive; it is released once the operations are done (in flight, in back-off, queued).
    @Test func clientDroppedWhileInFlight() async throws {
        func dropped(_ server: LoopbackServer, timeoutMs: Int, backoffMs: Int, gapMs: Int,
                     paths: [String], afterStart: () async -> Void) async throws -> ([Outcome], Bool) {
            let weakClient = WeakClient()
            var tasks: [Task<Outcome, Never>] = []
            do {
                let http = try Self.client(server, timeoutMs: timeoutMs, backoffMs: backoffMs, gapMs: gapMs)
                weakClient.client = http
                for path in paths { tasks.append(Self.start(http, path)) }
            }
            await afterStart()
            #expect(weakClient.client != nil)  // still referenced by the operations
            var outcomes: [Outcome] = []
            for task in tasks { outcomes.append(await task.value) }
            tasks.removeAll()
            return (outcomes, await Self.waitUntil { weakClient.client == nil })
        }
        let a = try LoopbackServer([.text(Self.kBody, delay: .milliseconds(20))])
        defer { a.stop() }
        let (inFlight, releasedA) = try await dropped(a, timeoutMs: 2000, backoffMs: 5, gapMs: 0, paths: ["/x"]) {}
        #expect(Self.body(inFlight[0]) == Data(Self.kBody.utf8))
        #expect(releasedA)

        let b = try LoopbackServer([.respond(status: 503, body: Data(Self.kBody.utf8)), .text(Self.kBody)])
        defer { b.stop() }
        // U28-F3: wait for the first attempt to reach the server, then a short positioning wait so
        // a skipped back-off (an immediate retry) has landed before the count is read; the 1 s
        // back-off leaves a correct client ~950 ms of margin for a stalled test thread.
        let (backoff, releasedB) = try await dropped(b, timeoutMs: 2000, backoffMs: 1000, gapMs: 0, paths: ["/x"]) {
            #expect(await b.waitForRequests(1))
            try? await Task.sleep(for: .milliseconds(50))
            #expect(b.requestCount == 1)  // the first attempt failed, the back-off is pending
        }
        #expect(Self.body(backoff[0]) == Data(Self.kBody.utf8))
        #expect(b.requestCount == 2)
        #expect(releasedB)

        let c = try LoopbackServer([.text(Self.kBody)])
        defer { c.stop() }
        let (paced, releasedC) = try await dropped(c, timeoutMs: 2000, backoffMs: 5, gapMs: 200, paths: ["/a", "/b"]) {}
        #expect(paced.allSatisfy { Self.body($0) == Data(Self.kBody.utf8) })
        #expect(releasedC)
    }

    // MARK: Pacing

    // C: /http/net/pacing-gap (test-http.c:4739-4758), the gap timed on the injected clock. The gap
    // runs from each attempt's start (next_start_us, wx-http.c:1592). On the real clock the server's
    // arrival times add each request's latency from its start to the server (URLSession, the
    // loopback socket, the server's queue), and the previous request's latency counts against the
    // gap: under load the arrival gap fell to 66 and 117 ms (results/U23-v3-20261023123721-95783.log,
    // U28-20261023121111-66955.log) while the attempts started 150 ms or more apart
    // (probe-p7/p14-pacing.log). On a ManualClock an arrival's clock time is its attempt's start.
    // Once the previous attempt has left the wire, the clock stops 129 ms after the previous start,
    // where C's bound (>= 130 ms, :4756) is checked on what the server measures, its request count,
    // and again at 149 ms (the client's own 150 ms gap); 1 ms later the next request goes.
    @Test func pacingGapAndSingleWire() async throws {
        let server = try LoopbackServer([.text(Self.kBody, delay: .milliseconds(60))])
        defer { server.stop() }
        let clock = ManualClock()
        let http = try Self.client(server, timeoutMs: 5000, backoffMs: 5, gapMs: 150, clock: clock)
        let tasks = (0..<4).map { _ in Self.start(http) }
        var arrivals: [Int64] = []  // the clock (µs) when each request had reached the server
        for i in 0..<4 {
            if i > 0 {
                #expect(await Self.waitUntil(timeout: .seconds(10)) { http.finishedAttemptCount >= i }, "attempt \(i)")
                await clock.advance(by: arrivals[i - 1] + 129_000 - clock.monotonicMicroseconds)
                _ = await server.waitForRequests(i + 1, timeout: .milliseconds(200))
                #expect(server.requestCount == i, "request \(i + 1) went 129 ms after the previous start")  // test-http.c:4756
                await clock.advance(by: 20_000)
                _ = await server.waitForRequests(i + 1, timeout: .milliseconds(200))
                #expect(server.requestCount == i, "request \(i + 1) went 149 ms after the previous start")
                await clock.advance(by: 1000)
            }
            #expect(await server.waitForRequests(i + 1, timeout: .seconds(10)), "request \(i + 1)")
            arrivals.append(clock.monotonicMicroseconds)
        }
        for task in tasks { #expect(Self.body(await task.value) == Data(Self.kBody.utf8)) }
        #expect(server.requestCount == 4)
        #expect(server.maxActiveCount == 1)                                         // test-http.c:4754
        // The clock times recorded above are 150 ms apart by construction (this test sets them): a
        // consistency check; C's bound is asserted on the server's request count, above.
        for i in 1..<arrivals.count {
            #expect((arrivals[i] - arrivals[i - 1]) / 1000 >= 130, "the clock between two starts")
        }
    }

    // C: /http/net/pacing-off (test-http.c:4761-4778)
    @Test func pacingOffRunsConcurrently() async throws {
        let server = try LoopbackServer([.text(Self.kBody, delay: .milliseconds(300))])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 5000, backoffMs: 5)
        let begin = ContinuousClock.now
        let tasks = [Self.start(http, "/a"), Self.start(http, "/b")]
        for task in tasks { #expect(Self.body(await task.value) == Data(Self.kBody.utf8)) }
        #expect(server.maxActiveCount == 2)                                         // test-http.c:4773
        #expect(Self.milliseconds(ContinuousClock.now - begin) < 560)               // test-http.c:4774
    }

    // C: /http/net/pacing-retry (test-http.c:4781-4795), the gap timed on the injected clock as in
    // pacingGapAndSingleWire (DECISIONS #76). On the real clock the arrival gap is the 200 ms gap
    // plus the wake-up's overshoot plus request 2's latency minus request 1's: about 20 ms of slack
    // against C's 180 ms (200.5-215 ms measured by the reproduce lens at load average 4). Once the
    // 503 attempt has left the wire, the clock stops 179 ms after its start, where C's bound
    // (>= 180 ms, :4792) is checked on the server's request count, and again at 199 ms; 1 ms later
    // the retry goes.
    @Test func pacingRetryWaitsForSlot() async throws {
        let server = try LoopbackServer([.respond(status: 503, body: Data(Self.kBody.utf8)), .text(Self.kBody)])
        defer { server.stop() }
        let clock = ManualClock()
        let http = try Self.client(server, timeoutMs: 5000, backoffMs: 0, gapMs: 200, clock: clock)  // no back-off: only the gap
        let task = Self.start(http)
        #expect(await server.waitForRequests(1, timeout: .seconds(10)), "the first request")
        #expect(await Self.waitUntil(timeout: .seconds(10)) { http.finishedAttemptCount >= 1 }, "the 503 attempt left the wire")
        await clock.advance(by: 179_000)
        _ = await server.waitForRequests(2, timeout: .milliseconds(200))
        #expect(server.requestCount == 1, "the retry went 179 ms after the first start")  // test-http.c:4792
        await clock.advance(by: 20_000)
        _ = await server.waitForRequests(2, timeout: .milliseconds(200))
        #expect(server.requestCount == 1, "the retry went 199 ms after the first start")
        await clock.advance(by: 1000)
        let outcome = await Self.outcome(of: task, within: .seconds(10))
        #expect(outcome.flatMap { Self.body($0) } == Data(Self.kBody.utf8), "\(String(describing: outcome))")
        #expect(server.requestCount == 2)
    }

    // C: /http/net/many-sequential (test-http.c:4854-4880)
    @Test func manySequentialRequests() async throws {
        let server = try LoopbackServer([.text("{}")])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        for _ in 0..<80 {                                                           // test-http.c:4859
            #expect(Self.body(await Self.fetch(http)) == Data("{}".utf8))
        }
        for _ in 0..<3 {                                                            // test-http.c:4868
            let tasks = (0..<HTTPPolicy.maxInflight).map { _ in Self.start(http) }
            for task in tasks { #expect(Self.body(await task.value) == Data("{}".utf8)) }
        }
        #expect(http.outstandingCount == 0)
    }
}
