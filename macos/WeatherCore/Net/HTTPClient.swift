// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HTTPClient.swift - the hardened, host-pinned HTTP GET engine of WeatherCore
// (C: src/net/wx-http.{h,c}, WxHttp) on an ephemeral URLSession. Every
// provider reaches the network through one HTTPClient and nothing else in the
// module does. The pure decisions (validation, status mapping, retry rule,
// back-off, Expires/Last-Modified) live in HTTPPolicy.swift (U09); this file
// is the transport: attempts, deadlines, retries, pacing, admission and
// cancellation.
//
// Policy, as in C (wx-http.h:23-258):
//  - GET only, to the origin pinned at construction; the request line carries
//    HTTPRequestPlan.target byte for byte (the URL is built with
//    CFURLCreateWithBytes from plan.url, never resolved relative to the
//    origin, and its scheme/host/port are checked against the origin's).
//  - Request headers: User-Agent, Accept, Accept-Encoding: gzip and an
//    optional If-Modified-Since (plan.headers), plus `Accept-Language: *`
//    (documented difference, DECISIONS #30: URLSession adds the user's
//    locale unless the header is set; no public-API way to remove it was
//    found among the request and session header settings); Host and
//    Connection come from URLSession. Transport failure messages are fixed
//    English phrases (never the localized URLError text).
//  - No redirects (completion-handler delegate answers nil, so the 3xx is the
//    final response, WX_ERROR_HTTP), no cookies, no credentials (an HTTP
//    authentication challenge is cancelled and its 401/407 reported as the
//    status error), no URL cache, default TLS trust evaluation.
//  - Per attempt: HTTPClientPolicy.timeoutMs covering headers AND body (an own
//    WxClock deadline, not URLSession's idle timer); per operation:
//    HTTPPolicy.totalDeadlineMs including queue wait and back-off.
//  - Retries (at most HTTPPolicy.maxRetries) only after NETWORK, a per-attempt
//    TIMEOUT or HTTP 500...599, waiting backoffBaseMs << attempt on the
//    injected WxClock.
//  - Body: at most HTTPPolicy.maxBodyBytes DECODED bytes (counted in
//    didReceive data); a declared Content-Length above the cap, an invalid or
//    conflicting Content-Length, a Transfer-Encoding other than chunked and a
//    Content-Encoding list other than nothing / one gzip are PARSE, decided
//    from the response head before any body byte is read.
//  - At most HTTPPolicy.maxInflight outstanding operations per client; the
//    next one fails at once with RATE_LIMITED and no traffic.
//  - Pacing (minGapMs > 0): one FIFO queue, at most one attempt on the wire,
//    attempt starts at least minGapMs apart, a retry re-enters at the head.
//  - Cancellation is Swift task cancellation: a cancelled caller gets
//    CancellationError (C: G_IO_ERROR_CANCELLED) promptly, from the queue, an
//    attempt or a back-off, without traffic when it was cancelled before the
//    call, and also when the outcome was ready but get() had not returned.
//
// What URLSession decides itself, where no public-API fix was found among the
// signals probed for each item (listed per item in the U13 debrief, with every C
// case and its probe; the tests pin each as a "platform row"). For status lines it does
// not parse, CFNetwork hands the raw answer over as body bytes (HTTP/0.9
// fallback); there only DECISIONS #10's AVOID of a hand-written HTTP parser
// rules out reading them (DECISIONS #36 N1).
//  - DECISIONS #30: Accept-Language: * is sent (no public-API way found to
//    remove the header); URLSession inflates gzip itself when the FIRST Content-Encoding
//    element is gzip and checks neither the stream end, nor the CRC, nor bytes
//    after the member (C: NETWORK / PARSE). Lists it leaves undecoded
//    ("identity, gzip") are inflated here with the C rules. Under this class
//    (DECISIONS #57): the encoded-count rule (fewer than 20 encoded bytes
//    cannot be a gzip member: NETWORK x3, as in C) is exact only for HTTP/1.1
//    Content-Length or close-delimited bodies; on h2 the metrics count DATA
//    frame headers (9 bytes a frame), so 11-19 encoded bytes in one frame are
//    CFNetwork's empty or prefix success (D5; not testable on loopback), and a
//    chunked body uses the decoded count, so a cut that CFNetwork decodes to a
//    prefix is a success with it (L6).
//  - DECISIONS #34 (documented platform differences of the DECISIONS #10
//    transport): CFNetwork re-sends a request at once, without back-off, inside
//    one task (3 requests on HTTP/1.1; 9 on h2, probe only) when the connection
//    closes before any response byte; the client charges them (task metrics,
//    observed behaviour) and starts no attempt beyond 1 + maxRetries requests,
//    but a re-send series inside a later attempt makes 4-5 wire requests (C: 3;
//    up to 11 on h2, probe only), and after an attempt that held a re-send the
//    next back-off is 2B, not B. It refuses a head with two Content-Length
//    lines of different text before the head is visible (NETWORK, re-sent; C:
//    PARSE or the status's outcome); for a chunked body with a Content-Length
//    whose value does not begin with a negative decimal number it hands the
//    head and the body over, then fails the task (-1005, NETWORK, re-sent; a
//    value beginning with one is carried; C: the chunked body is read, item 4
//    as DECISIONS #36 restates it); takes the end of the connection at a chunk
//    boundary as the end of a chunked body; de-chunks a few hostile single
//    Transfer-Encoding values ("xchunked"); and may reuse a connection after a
//    rejected response that it framed itself.
//  - DECISIONS #36 N3 (as corrected by DECISIONS #45): CFNetwork withholds
//    every head until at least its first body byte (or the end of its body);
//    a head without Content-Type stays withheld longer, until the body is
//    sniffed (probe-p7/p1b.log:10-12: 4 body bytes, task.response nil). A
//    withheld head is judged from the task metrics when the connection fails
//    or the attempt deadline ends the transfer: C's outcome when the head's
//    first byte came within the deadline, but only at the deadline's wake-up
//    when the connection stays open (the system clock wakes about 6.7 % late:
//    10.67 s for 10 s, probe-p7/p2-10s.log; a withheld 5xx takes about 35 s
//    over three attempts, C about 3 s); a withheld head whose first byte came
//    after the deadline is the deadline's TIMEOUT, as in C (DECISIONS #53). A
//    head followed by no body byte is not in the metrics and is never judged
//    (NEW U13-N16, below). Whether handed over or withheld, a head is dated by
//    its first byte (Transfer.verdictTime; DECISIONS #38, #53; NEW U13-N13).
//  - DECISIONS #45 (NEW U13-N11..N16), no public-API fix found among the
//    signals each lists in the U13 debrief:
//    N11: a response with two Host lines (also in a 1xx head) is used by its
//    status (200 OK x1, 429 RATE_LIMITED x1, 503 HTTP x3) where libsoup
//    refuses the head (C: NETWORK after 3 requests); CFNetwork joins the
//    lines into one value, which C accepts as one line.
//    N12: an HTTP/1.0 response whose Connection header names Content-Length,
//    Content-Encoding, Transfer-Encoding, Last-Modified or Expires keeps those
//    headers and is framed, decoded and validated by them (a different body
//    or validators, or PARSE after 1 request for a coding, length or value
//    C never sees), where libsoup removes them first (C: success, 1
//    request); CFNetwork reports no response version.
//    N13: a head whose first byte comes before the deadline and whose end
//    after it is judged as if complete (by its status, and by the head rules:
//    the 100 KiB limit, the HTTP/0.9 fallback, a server-sent Identity) when it
//    reaches the client before the deadline's wake-up, or is complete at the
//    wake-up (C: TIMEOUT x3); a head whose first byte came after the deadline
//    is the deadline's TIMEOUT x3, as in C (DECISIONS #53, #76, #78); the
//    other way round, a head C judges at once is a TIMEOUT here only when no
//    body byte follows it (N16). Extension (DECISIONS #57): a final head
//    after the deadline that follows a 1xx head before it is dated by the 1xx's
//    first byte and gets whatever verdict it carries, handed over or withheld
//    alike: RATE_LIMITED or NOT_FOUND x1, HTTP x1 (3xx/4xx) or x3 (5xx), PARSE
//    x1, a bodiless 204/205/304-to-If-Modified-Since a success (C: TIMEOUT x3).
//    N14: a 401/407 whose authentication challenge CFNetwork raises, or a
//    401/407/421 whose body has a Content-Encoding, fails fast (HTTP after 1
//    request, from the head) where C reads the body first (stalled: TIMEOUT
//    x3; cut on a kept-alive connection: NETWORK x3); every other 401/407/421
//    counts once its body has ended, as in C; an HTTP/1.0 one cut short
//    without a Connection header is NETWORK x3 (C: HTTP x1). One with a
//    Content-Encoding whose head CFNetwork withholds and whose body stalls is
//    TIMEOUT x3, as in C (DECISIONS #53; recorded in #57 as a correction to #45).
//    N15: a chunked body labelled gzip (first element) of 20 or more payload
//    bytes that CFNetwork decodes to nothing is NETWORK after 3 requests (the
//    decoded count stands in for the encoded one, which counts the chunk
//    framing); C: a valid member of empty content is a success with an empty
//    body, the member followed by bytes PARSE after 1 request.
//    N16: a head followed by no body byte on a connection the server keeps
//    open ends as the attempt deadline's TIMEOUT after 3 requests (about
//    33-35 s): a 429 there gets no 60 s cool-down and no NWS 5 s pause (C:
//    RATE_LIMITED after 1 request, at once), and a 205 without a body byte or
//    a chunked 204 fails where C succeeds.
//  - DECISIONS #57 (NEW U13-N17): a 401 (no challenge CFNetwork handles, no
//    Content-Encoding) whose chunked body is cut inside a chunk is HTTP after
//    1 request, because CFNetwork completes that body without an error (C:
//    NETWORK after 3 requests, http1/soup-body-input-stream.c:150-157); the
//    same 407 or 421 body is NETWORK x3 as in C.
//  - The 100 KiB head limit (wx-http.h:199) is checked on the metrics' count
//    of head bytes when the transfer completes: CFNetwork has buffered the
//    whole head by then (no early memory bound), and a server that keeps the
//    connection open with an incomplete body gets the refusal at the deadline.
//    Status-line forms libsoup and CFNetwork parse differently, and header
//    syntax CFNetwork normalises (blanks before a colon, a bare CR) or keeps
//    verbatim (fold whitespace, DECISIONS #57), are documented differences
//    (U13 debrief).

import Foundation
import Synchronization

/// The HTTP client of one provider (C: WxHttp). Create one per base URL and
/// share it; it is safe to use from any task.
public final class HTTPClient: Sendable {

    /// A successful response (C: WxHttpResponse).
    public struct Response: Sendable, Equatable {
        /// HTTP status of the final attempt: 200...299, or 304 when
        /// If-Modified-Since was sent.
        public let status: Int
        /// The decoded body, at most HTTPPolicy.maxBodyBytes bytes; empty for
        /// 204, 205 and 304.
        public let body: Data
        /// UTC unix seconds from Expires, 0 if absent or implausible.
        public let expiresS: Int64
        /// Last-Modified text, nil if absent or unusable.
        public let lastModified: String?

        public init(status: Int, body: Data, expiresS: Int64, lastModified: String?) {
            self.status = status
            self.body = body
            self.expiresS = expiresS
            self.lastModified = lastModified
        }
    }

    /// The constant Accept-Language value sent with every request (documented
    /// difference, DECISIONS #30): the same on every install, RFC 9110 12.5.4
    /// "any language", so no locale is disclosed.
    public static let acceptLanguage = "*"

    /// The wire connections URLSession may open per host: libsoup's default
    /// (max-conns-per-host 2), which bounded the C client's wire concurrency.
    static let connectionsPerHost = 2

    /// The validated configuration (origin, User-Agent, timings).
    public let policy: HTTPClientPolicy
    /// The time source of every deadline and back-off.
    let clock: any WxClock
    /// The whole-operation deadline, ms (HTTPPolicy.totalDeadlineMs; tests
    /// inject a shorter one through the internal initialiser).
    let totalDeadlineMs: Int

    private let session: URLSession
    private let origin: Origin
    private let state = Mutex(State())

    /// Scheme, host and port of the pinned origin as CFURL parses them.
    private struct Origin: Sendable {
        let scheme: String
        let host: String
        let port: Int
    }

    /// Admission and pacing state (C: inflight, on_wire, next_start_us, queue).
    private struct State {
        var inflight = 0
        var onWire = 0
        var nextStartUs: Int64 = .min
        var queue: [UInt64] = []
        var nextTicket: UInt64 = 0
        var generation: UInt64 = 0
        var parked: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var attemptsFinished = 0
    }

    /// wx_http_new_custom: validates like HTTPClientPolicy (INVALID_ARG with
    /// its fixed messages) and creates the client's session.
    public convenience init(
        baseURL: String, userAgent: String = HTTPPolicy.userAgent,
        timeoutMs: Int = HTTPPolicy.timeoutMs, backoffBaseMs: Int = HTTPPolicy.backoffBaseMs,
        minGapMs: Int = 0, clock: any WxClock = SystemClock()
    ) throws(WxError) {
        let policy = try HTTPClientPolicy(
            baseURL: baseURL, userAgent: userAgent, timeoutMs: timeoutMs,
            backoffBaseMs: backoffBaseMs, minGapMs: minGapMs)
        try self.init(policy: policy, clock: clock, totalDeadlineMs: HTTPPolicy.totalDeadlineMs)
    }

    /// Creates a client for an already validated policy.
    public convenience init(policy: HTTPClientPolicy, clock: any WxClock = SystemClock()) throws(WxError) {
        try self.init(policy: policy, clock: clock, totalDeadlineMs: HTTPPolicy.totalDeadlineMs)
    }

    /// Internal: lets tests shorten the whole-operation deadline (C has none:
    /// its test waits 45 s of wall time, test-http.c test_net_total_deadline).
    init(policy: HTTPClientPolicy, clock: any WxClock, totalDeadlineMs: Int) throws(WxError) {
        guard totalDeadlineMs > 0, let origin = Self.components(of: policy.schemeNormalisedOrigin + "/") else {
            throw WxError(.invalidArg, HTTPPolicy.Message.unacceptableBaseURL)
        }
        self.policy = policy
        self.clock = clock
        self.totalDeadlineMs = totalDeadlineMs
        self.origin = origin
        session = URLSession(
            configuration: Self.makeConfiguration(), delegate: SessionDelegate(), delegateQueue: nil)
    }

    deinit {
        // Every operation keeps the client alive, so nothing is in flight here.
        session.invalidateAndCancel()
    }

    /// The number of outstanding operations (C: self->inflight).
    var outstandingCount: Int { state.withLock { $0.inflight } }

    /// The number of attempts that have left the wire (tests use it to know
    /// that a back-off, not an attempt deadline, is the pending clock wait).
    var finishedAttemptCount: Int { state.withLock { $0.attemptsFinished } }

    // MARK: Session configuration

    /// An ephemeral configuration with every implicit behaviour switched off:
    /// no cookie jar, credential store or URL cache, no waiting for
    /// connectivity, and URLSession's own timers far beyond the client's
    /// deadlines (they are idle / whole-task timers, not the C contract).
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = connectionsPerHost
        let farBeyond = TimeInterval(HTTPPolicy.timeArgMaxMs + HTTPPolicy.totalDeadlineMs) / 1000
        configuration.timeoutIntervalForRequest = farBeyond
        configuration.timeoutIntervalForResource = farBeyond
        return configuration
    }

    // MARK: Request

    private static func cfURL(_ text: String) -> URL? {
        let bytes = Array(text.utf8)
        return CFURLCreateWithBytes(nil, bytes, bytes.count, CFStringBuiltInEncodings.UTF8.rawValue, nil) as URL?
    }

    private static func components(of text: String) -> Origin? {
        guard let url = cfURL(text), let scheme = CFURLCopyScheme(url as CFURL) as String?,
              let host = CFURLCopyHostName(url as CFURL) as String?
        else { return nil }
        return Origin(scheme: scheme.lowercased(), host: host, port: Int(CFURLGetPortNumber(url as CFURL)))
    }

    /// The URLRequest of a plan: the URL is made from plan.url's bytes (so
    /// the request line carries plan.target unchanged; URL(string:) would
    /// re-encode characters such as | ^ { } and a relative resolution of a
    /// "//" target would leave the origin), then pinned to the origin.
    func makeRequest(_ plan: HTTPRequestPlan) throws(WxError) -> URLRequest {
        guard let url = Self.cfURL(plan.url),
              let parts = Self.components(of: plan.url),
              parts.scheme == origin.scheme, parts.host == origin.host, parts.port == origin.port
        else { throw WxError(.invalidArg, HTTPPolicy.Message.malformedRequestPath) }
        var request = URLRequest(url: url)
        request.httpMethod = HTTPPolicy.TransportRules.method
        request.httpShouldHandleCookies = HTTPPolicy.TransportRules.sendsCookies
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = TimeInterval(HTTPPolicy.timeArgMaxMs + HTTPPolicy.totalDeadlineMs) / 1000
        for field in plan.headers {
            request.setValue(field.value, forHTTPHeaderField: field.name)
        }
        request.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        return request
    }

    // MARK: Operation

    /// wx_http_get_async + wx_http_get_finish: GET `pathAndQuery` of the
    /// pinned origin with the policy of the file comment.
    ///
    /// - Throws: `WxError` (INVALID_ARG before anything else, RATE_LIMITED
    ///   when HTTPPolicy.maxInflight operations are outstanding, NETWORK,
    ///   TIMEOUT, HTTP, NOT_FOUND, PARSE), or `CancellationError` when the
    ///   calling task is cancelled before the call returns. Messages never
    ///   contain body text.
    public func get(_ pathAndQuery: String, accept: String, ifModifiedSince: String? = nil) async throws
        -> Response
    {
        let plan = try policy.plan(pathAndQuery: pathAndQuery, accept: accept, ifModifiedSince: ifModifiedSince)
        let request = try makeRequest(plan)
        let admitted = state.withLock { s -> Bool in
            guard s.inflight < HTTPPolicy.maxInflight else { return false }
            s.inflight += 1
            return true
        }
        guard admitted else { throw WxError(.rateLimited, HTTPPolicy.Message.tooManyOutstanding) }
        defer { state.withLock { $0.inflight -= 1 } }
        try Task.checkCancellation()  // a cancelled caller sends nothing

        let totalDeadline = clock.monotonicMicroseconds + Int64(totalDeadlineMs) * 1000
        // Requests on the wire so far. C makes one request per attempt; CFNetwork re-sends a
        // request by itself, immediately (3 requests per task on HTTP/1.1; 9 on h2, probe only),
        // when the connection closes before any response byte or the head cannot be parsed. Those
        // re-sends are charged here (one URLSessionTaskMetrics transaction per request on the
        // wire: observed behaviour, not an Apple guarantee), so no attempt starts once
        // 1 + HTTPPolicy.maxRetries requests were made; at most 1 + maxRetries attempts happen in
        // any case. A re-send series inside a later attempt still overshoots on the wire
        // (DECISIONS #34 item 1, see the file comment).
        var requests = 0
        var atHead = false
        while true {
            try await enterWire(atHead: atHead, totalDeadline: totalDeadline)
            let (outcome, sent) = await runAttempt(request, plan, totalDeadline: totalDeadline)
            leaveWire()
            requests += sent
            // The caller's cancellation wins over every outcome (normalize_error).
            try Task.checkCancellation()
            switch outcome {
            case .success(let response):
                return response
            case .cancelled:
                throw CancellationError()
            case .failure(let error, let status, let totalExpired):
                let attempt = requests - 1  // C's attempt number of the request that just failed
                guard HTTPPolicy.shouldRetry(
                    error.code, httpStatus: status, attempt: attempt, totalDeadlineExpired: totalExpired)
                else { throw error }
                let resume = clock.monotonicMicroseconds + Int64(policy.backoffDelayMs(attempt: attempt)) * 1000
                if resume >= totalDeadline {
                    try await clock.sleep(until: totalDeadline)
                    throw WxError(.timeout, HTTPPolicy.Message.deadlineExceeded)
                }
                try await clock.sleep(until: resume)
                atHead = true
            }
        }
    }

    /// The result of one attempt.
    enum AttemptOutcome: Sendable {
        case success(Response)
        /// `status` is the attempt's HTTP status (0 if none); `totalExpired`
        /// marks the whole-operation deadline.
        case failure(WxError, status: Int, totalExpired: Bool)
        case cancelled
    }

    /// One GET with its deadline: min(per-attempt, whole-operation). Returns the outcome and
    /// the number of requests URLSession put on the wire for it (at least 1).
    ///
    /// When the deadline passes first, it cancels the transfer (C: on_deadline cancels the
    /// attempt's I/O and the pending callback reports it), and the transfer's completion gives
    /// the outcome: the deadline's TIMEOUT, or what C had already decided from the head before
    /// the deadline, which CFNetwork may have withheld and which the task metrics still show. A
    /// transfer that completes after the deadline (the clock's wake-up comes late) is judged the
    /// same way: a verdict on the head counts when the head's first byte arrived within the
    /// deadline (Transfer.verdictTime), anything else is the deadline's TIMEOUT. The caller's
    /// cancellation is never judged.
    private func runAttempt(_ request: URLRequest, _ plan: HTTPRequestPlan, totalDeadline: Int64) async
        -> (AttemptOutcome, Int)
    {
        let attemptDeadline = clock.monotonicMicroseconds + Int64(policy.timeoutMs) * 1000
        let totalFirst = totalDeadline <= attemptDeadline
        let wake = min(attemptDeadline, totalDeadline)
        let clock = self.clock
        let session = self.session
        // The request goes on the wire now, not when a child task gets a thread: the attempt's
        // deadline then measures the transfer, not the scheduling of this task group.
        let transfer = Transfer(
            sentIfModifiedSince: plan.sendsIfModifiedSince, clock: clock, deadline: wake, totalFirst: totalFirst)
        transfer.begin(session: session, request: request)
        let outcome = await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await clock.sleep(until: wake)
                } catch {
                    return  // the transfer finished first, or the caller cancelled
                }
                transfer.expire()
            }
            let outcome = await withTaskCancellationHandler {
                await transfer.outcome()
            } onCancel: {
                transfer.cancel()
            }
            group.cancelAll()
            return outcome
        }
        // The transfer completed, and its metrics precede its completion.
        return (outcome, max(1, transfer.requestCount))
    }

    // MARK: Pacing (C: enqueue, pump, on_pump_timer, on_queue_cancelled)

    /// Waits until this operation may put an attempt on the wire. Without
    /// pacing that is at once; with pacing the operation queues (at the tail,
    /// or at the head for a retry) until it is first, nothing is on the wire
    /// and minGapMs have passed since the previous attempt started.
    private func enterWire(atHead: Bool, totalDeadline: Int64) async throws {
        let gapUs = Int64(policy.minGapMs) * 1000
        if gapUs == 0 {
            state.withLock { $0.onWire += 1 }
            return
        }
        let ticket = state.withLock { s -> UInt64 in
            let ticket = s.nextTicket
            s.nextTicket += 1
            if atHead { s.queue.insert(ticket, at: 0) } else { s.queue.append(ticket) }
            return ticket
        }
        do {
            while true {
                enum Next { case go, sleep(Int64), park(UInt64) }
                let now = clock.monotonicMicroseconds
                let next = state.withLock { s -> Next in
                    guard s.queue.first == ticket, s.onWire == 0 else { return .park(s.generation) }
                    guard now >= s.nextStartUs else { return .sleep(s.nextStartUs) }
                    s.queue.removeFirst()
                    s.onWire += 1
                    s.nextStartUs = now + gapUs
                    return .go
                }
                switch next {
                case .go:
                    return
                case .sleep(let until):
                    if until >= totalDeadline {
                        try await clock.sleep(until: totalDeadline)
                        throw WxError(.timeout, HTTPPolicy.Message.deadlineExceeded)
                    }
                    try await clock.sleep(until: until)
                case .park(let generation):
                    try await park(ticket, generation: generation, totalDeadline: totalDeadline)
                }
            }
        } catch {
            state.withLock { s in s.queue.removeAll { $0 == ticket } }
            wakeParked()
            throw error
        }
    }

    /// Ends an attempt's time on the wire and lets the queue move on.
    private func leaveWire() {
        state.withLock { s in
            s.onWire -= 1
            s.attemptsFinished += 1
        }
        if policy.minGapMs > 0 {
            wakeParked()
        }
    }

    /// Wakes every parked queue member so it re-checks its turn.
    private func wakeParked() {
        let parked = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.generation &+= 1
            let all = Array(s.parked.values)
            s.parked.removeAll()
            return all
        }
        for continuation in parked {
            continuation.resume()
        }
    }

    /// Parks a queued operation until the queue changes, the whole-operation
    /// deadline passes (TIMEOUT) or the caller cancels (CancellationError).
    private func park(_ ticket: UInt64, generation: UInt64, totalDeadline: Int64) async throws {
        enum Parked { case woken, deadline }
        let clock = self.clock
        let result: Parked? = await withTaskGroup(of: Parked?.self) { group in
            group.addTask {
                await self.waitForChange(ticket, since: generation)
                return Task.isCancelled ? nil : .woken
            }
            group.addTask {
                do {
                    try await clock.sleep(until: totalDeadline)
                    return .deadline
                } catch {
                    return nil
                }
            }
            var result: Parked?
            for await value in group {
                if let value {
                    result = value
                    break
                }
            }
            group.cancelAll()
            return result
        }
        switch result {
        case .woken: return
        case .deadline: throw WxError(.timeout, HTTPPolicy.Message.deadlineExceeded)
        case nil: throw CancellationError()
        }
    }

    private func waitForChange(_ ticket: UInt64, since generation: UInt64) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.generation != generation || Task.isCancelled { return true }
                    s.parked[ticket] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { $0.parked.removeValue(forKey: ticket) }
            continuation?.resume()
        }
    }
}
