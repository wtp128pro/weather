// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HTTPClientTransfer.swift - one attempt of HTTPClient on URLSession (C:
// attempt_start, on_status_code/inspect_framing, on_sent, on_read in
// src/net/wx-http.c:1095-1600) and the response-head rules it applies.
//
// Every URLSession delegate method here uses its completion-handler form:
// an async implementation of these @objc optional requirements crashes the
// Swift 6.4 compiler under NonisolatedNonsendingByDefault (cartography
// macos-platform.md:99-128), and the completion handler is the only form
// that cannot be mistaken for it.
//
// What CFNetwork shows of a response, and how the C rules are applied to it
// (each observed on macOS 27 with loopback probes, see the U13 debrief):
//  - A status line or answer it cannot parse becomes an HTTP/0.9-style 200
//    whose "body" is the raw answer; its transaction metrics then report 0
//    response-head bytes (a real head, even a header-less one, reports more).
//    C: a libsoup error, NETWORK (wx-http.h:191-196).
//  - After removing a single chunked framing it reports Transfer-Encoding as
//    exactly "Identity"; every other Transfer-Encoding list (all PARSE in C)
//    reaches the delegate as some other value.
//  - A head is handed over at the earliest together with its first body byte or
//    the end of its body; a head without Content-Type, or with text/plain,
//    unknown/unknown or an empty one, only once the body has been sniffed
//    (probe-p7/p3.log, p1b.log:10-12); a 205 or a chunked 204 on an open
//    connection not at all. Polling URLSessionTask.response shows nothing
//    meanwhile. When the connection then
//    fails, or the attempt deadline cancels the transfer, the head is only
//    visible in the task metrics, and it is judged from there; when it is
//    handed over after the deadline, its verdict is dated by its arrival
//    (Transfer.verdictTime). (U13 probes probe-p7/p1.log, p3.log.)
//  - Its metrics count every response-head byte, the blank line and any 1xx
//    heads included; libsoup refuses a head of more than 100 KiB (wx-http.h:199).
//  - It inflates a Content-Encoding list itself exactly when the list's first
//    element is gzip / x-gzip; the other lists C reads as one gzip arrive as
//    the raw member and are inflated here (GzipMemberDecoder).

import Compression
import Foundation
import Synchronization

extension HTTPClient {

    // MARK: Response-head rules (ports of wx-http.c parsers)

    /// Content-Encoding, read as a content-coding list (parse_content_coding,
    /// wx-http.c:1095-1115): blanks, empty elements and "identity" are
    /// dropped (case-insensitive); what is left must be nothing or exactly one
    /// gzip / x-gzip. Several header lines arrive joined with ", ", which is
    /// the same list.
    enum ContentCoding: Equatable {
        case none
        case gzip
        case unsupported
    }

    static func contentCoding(_ list: String?) -> ContentCoding {
        guard let list else { return .none }
        var gzips = 0
        for part in list.split(separator: ",", omittingEmptySubsequences: false) {
            let name = part.trimmingCharacters(in: Self.gStrstripBlanks).lowercased()
            if name.isEmpty || name == "identity" { continue }
            guard name == "gzip" || name == "x-gzip" else { return .unsupported }
            gzips += 1
        }
        if gzips > 1 { return .unsupported }
        return gzips == 1 ? .gzip : .none
    }

    /// Whether CFNetwork inflates a gzip Content-Encoding list itself: exactly when its first
    /// element is gzip or x-gzip (probed for every gzip list of test-http.c:2689-2727, with
    /// Content-Length and chunked framing). The other lists C accepts as one gzip ("identity,
    /// gzip", ", gzip", "identity" + "gzip") arrive as the raw member.
    static func systemInflates(_ list: String) -> Bool {
        let first = list.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let name = first.trimmingCharacters(in: Self.gStrstripBlanks).lowercased()
        return name == "gzip" || name == "x-gzip"
    }

    /// g_strstrip's set (g_ascii_isspace): space, \t, \n, \v, \f, \r.
    private static let gStrstripBlanks = CharacterSet(charactersIn: " \t\n\u{0B}\u{0C}\r")

    /// Content-Length, read as a list (parse_content_length,
    /// wx-http.c:1149-1190): every element 1*DIGIT after trimming blanks and
    /// tabs, equal values are one value, a value above `limit` (the client's
    /// decoded-body cap, HTTPClient.maxBodyBytes) is too large.
    enum ContentLength: Equatable {
        case value(Int)
        case invalid
        case conflicting
        case tooLarge
    }

    static func contentLength(_ list: String, limit: Int) -> ContentLength {
        var first: [UInt8]?
        var conflict = false
        for part in list.utf8.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false) {
            var element = part[...]
            while let b = element.first, b == 0x20 || b == 0x09 { element = element.dropFirst() }
            while let b = element.last, b == 0x20 || b == 0x09 { element = element.dropLast() }
            if element.isEmpty || !element.allSatisfy({ (0x30...0x39).contains($0) }) { return .invalid }
            while element.count > 1, element.first == 0x30 { element = element.dropFirst() }
            if let first {
                if !first.elementsEqual(element) { conflict = true }
            } else {
                first = Array(element)
            }
        }
        guard let first else { return .invalid }
        if conflict { return .conflicting }
        if first.count > 9 { return .tooLarge }  // above 999999999 > every cap (HTTPPolicy.maxBodyBytes(host:))
        let n = first.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        return n > limit ? .tooLarge : .value(n)
    }

    /// Transfer-Encoding as CFNetwork reports it. C requires the raw (joined) list to be
    /// exactly "chunked" (transfer_coding_is_chunked, wx-http.c:1240). CFNetwork removes one
    /// chunked framing itself and reports what is left: exactly "Identity" when the list was
    /// one "chunked" element (any case, blanks around it); every list C refuses comes out as
    /// something else (" chunked", "identity", " identity", "gzip", "bogus", " ", "", ...).
    /// A server that literally sends "Identity" (or " Identity", which CFNetwork trims) is told
    /// apart when the transfer ends, from the task metrics (no chunk framing was removed) or from
    /// a Content-Length that chunked framing could not carry (`chunkedMayCarry`) on a transfer
    /// that completed (see Transfer.finalOutcome).
    static func transferEncodingIsChunked(_ reported: String) -> Bool {
        reported == "Identity"
    }

    /// Whether CFNetwork lets a chunked response carry this Content-Length value. With any
    /// other value it still hands over the de-chunked head and body, then fails the task (-1005,
    /// DECISIONS #34 item 4); it carries only a value that reads as a NEGATIVE decimal
    /// (strtoll-like: blanks, "-", digits with at least one non-zero digit, anything after them
    /// ignored): "-1", " -1", "-01", "-1x", "-1.5", "-1, -2" are carried; "-0", "-00", "-a",
    /// "-0x1", "-+1", "-", "3", "+5", "" end in -1005 (U13 probe). So "Identity" next to any other
    /// Content-Length on a transfer that completed was sent by the server itself.
    static func chunkedMayCarry(contentLength value: String) -> Bool {
        var bytes = value.utf8[...]
        while let b = bytes.first, b == 0x20 || b == 0x09 { bytes = bytes.dropFirst() }
        guard bytes.first == UInt8(ascii: "-") else { return false }
        return bytes.dropFirst().prefix { (0x30...0x39).contains($0) }.contains { $0 != 0x30 }
    }

    /// The line C reads for Last-Modified and Expires, from a value URLSession joined with ", "
    /// (C reads the LAST line through libsoup's soup_message_headers_get_one, wx-http.h:205-209;
    /// repeated lines are libsoup's business, :214-217). Rule (b) of DECISIONS #40, which amends
    /// DECISIONS #36 N9: the value is cut at ", " into items, a weekday name and the piece after it
    /// forming one item (an IMF-fixdate or rfc850-date holds one ", ", an asctime-date none).
    /// When there are two or more items and every item is an HTTP date (HTTPPolicy.HTTPDate), the
    /// last item is returned: repeated date lines give C's last line. In every other case the
    /// value is returned unchanged, as C keeps a single line ("x, y", "Mon, 1 Jan 2024",
    /// "<date>, extra"; a Last-Modified line is sent back as it came, test-metno.c:4041-4056).
    /// Once joined, one line cannot be told from several (NEW U13-N9): repeated lines with a
    /// line that is not a date give the joined value (C: the last line; "a" + "b" -> "a, b",
    /// C accepts nil, "a" or "b", test-http.c:4611-4612), and a single line made only of HTTP
    /// dates joined by ", " gives its last date (C: the whole line).
    static func lastHeaderLine(_ value: String) -> String {
        let pieces = value.components(separatedBy: ", ")
        if pieces.count == 1 { return value }
        var items: [String] = []
        var i = 0
        while i < pieces.count {
            if Self.isWeekdayName(pieces[i]) && i + 1 < pieces.count {
                items.append(pieces[i] + ", " + pieces[i + 1])
                i += 2
            } else {
                items.append(pieces[i])
                i += 1
            }
        }
        let isDate = { (item: String) in HTTPPolicy.HTTPDate.parse(Array(item.utf8)) != nil }
        if items.count >= 2, items.allSatisfy(isDate), let last = items.last { return last }
        return value
    }

    /// A weekday as HTTP dates spell it: "Mon".."Sun" (IMF-fixdate) or "Monday".."Sunday"
    /// (rfc850-date), ASCII case-insensitive.
    private static func isWeekdayName(_ text: String) -> Bool {
        let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        let full = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let lower = text.lowercased()
        return text.utf8.allSatisfy { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
            && (days.contains(lower) || full.contains(lower))
    }

    /// Last-Modified (record_validators, wx-http.c:1400-1407): the last line, kept only when it
    /// is printable ASCII of at most HTTPPolicy.validatorMax bytes.
    static func lastModified(_ value: String?) -> String? {
        guard let value else { return nil }
        return HTTPPolicy.usableLastModified(bytes: Array(lastHeaderLine(value).utf8))
    }

    /// Expires (wx_http_parse_expires on the last line, wx-http.c:1403); 0 when unusable.
    static func expires(_ value: String?, nowS: Int64) -> Int64 {
        guard let value else { return 0 }
        return HTTPPolicy.parseExpires(bytes: Array(lastHeaderLine(value).utf8), nowS: nowS)
    }

    // MARK: Session delegate

    /// The session-wide delegate: a backstop with the same refusals as
    /// `Transfer` (each task has its own delegate, which takes precedence).
    final class SessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            completionHandler(Transfer.disposition(for: challenge), nil)
        }
    }

    // MARK: One attempt

    /// One GET on the wire: decides the outcome from the response head and
    /// the body, and completes its continuation exactly once.
    final class Transfer: NSObject, URLSessionDataDelegate, Sendable {
        private struct State {
            var continuation: CheckedContinuation<AttemptOutcome, Never>?
            var task: URLSessionDataTask?
            /// The caller cancelled (C: the user's GCancellable).
            var cancelled = false
            /// The attempt's deadline cancelled the transfer (C: on_deadline / on_total_deadline).
            var expired = false
            /// The outcome decided before completion (status, framing, cap) and when.
            var decided: AttemptOutcome?
            var decidedAt: Int64 = .max
            /// `decided` was reached on the response head (C: on_sent decides status, framing and
            /// coding as soon as the head has arrived), not on body bytes.
            var decidedOnHead = false
            /// When the transfer began (monotonic microseconds on the client's clock, just before
            /// the task was created), and how long after the task's creation the first byte of the
            /// final response arrived (URLSessionTaskMetrics: transactionMetrics.last
            /// .responseStartDate - taskInterval.start), rounded up.
            var begunAt: Int64 = 0
            var responseStartOffsetUs: Int64?
            /// didReceive response ran, or a withheld head was judged from the metrics.
            var inspected = false
            var status = 0
            /// The Content-Encoding list is one gzip that CFNetwork inflates itself.
            var systemGzip = false
            /// The raw gzip member of a list CFNetwork leaves undecoded, inflated here.
            var decoder: GzipMemberDecoder?
            var lengthUnknown = false
            /// Transfer-Encoding was accepted as chunked (reported "Identity").
            var chunked = false
            /// ... next to a Content-Length that chunked framing cannot carry (`chunkedMayCarry`).
            var lengthBesideIdentity = false
            /// A 401, 407 or 421 whose status counts only once its body has ended (C: libsoup reads
            /// that body first, Transfer.bodyFirstStatuses): its error, the declared Content-Length,
            /// and whether the response's Connection header holds "close" (libsoup then reads the
            /// body to the end of the connection, soup-message.c:2078-2118,
            /// http1/soup-client-message-io-http1.c:615-625).
            var bodyFirst: WxError?
            var bodyFirstDeclared: Int?
            var bodyFirstClose = false
            /// The Content-Length of a status the caller declared (HTTPClient.get `answering`),
            /// which CFNetwork completes without an error when its body is cut short (see
            /// finalOutcome).
            var answeredDeclared: Int?
            var body = Data()
            var received = 0
            var expiresS: Int64 = 0
            var lastModified: String?
            /// URLSessionTaskMetrics: requests on the wire and, for the last one, the response
            /// head bytes, the body bytes before and after URLSession's decoding, and the head.
            var transactions = 0
            var headBytes: Int64?
            var protocolName: String?
            var wireBodyBytes: Int64 = 0
            var decodedBodyBytes: Int64 = 0
            var metricsResponse: HTTPURLResponse?
            /// The final outcome.
            var finished: AttemptOutcome?

            var isHTTP1: Bool { protocolName?.hasPrefix("http/1") == true }
        }

        private let sentIfModifiedSince: Bool
        private let clock: any WxClock
        /// The attempt's deadline (monotonic microseconds) and the outcome it gives: C's
        /// "request timed out", or "operation deadline exceeded" when the whole-operation
        /// deadline comes first (normalize_error, wx-http.c:701-704).
        private let deadline: Int64
        private let deadlineOutcome: AttemptOutcome
        /// The client's decoded-body cap (HTTPClient.maxBodyBytes), applied on every path that
        /// measures the body: the declared Content-Length, the bytes handed over (CFNetwork's
        /// own gzip inflation included) and the strict gzip decoder.
        private let maxBodyBytes: Int
        /// Non-2xx statuses the caller reads as answers (HTTPClient.get `answering`).
        private let answering: Set<Int>
        private let state = Mutex(State())

        init(
            sentIfModifiedSince: Bool, clock: any WxClock, deadline: Int64, totalFirst: Bool, maxBodyBytes: Int,
            answering: Set<Int>
        ) {
            self.sentIfModifiedSince = sentIfModifiedSince
            self.clock = clock
            self.deadline = deadline
            self.maxBodyBytes = maxBodyBytes
            self.answering = answering
            deadlineOutcome = .failure(
                WxError(.timeout, totalFirst ? HTTPPolicy.Message.deadlineExceeded : HTTPPolicy.Message.requestTimedOut),
                status: 0, totalExpired: totalFirst)
        }

        /// The requests URLSession made for this attempt (0 until its metrics arrive).
        var requestCount: Int { state.withLock { $0.transactions } }

        /// Puts the request on the wire.
        func begin(session: URLSession, request: URLRequest) {
            let begunAt = clock.monotonicMicroseconds
            let task = session.dataTask(with: request)
            task.delegate = self
            let go = state.withLock { s -> Bool in
                if s.cancelled { return false }
                s.task = task
                s.begunAt = begunAt
                return true
            }
            if go { task.resume() }
        }

        /// Waits for the outcome (`.cancelled` once cancel() ran before the task started).
        func outcome() async -> AttemptOutcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<AttemptOutcome, Never>) in
                let ready = state.withLock { s -> AttemptOutcome? in
                    if let finished = s.finished { return finished }
                    if s.cancelled && s.task == nil { return .cancelled }
                    s.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }

        /// Cancels the attempt for the caller; the completion reports it.
        func cancel() {
            let (task, continuation) = state.withLock { s -> (URLSessionDataTask?, CheckedContinuation<AttemptOutcome, Never>?) in
                s.cancelled = true
                if s.task == nil && s.finished == nil {
                    // Never started: nothing will complete, so the waiter is answered here.
                    let continuation = s.continuation
                    s.continuation = nil
                    return (nil, continuation)
                }
                return (s.task, nil)
            }
            task?.cancel()
            continuation?.resume(returning: .cancelled)
        }

        /// The attempt's deadline has passed (C: on_deadline, wx-http.c:807-813): ends the
        /// transfer, whose completion then gives the deadline's outcome, unless C would have
        /// decided the head before it (see finalOutcome).
        func expire() {
            let task = state.withLock { s -> URLSessionDataTask? in
                guard s.finished == nil else { return nil }
                s.expired = true
                return s.task
            }
            task?.cancel()
        }

        static func disposition(for challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodServerTrust:
                return .performDefaultHandling  // the system's certificate verification
            case NSURLAuthenticationMethodClientCertificate:
                return .rejectProtectionSpace  // no client certificate is ever offered
            default:
                return .cancelAuthenticationChallenge  // no credentials are ever sent
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)  // the 3xx becomes the final response
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let disposition = Self.disposition(for: challenge)
            if disposition == .cancelAuthenticationChallenge {
                // An authentication request (401, or 407 from a proxy): without credentials it is
                // the status error, final (C: no authenticate handler, 401/407 -> WX_ERROR_HTTP).
                // Cancelling ends the transfer before its body, which C reads first (NEW U13-N14).
                // No public-API fix found among the four dispositions (probe-p7/p10b.log, Basic and
                // Digest, the client's session configuration, no credential storage):
                // useCredential with a nil credential (lines 1-4, 17-20), performDefaultHandling
                // (5-8, 21-24) and rejectProtectionSpace (9-12, 25-28) hand the body over only after
                // a SECOND request (C: one); cancelAuthenticationChallenge (13-16, 29-32) sends one
                // request and no body. None sent an Authorization header there; performDefaultHandling
                // may send the system's credentials for NTLM / Negotiate (not probed), which C never does.
                let status = (challenge.failureResponse as? HTTPURLResponse)?.statusCode
                    ?? (challenge.protectionSpace.isProxy() ? 407 : 401)
                let now = clock.monotonicMicroseconds
                state.withLock { s in
                    s.status = status
                    if s.decided == nil {
                        s.decided = .failure(HTTPPolicy.statusError(status), status: status, totalExpired: false)
                        s.decidedAt = now
                    }
                }
            }
            completionHandler(disposition, nil)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            completionHandler(decide(inspect(response), at: clock.monotonicMicroseconds) ? .allow : .cancel)
        }

        private enum HeadVerdict {
            case proceed
            case decided(AttemptOutcome)
        }

        /// Records a head verdict reached at monotonic time `at`; true when the body is to be read.
        private func decide(_ verdict: HeadVerdict, at: Int64) -> Bool {
            switch verdict {
            case .proceed:
                return true
            case .decided(let outcome):
                state.withLock { s in
                    if s.decided == nil {
                        s.decided = outcome
                        s.decidedAt = at
                        s.decidedOnHead = true
                    }
                }
                return false
            }
        }

        /// on_sent + inspect_framing, in C's order: head syntax, status, validators,
        /// bodiless statuses, framing, content coding.
        private func inspect(_ response: URLResponse) -> HeadVerdict {
            state.withLock { $0.inspected = true }
            guard let http = response as? HTTPURLResponse else {
                return .decided(.failure(
                    WxError(.network, HTTPPolicy.Message.network("not an HTTP response")), status: 0,
                    totalExpired: false))
            }
            // libsoup refuses a head with a NUL byte anywhere (soup_headers_parse, "Could not parse
            // HTTP response"): NETWORK, before the status is looked at (wx-http.h:199). CFNetwork
            // keeps NUL bytes in header names and values, so those are seen here.
            if http.allHeaderFields.contains(where: { key, value in
                "\(key)".unicodeScalars.contains("\u{0}") || "\(value)".unicodeScalars.contains("\u{0}")
            }) {
                return .decided(.failure(Transfer.malformedResponse, status: 0, totalExpired: false))
            }
            let status = http.statusCode
            state.withLock { $0.status = status }
            guard (100...999).contains(status) else {
                // Only a 3-digit status is a status line (wx-http.h:191-196): a libsoup error, N.
                return .decided(.failure(Transfer.malformedResponse, status: 0, totalExpired: false))
            }
            let bodiless = status == 204 || status == 205 || (status == 304 && sentIfModifiedSince)
            // A status the caller declared (HTTPClient.get `answering`, e.g. NWS's 400 "out of
            // bounds") is an answer: read below exactly like a 2xx - validators, framing, coding,
            // the body under the client's cap, a body cut short (finalOutcome) - and returned with
            // its status; a body that fails those rules gets the 2xx's error and retries. Every
            // other non-2xx status is the status error, as in C. (An authentication challenge has
            // already decided its 401/407 before this, see didReceive challenge; and CFNetwork
            // completes a 401's chunked body cut inside a chunk, which no count measures, so a
            // declared 401 is answered with the bytes before the cut: NEW U13-N17.)
            let answered = !bodiless && answering.contains(status)
            if !bodiless && !answered && !(200...299).contains(status) {
                // A 401, 407 or 421 counts only once its body has ended, as in C (bodyFirstStatuses),
                // when CFNetwork hands that body over as sent: without a Content-Encoding (or with
                // identity only). One it would decode itself can fail in its decoder (-1015) where C,
                // which reads the raw body, reports the status; that one is decided here (NEW
                // U13-N14). A 401/407 with an authentication scheme CFNetwork handles never gets
                // here: its challenge is cancelled (see didReceive challenge).
                let coding = http.value(forHTTPHeaderField: "Content-Encoding")
                if Transfer.bodyFirstStatuses.contains(status), HTTPClient.contentCoding(coding) == .none {
                    let declared: Int? = http.value(forHTTPHeaderField: "Content-Length").flatMap {
                        if case .value(let n) = HTTPClient.contentLength($0, limit: maxBodyBytes) { n } else { nil }
                    }
                    let close = (http.value(forHTTPHeaderField: "Connection") ?? "").split(separator: ",")
                        .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "close" }
                    state.withLock { s in
                        s.bodyFirst = HTTPPolicy.statusError(status)
                        s.bodyFirstDeclared = declared
                        s.bodyFirstClose = close
                    }
                    return .proceed
                }
                return .decided(.failure(HTTPPolicy.statusError(status), status: status, totalExpired: false))
            }
            let expiresS = HTTPClient.expires(http.value(forHTTPHeaderField: "Expires"), nowS: clock.wallSeconds)
            let lastModified = HTTPClient.lastModified(http.value(forHTTPHeaderField: "Last-Modified"))
            state.withLock { s in
                s.expiresS = expiresS
                s.lastModified = lastModified
            }
            if bodiless {
                return .decided(.success(Response(
                    status: status, body: Data(), expiresS: expiresS, lastModified: lastModified)))
            }
            let parse = { (message: String) in
                HeadVerdict.decided(.failure(WxError(.parse, message), status: status, totalExpired: false))
            }
            var declared: Int?
            var chunked = false
            var lengthBesideIdentity = false
            if let transfer = http.value(forHTTPHeaderField: "Transfer-Encoding") {
                if !HTTPClient.transferEncodingIsChunked(transfer) { return parse("unsupported response framing") }
                chunked = true
                // CFNetwork hands over a de-chunked head with such a Content-Length too, but then
                // fails the task (-1005, DECISIONS #34 item 4); a server-sent "Identity" completes.
                lengthBesideIdentity = http.value(forHTTPHeaderField: "Content-Length")
                    .map { !HTTPClient.chunkedMayCarry(contentLength: $0) } ?? false
            } else if let list = http.value(forHTTPHeaderField: "Content-Length") {
                switch HTTPClient.contentLength(list, limit: maxBodyBytes) {
                case .value(let n): declared = n
                case .invalid: return parse("invalid Content-Length")
                case .conflicting: return parse("conflicting Content-Length values")
                case .tooLarge: return parse(HTTPPolicy.Message.responseTooLarge)
                }
            }
            let list = http.value(forHTTPHeaderField: "Content-Encoding")
            let coding = HTTPClient.contentCoding(list)
            if coding == .unsupported { return parse("unsupported content coding") }
            if coding == .gzip && declared == 0 {
                // Zero encoded bytes cannot hold the 20-byte empty gzip member (C: the decoder never
                // reaches its end marker).
                return .decided(.failure(GzipMemberDecoder.Failure.cut.error, status: status, totalExpired: false))
            }
            let systemGzip = coding == .gzip && HTTPClient.systemInflates(list ?? "")
            state.withLock { s in
                s.systemGzip = systemGzip
                s.decoder = coding == .gzip && !systemGzip ? GzipMemberDecoder(limit: maxBodyBytes) : nil
                s.lengthUnknown = declared == nil
                s.chunked = chunked
                s.lengthBesideIdentity = lengthBesideIdentity
                s.answeredDeclared = answered ? declared : nil
            }
            return .proceed
        }

        /// A status line or answer CFNetwork could not parse, or a head with a NUL byte
        /// (wx-http.h:191-199).
        static let malformedResponse = WxError(.network, HTTPPolicy.Message.network("malformed response"))

        /// libsoup's limit on an HTTP/1 response head (HEADER_SIZE_LIMIT, 100 KiB, libsoup 3.6
        /// http1/soup-message-io-data.c:20, :102-107): after each line it reads (or each 8 KiB of
        /// a longer one), more than 100 * 1024 head bytes so far is "Header too big" (NETWORK);
        /// the blank line that ends the head is not checked. So C refuses a head whose status
        /// line and header lines, with their line ends, exceed 102400 bytes.
        static let headLineLimit = 100 * 1024

        /// The same limit on CFNetwork's count of response-head bytes, which includes the blank
        /// line (2 bytes for CRLF; probed: an 89-byte head counts 89) and every 1xx head before
        /// the final one (probed: 25 + 89 = 114). A head ended by a bare LF counts one byte less,
        /// so such a head of exactly 102402 bytes passes here (C refuses it); with 1xx heads the
        /// sum is checked (C checks each head on its own). Both are documented differences.
        static let headByteLimit: Int64 = Int64(headLineLimit) + 2

        /// The smallest gzip member (RFC 1952): a 10-byte header, an empty final DEFLATE block of
        /// 2 bytes, an 8-byte trailer (LoopbackServer.gzip of nothing is exactly 20 bytes).
        static let minimumGzipMember = 20

        /// C's "Header too big" (wx-http.h:199), NETWORK and retried.
        static let headTooLarge = WxError(.network, HTTPPolicy.Message.network("response head too large"))

        /// The client's error for a 2xx Content-Length body cut short, which CFNetwork fails with
        /// NSURLErrorNetworkConnectionLost (-1005; C: libsoup's "Connection terminated
        /// unexpectedly", NETWORK, retried); a declared status's cut body gets it too (finalOutcome).
        static let connectionLost = WxError(
            .network, HTTPPolicy.Message.network(HTTPClient.transportMessage(URLError(.networkConnectionLost))))

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // The client's cap counts DECODED bytes: what URLSession hands over, or what the strict
            // decoder made of the raw member (inflate_chunk, wx-http.c:918-934).
            let now = clock.monotonicMicroseconds
            let stop = state.withLock { s -> Bool in
                if s.decided != nil { return false }
                s.received += data.count
                // The body of a body-first status is only waited for: neither kept nor capped (C
                // gathers it uncapped, soup-session.c:2843-2845; here nothing is kept).
                if s.bodyFirst != nil { return false }
                if let decoder = s.decoder {
                    if let failure = decoder.feed(data) {
                        s.decided = .failure(failure.error, status: s.status, totalExpired: false)
                        s.decidedAt = now
                        return true
                    }
                    return false
                }
                if s.received > maxBodyBytes {
                    s.decided = .failure(
                        WxError(.parse, HTTPPolicy.Message.responseTooLarge), status: s.status, totalExpired: false)
                    s.decidedAt = now
                    return true
                }
                s.body.append(data)
                return false
            }
            if stop { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let last = metrics.transactionMetrics.last
            let responseStartOffsetUs = last?.responseStartDate.map { start in
                Int64((start.timeIntervalSince(metrics.taskInterval.start) * 1_000_000).rounded(.up))
            }
            state.withLock { s in
                s.responseStartOffsetUs = responseStartOffsetUs
                s.transactions = metrics.transactionMetrics.count
                s.headBytes = last?.countOfResponseHeaderBytesReceived
                s.protocolName = last?.networkProtocolName
                s.wireBodyBytes = last?.countOfResponseBodyBytesReceived ?? 0
                s.decodedBodyBytes = last?.countOfResponseBodyBytesAfterDecoding ?? 0
                s.metricsResponse = last?.response as? HTTPURLResponse
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let now = clock.monotonicMicroseconds
            // A head CFNetwork held back (until its first body byte, longer when it sniffs the body)
            // and never handed over, because the transfer failed or the attempt deadline cancelled
            // it, is judged from the metrics, as C judges every head as soon as it arrives (on_sent,
            // inspect_framing). It arrived before the cancel, but not necessarily before the deadline:
            // the deadline's wake-up comes late, so a head can arrive between the deadline and the
            // cancel, where C has already timed out (wx-http.c:807-813, :704). Its verdict is therefore
            // recorded now and dated by the head's first byte in verdictTime, like a head handed over
            // late (DECISIONS #53, V1-P7-D1); only without a responseStartDate is it dated at
            // min(now, deadline). A caller's cancellation is never judged further.
            let (withheld, startKnown) = state.withLock { s -> (HTTPURLResponse?, Bool) in
                (error != nil && !s.inspected && !s.cancelled && s.decided == nil ? s.metricsResponse : nil,
                 s.responseStartOffsetUs != nil)
            }
            if let withheld { _ = decide(inspect(withheld), at: startKnown ? now : min(now, deadline)) }
            let (continuation, outcome) = state.withLock { s -> (CheckedContinuation<AttemptOutcome, Never>?, AttemptOutcome) in
                let outcome = finalOutcome(&s, error, late: s.expired || now > deadline)
                s.finished = outcome
                let continuation = s.continuation
                s.continuation = nil
                return (continuation, outcome)
            }
            continuation?.resume(returning: outcome)
        }

        /// Statuses whose verdict C reaches only once the whole body has arrived: libsoup expects
        /// to requeue a 401 or 407 (its default auth manager) and a 421, so it reads their body
        /// into memory before soup_session_send_async completes and on_sent sees the status
        /// (libsoup 3.6.6 soup-session.c: expected_to_be_requeued :2702-2720,
        /// send_async_maybe_complete :2838-2864, async_send_request_finished :2765-2803). The
        /// client waits for that body too (inspect, State.bodyFirst), unless CFNetwork raised an
        /// authentication challenge for the 401/407 or would decode the body (NEW U13-N14).
        static let bodyFirstStatuses: Set<Int> = [401, 407, 421]

        /// When C reached the verdict in `decided`. A verdict on the head is dated by the head's
        /// arrival, because CFNetwork may hand a head over long after it arrived (only with its
        /// first body byte or the end of its body, later still when it sniffs the body), also after
        /// the attempt deadline but before the deadline's wake-up cancelled the transfer
        /// (DECISIONS #38, V1-D1), and for a head it withheld and never handed over (DECISIONS #53,
        /// V1-P7-D1). The arrival is the first byte of the transaction's response
        /// (URLSessionTaskTransactionMetrics.responseStartDate, taken as an offset from the task's
        /// creation and placed on the client's clock at begin()). No public-API signal found for
        /// the time the head was COMPLETE among the transaction dates (fetchStart through
        /// responseEnd), the byte counts, task.response and countOfBytesReceived (probe-p7/p1.log,
        /// p3.log), so a head whose bytes straddle the deadline is dated by its first byte as well:
        /// judged as if complete, C: TIMEOUT x3 (NEW U13-N13; finalOutcome dates the head rules the
        /// same way, DECISIONS #76, #78). responseStartDate is the first byte
        /// of an interim (1xx) head when one came first, so a final head after the deadline that
        /// follows a 1xx head before it gets whatever verdict it carries too: RATE_LIMITED or
        /// NOT_FOUND x1, HTTP x1/x3, PARSE x1, a bodiless 204/205/304-to-IMS a success (C: TIMEOUT x3; NEW U13-N13
        /// extension, DECISIONS #57: no public-API fix found among responseStartDate,
        /// responseEndDate and didReceiveInformationalResponse, which gives the 1xx's arrival
        /// only; the final didReceive(response:) time was not tried, being only an upper bound).
        /// Verdicts on body bytes (the cap, the gzip decoder) and the statuses C judges
        /// after the body keep the time they were reached.
        ///
        /// The offset (responseStartDate - taskInterval.start, two URLSessionTaskMetrics dates,
        /// DECISIONS #38) is the client's only time input not read from its WxClock. It is
        /// bounded: max(0, offset), and the result is at most decidedAt, so it can only date a
        /// verdict on the head earlier than its delivery. It decides an outcome for a head handed
        /// over between the deadline and the deadline's wake-up (about 0.67 s at the 10 s attempt
        /// deadline, probe-p7/p2-10s.log) and, since DECISIONS #53, for every head CFNetwork
        /// withheld and the client judges at the deadline's wake-up (the DECISIONS #36 N3 class).
        /// The metrics dates are Dates, while the client's clock (CLOCK_UPTIME_RAW) pauses in system
        /// sleep: an attempt that spans a sleep has its offset grow by the sleep, so an in-time
        /// withheld head judged at the wake-up (a 429, say) can be dated late, become the
        /// deadline's TIMEOUT and be retried; a wall-clock step during an attempt could misdate such
        /// a head either way. Neither was probed.
        private static func verdictTime(_ s: State) -> Int64 {
            guard s.decidedOnHead, !bodyFirstStatuses.contains(s.status), let offset = s.responseStartOffsetUs
            else { return s.decidedAt }
            return min(s.decidedAt, s.begunAt + max(0, offset))
        }

        /// The outcome of a completed task: a head whose first byte came after the deadline is the
        /// deadline's outcome, then the rules C applies to the head as it arrives (head size and
        /// syntax, framing), then a verdict C reached before the deadline (verdictTime), then the
        /// deadline itself (`late`: it cancelled the transfer, or the task completed after it),
        /// then the transport's error and a declared status's body cut short, then on_read's
        /// end-of-body rules and the strict gzip path.
        private func finalOutcome(_ s: inout State, _ error: (any Error)?, late: Bool) -> AttemptOutcome {
            s.task = nil
            if s.cancelled && s.decided == nil { return .cancelled }
            // A head whose first byte came after the deadline (the response's first byte, dated as in
            // verdictTime): C's on_deadline had already ended the attempt (wx-http.c:807-813), so C
            // reports TIMEOUT (:704), retried (:771-779), and none of the head rules below may judge
            // it: the 100 KiB limit, the HTTP/0.9 fallback, the server-sent Identity (DECISIONS #76).
            // A head whose first byte came in time and whose end came after the deadline is judged
            // by them as if complete (no public-API signal for the time the head was complete; the
            // NEW U13-N13 class, DECISIONS #76, #78).
            if late, let offset = s.responseStartOffsetUs, s.begunAt + max(0, offset) > deadline { return deadlineOutcome }
            if s.isHTTP1 {
                // C reads the head line by line and refuses it past 100 KiB before parsing it, so
                // neither its status nor its body counts (wx-http.h:199). CFNetwork has already
                // buffered the whole head (and the body read so far) when this is seen.
                if let head = s.headBytes, head > Transfer.headByteLimit {
                    return .failure(Transfer.headTooLarge, status: 0, totalExpired: false)
                }
                // An answer whose head CFNetwork could not parse (an HTTP/0.9-style 200 that
                // carries the raw answer, with 0 response-head bytes in the metrics) is a libsoup
                // error in C: N, retried; nothing of it is copied. h2/h3 have no such fallback.
                if s.inspected, s.headBytes == 0 {
                    return .failure(Transfer.malformedResponse, status: 0, totalExpired: false)
                }
            }
            if s.chunked && s.transactions > 0
                && ((s.systemGzip ? s.wireBodyBytes == 0 : s.wireBodyBytes == s.decodedBodyBytes)
                    || (s.lengthBesideIdentity && error == nil && !late))
            {
                // "Identity" without any chunk framing removed: the server itself sent
                // Transfer-Encoding: Identity (C: not "chunked", PARSE before the body). Chunk
                // framing always adds at least 3 body bytes on the wire (the metrics count them,
                // not the payload). On the decoder path CFNetwork does not inflate, so wire and
                // decoded counts are the raw member's; when it inflates, an empty body (0 wire
                // bytes) decides, and so does a Content-Length chunked framing cannot carry on a
                // transfer that completed (CFNetwork fails chunked framing with it, -1005).
                return .failure(WxError(.parse, "unsupported response framing"), status: s.status, totalExpired: false)
            }
            if let decided = s.decided, !late || Transfer.verdictTime(s) <= deadline { return decided }
            if late { return deadlineOutcome }
            if let error {
                return .failure(
                    WxError(.network, HTTPPolicy.Message.network(HTTPClient.transportMessage(error))), status: s.status,
                    totalExpired: false)
            }
            if let declared = s.answeredDeclared, s.transactions > 0, s.wireBodyBytes < Int64(declared) {
                // A declared status's Content-Length body cut short, the connection closed or kept
                // alive: CFNetwork fails the same 2xx body (-1005, the transport error above) but
                // completes a non-2xx one without an error (as for a body-first status below), so the
                // cut is read from the metrics' wire count and given the 2xx's outcome: NETWORK "the
                // connection was lost", retried, before any coding rule below, as the 2xx's transport
                // error is. The count is the encoded bytes on HTTP/1.1; on h2 it adds 9 bytes per DATA
                // frame header (V1-P7-D5, below), so a whole body never reads as cut there, while a
                // cut within those bytes would pass (h2 not probed; not testable on loopback).
                return .failure(Transfer.connectionLost, status: s.status, totalExpired: false)
            }
            if let statusError = s.bodyFirst {
                // The body of a 401/407/421 has ended: C reports the status, after 1 request (a 421
                // may be re-sent once by libsoup, test-http.c:3269-3270). A Content-Length body cut
                // short on a kept-alive connection is libsoup's "Connection terminated unexpectedly"
                // (http1/soup-body-input-stream.c:150-157): NETWORK, retried. CFNetwork completes
                // such a 4xx body without an error, so the cut is read from the metrics' wire count.
                // With "Connection: close" libsoup reads to the end of the connection: the status.
                // (An HTTP/1.0 answer is not kept alive either, but CFNetwork reports no version:
                // NEW U13-N14.) A chunked 401 body cut inside a chunk also completes without an error
                // and has no declared length to compare: the status, HTTP after 1 request (C: NETWORK
                // x3, soup-body-input-stream.c:150-157; NEW U13-N17, DECISIONS #57); CFNetwork fails
                // the same 407 or 421 body (-1005), NETWORK x3 as in C.
                if let declared = s.bodyFirstDeclared, s.transactions > 0, s.wireBodyBytes < Int64(declared), !s.bodyFirstClose {
                    return .failure(
                        WxError(.network, "connection closed before the whole body arrived"), status: s.status,
                        totalExpired: false)
                }
                return .failure(statusError, status: s.status, totalExpired: false)
            }
            // C counts the ENCODED body (raw_received, on_read wx-http.c:992, :1012-1016). When CFNetwork
            // inflates gzip itself, the encoded size of a Content-Length or close-delimited body is
            // the metrics' wire count: equal to the payload on HTTP/1.1 (U13 probe probe-p7/p4b.log).
            // On h2 the count adds 9 bytes per DATA frame header (2742 for a Content-Length of 2724
            // from api.met.no, V1-P7-D5 of the U13 verify), so 11-19 encoded bytes in one frame count
            // 20-28 and pass the rule below as CFNetwork's empty or prefix success (C: NETWORK x3,
            // DECISIONS #30 class; valid bodies are not affected): the rule is exact only for HTTP/1.1
            // Content-Length or close-delimited bodies (DECISIONS #57, D5 under #30; not testable on loopback).
            // The wire count of a chunked body includes its chunk framing (29 bytes for a 20-byte
            // member in one chunk, 123 in 1-byte chunks, p4b.log), so the decoded count stands in
            // there: a chunked body CFNetwork decodes to nothing is NETWORK x3 (C for a cut member;
            // NEW U13-N15 for a valid member of empty content), and a cut one it decodes to a prefix
            // is a success with that prefix, also under 20 payload bytes (C: NETWORK x3, DECISIONS
            // #30 class; V1-P7-D6). No public-API fix found among countOfResponseBodyBytesReceived and
            // countOfResponseBodyBytesAfterDecoding. Content-Length or close-delimited bodies of 20 or
            // more encoded bytes that CFNetwork decodes to nothing are an empty success (a cut member:
            // C NETWORK x3, DECISIONS #30 class; probe-p7/p5-gzcut.rev2.log).
            let encodedKnown = s.systemGzip && !s.chunked && s.transactions > 0
            let encoded = encodedKnown ? Int(s.wireBodyBytes) : s.received
            if s.lengthUnknown && encoded == 0 {
                // An empty body of unknown length cannot be told from a cut head (on_read).
                return .failure(
                    WxError(.network, "connection closed before any content arrived"), status: s.status,
                    totalExpired: false)
            }
            if encodedKnown && encoded < Transfer.minimumGzipMember {
                // 1-19 encoded bytes cannot hold a gzip member (a 10-byte header, at least 2 bytes of
                // DEFLATE data, an 8-byte trailer): C's decoder refuses them or has not ended when the
                // body ends (inflate_chunk, wx-http.c:907-944; on_read :1025-1031), NETWORK, retried,
                // where CFNetwork hands them over as an empty body (probe-p7/p5-gz20.pre-rev2.log; after
                // this rule, p5-gz20.rev2.log).
                return .failure(GzipMemberDecoder.Failure.cut.error, status: s.status, totalExpired: false)
            }
            if let decoder = s.decoder {
                switch decoder.finish() {
                case .success(let decoded):
                    return .success(Response(
                        status: s.status, body: decoded, expiresS: s.expiresS, lastModified: s.lastModified))
                case .failure(let failure):
                    return .failure(failure.error, status: s.status, totalExpired: false)
                }
            }
            var body = s.body
            // Backstop for a list CFNetwork is expected to inflate (first element gzip): should it
            // ever hand over the raw member instead, the body is inflated here. Undecoded means:
            // with a Content-Length, the metrics show no size change and the bytes start with the
            // gzip magic; without one (chunk framing counts in the metrics), the magic alone.
            let magic = body.starts(with: [0x1F, 0x8B, 0x08])
            let undecoded = magic && (s.lengthUnknown || (s.transactions > 0 && s.wireBodyBytes == s.decodedBodyBytes))
            if s.systemGzip && undecoded {
                switch HTTPClient.inflateGzipMember(body, limit: maxBodyBytes) {
                case .success(let decoded): body = decoded
                case .failure(let error): return .failure(error, status: s.status, totalExpired: false)
                }
            }
            return .success(Response(status: s.status, body: body, expiresS: s.expiresS, lastModified: s.lastModified))
        }
    }

    /// The transport's own message for "network error: %s" (wx-http.c:706): a fixed English
    /// phrase per URLError code plus the code, so the text never depends on the user's
    /// language (localizedDescription would) and never contains response text.
    static func transportMessage(_ error: any Error) -> String {
        let nsError = error as NSError
        let phrase: String
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut: phrase = "the transport timed out"
        case .cannotFindHost, .dnsLookupFailed: phrase = "host not found"
        case .cannotConnectToHost: phrase = "could not connect to the server"
        case .networkConnectionLost: phrase = "the connection was lost"
        case .notConnectedToInternet: phrase = "not connected to the network"
        case .badServerResponse: phrase = "bad server response"
        case .cannotDecodeContentData, .cannotDecodeRawData: phrase = "cannot decode the content"
        case .cannotParseResponse: phrase = "cannot parse the response"
        case .zeroByteResource: phrase = "empty response"
        case .secureConnectionFailed: phrase = "secure connection failed"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            phrase = "the server certificate is not trusted"
        case .clientCertificateRejected, .clientCertificateRequired: phrase = "the server asked for a client certificate"
        case .appTransportSecurityRequiresSecureConnection: phrase = "App Transport Security refused the connection"
        default: phrase = "transport failure"
        }
        return "\(phrase) (\(nsError.domain) \(nsError.code))"
    }

    // MARK: Strict gzip (inflate_chunk / on_read, wx-http.c:907-1050)

    /// Inflates exactly one complete gzip member (RFC 1952) as the C client does; see
    /// GzipMemberDecoder for the rules.
    static func inflateGzipMember(_ data: Data, limit: Int) -> Result<Data, WxError> {
        let decoder = GzipMemberDecoder(limit: limit)
        if let failure = decoder.feed(data) { return .failure(failure.error) }
        return decoder.finish().mapError(\.error)
    }

    /// One gzip member decoded as it arrives, with the rules of GLib's zlib decompressor as the
    /// C client uses it (inflate_chunk, wx-http.c:907-944; on_read :1024-1031): the header is
    /// checked (magic, method 8, no reserved flag, the header CRC when FHCRC is set), more than
    /// `limit` decoded bytes are PARSE "response too large" as soon as they are produced, a
    /// corrupt stream or a wrong CRC-32 / ISIZE is NETWORK, a member that has not ended when the
    /// body ends is NETWORK, and bytes after the trailer are PARSE.
    ///
    /// Compression.framework decodes the raw DEFLATE data, but a bulk-fed decoder reads past
    /// the end of the stream (it reports END with every input byte consumed), so the trailer
    /// would have to be found by value. Here two decoders run in lockstep over 4 KiB slices:
    /// `leading` produces the output; `exact` replays each slice in bulk, and the slice in
    /// which `leading` reported END byte by byte, which gives the exact end of the DEFLATE
    /// stream (1-byte feeding reported the exact end for every one of 3000 probed members; for
    /// a whole 4 MiB member it would take seconds, for one slice it does not). The 8 trailer
    /// bytes are then read at that offset.
    final class GzipMemberDecoder {
        enum Failure: Error, Equatable {
            /// The member (header, DEFLATE data or trailer) ended early: NETWORK.
            case cut
            /// Bad header, invalid DEFLATE data, or a CRC-32 / ISIZE / header CRC mismatch: NETWORK.
            case corrupt
            /// Bytes after the trailer in the read that completed it: PARSE.
            case dataAfterEnd
            /// Bytes after the trailer in a later read: PARSE.
            case continuesAfterEnd
            /// More than `limit` decoded bytes: PARSE.
            case tooLarge

            var error: WxError {
                switch self {
                case .cut: WxError(.network, "compressed body ended before its end marker")       // wx-http.c:1030
                case .corrupt: WxError(.network, HTTPPolicy.Message.network("invalid compressed data"))
                case .dataAfterEnd: WxError(.parse, "data after the end of the compressed body")  // wx-http.c:937
                case .continuesAfterEnd: WxError(.parse, "compressed body continues after its end marker")  // :915
                case .tooLarge: WxError(.parse, HTTPPolicy.Message.responseTooLarge)               // wx-http.c:931
                }
            }
        }

        static let sliceSize = 4096

        private enum Phase { case header, deflate, trailer }
        private enum HeaderField { case fixed, extraLength, extra, name, comment, headerCRC }

        private let limit: Int
        private var output = Data()
        private var failure: Failure?
        private var phase = Phase.header
        private var field = HeaderField.fixed
        private var fixed: [UInt8] = []
        private var flags: UInt8 = 0
        private var remaining = 0
        private var headerCRC: UInt32 = 0xFFFF_FFFF
        private var storedHeaderCRC: [UInt8] = []
        /// The DEFLATE bytes of the read being decoded, consumed from `pendingStart` on (by
        /// index: removing each slice from the front would cost O(n) per slice).
        private var pending: [UInt8] = []
        private var pendingStart = 0
        /// `leading` reached the end in an earlier slice, but `exact` has not yet (not observed;
        /// kept so a later end is still found byte by byte).
        private var exactSearching = false
        private var trailer: [UInt8] = []
        private let leading = InflateStream()
        private let exact = InflateStream()
        /// zlib's checks on the DEFLATE data, which Compression.framework does not all make.
        private let validator = DeflateValidator()

        init(limit: Int) {
            self.limit = limit
        }

        /// Feeds the next body bytes. Returns the failure once one is known (and from then on).
        func feed(_ data: Data) -> Failure? {
            if failure != nil { return failure }
            let finishedBefore = trailer.count == 8
            [UInt8](data).withUnsafeBufferPointer { bytes in
                var i = 0
                if phase == .header { i = consumeHeader(bytes) }
                guard failure == nil else { return }
                if phase == .deflate {
                    if exactSearching {
                        i = findExactEnd(bytes, from: i)
                    } else {
                        pending.append(contentsOf: bytes[i...])
                        i = bytes.count
                        // The whole read is decoded now, its tail shorter than a slice too, as C
                        // inflates each read (on_read, wx-http.c:999-1001): the end of the DEFLATE
                        // data and the trailer are found in the read that holds them, so a byte in
                        // a later read "continues after its end marker" (:913-916), and a verdict
                        // on this read is not deferred until the body ends.
                        while failure == nil, phase == .deflate, !exactSearching, pending.count > pendingStart {
                            processSlice(min(Self.sliceSize, pending.count - pendingStart), sameRead: true)
                        }
                        pending.removeFirst(pendingStart)
                        pendingStart = 0
                    }
                }
                if failure == nil, phase == .trailer, i < bytes.count {
                    appendTrailer(bytes[i...], sameRead: !finishedBefore)
                }
            }
            return failure
        }

        /// The body ended: the decoded bytes, or why the member is not one complete, correct member.
        func finish() -> Result<Data, Failure> {
            if let failure { return .failure(failure) }
            guard phase == .trailer, trailer.count == 8 else { return .failure(.cut) }
            return .success(output)
        }

        // MARK: Header (RFC 1952 2.3; zlib inflate.c HEAD...HCRC)

        private func consumeHeader(_ b: UnsafeBufferPointer<UInt8>) -> Int {
            var i = 0
            while i < b.count, phase == .header {
                let byte = b[i]
                i += 1
                if field != .headerCRC { headerCRC = HTTPClient.crc32Update(headerCRC, byte) }
                switch field {
                case .fixed:
                    fixed.append(byte)
                    guard fixed.count == 10 else { continue }
                    guard fixed[0] == 0x1F, fixed[1] == 0x8B, fixed[2] == 8, fixed[3] & 0xE0 == 0 else {
                        failure = .corrupt
                        return i
                    }
                    flags = fixed[3]
                    advance(after: .fixed)
                case .extraLength:
                    storedHeaderCRC.append(byte)  // reused as a 2-byte buffer
                    if storedHeaderCRC.count == 2 {
                        remaining = Int(storedHeaderCRC[0]) | Int(storedHeaderCRC[1]) << 8
                        storedHeaderCRC = []
                        if remaining == 0 { advance(after: .extra) } else { field = .extra }
                    }
                case .extra:
                    remaining -= 1
                    if remaining == 0 { advance(after: .extra) }
                case .name:
                    if byte == 0 { advance(after: .name) }
                case .comment:
                    if byte == 0 { advance(after: .comment) }
                case .headerCRC:
                    storedHeaderCRC.append(byte)
                    if storedHeaderCRC.count == 2 {
                        let expected = (headerCRC ^ 0xFFFF_FFFF) & 0xFFFF
                        guard UInt32(storedHeaderCRC[0]) | UInt32(storedHeaderCRC[1]) << 8 == expected else {
                            failure = .corrupt
                            return i
                        }
                        phase = .deflate
                    }
                }
            }
            return i
        }

        /// Moves to the next optional header field present after `done` (FEXTRA, FNAME,
        /// FCOMMENT, FHCRC in that order), or to the DEFLATE data.
        private func advance(after done: HeaderField) {
            let order: [(HeaderField, UInt8)] = [(.extraLength, 0x04), (.name, 0x08), (.comment, 0x10), (.headerCRC, 0x02)]
            let start = switch done {
            case .fixed: 0
            case .extraLength, .extra: 1
            case .name: 2
            case .comment: 3
            case .headerCRC: 4
            }
            for (next, bit) in order[start...] where flags & bit != 0 {
                field = next
                storedHeaderCRC = []
                return
            }
            phase = .deflate
        }

        // MARK: DEFLATE data

        /// Decodes the next `count` pending bytes: `leading` in bulk, then `exact` in bulk, or
        /// byte by byte when `leading` reached the end in this slice.
        private func processSlice(_ count: Int, sameRead: Bool) {
            let slice = Array(pending[pendingStart..<(pendingStart + count)])
            pendingStart += count
            let limit = self.limit
            // zlib refuses the data at a point where `decodedBefore` bytes have been decoded. C
            // reports the first problem in stream order: zlib's error when at most `limit` bytes came
            // before it (NETWORK), else "response too large" (PARSE), because inflate_chunk gives
            // zlib at most limit + 1 bytes of room and zlib stops when the room is full, before it
            // reaches the bad construct (wx-http.c:920-933). Compression.framework may hold the last
            // decoded bytes back when it meets the construct, so the cap is decided here, not by it.
            if case .invalid(let decodedBefore) = slice.withUnsafeBufferPointer({ validator.feed($0) }) {
                failure = decodedBefore <= limit ? .corrupt : .tooLarge
                return
            }
            let result = slice.withUnsafeBufferPointer { bytes in
                leading.process(bytes) { produced in
                    self.output.append(produced)
                    return self.output.count <= limit
                }
            }
            switch result {
            case .stopped:
                failure = .tooLarge
            case .corrupt:
                failure = .corrupt
            case .more:
                let replay = slice.withUnsafeBufferPointer { exact.process($0) { _ in true } }
                if case .more = replay {} else { failure = .corrupt }
            case .end:
                let rest = Array(pending[pendingStart...])
                pending = []
                pendingStart = 0
                exactSearching = true
                var whole = slice
                whole.append(contentsOf: rest)
                whole.withUnsafeBufferPointer { bytes in
                    let after = findExactEnd(bytes, from: 0)
                    if failure == nil, phase == .trailer, after < bytes.count {
                        appendTrailer(bytes[after...], sameRead: sameRead)
                    }
                }
            }
        }

        /// Feeds `exact` one byte at a time from `start` until it reports the end of the DEFLATE
        /// stream; returns the index just after the stream (the trailer starts there).
        private func findExactEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
            var i = start
            while i < bytes.count {
                let one = UnsafeBufferPointer(rebasing: bytes[i..<(i + 1)])
                switch exact.process(one, { _ in true }) {
                case .more:
                    i += 1
                case .end(let unused):
                    exactSearching = false
                    phase = .trailer
                    return i + 1 - unused
                case .corrupt, .stopped:
                    failure = .corrupt
                    return bytes.count
                }
            }
            return i
        }

        // MARK: Trailer

        /// Reads the CRC-32 and ISIZE right after the DEFLATE stream; any further byte is PARSE.
        private func appendTrailer(_ bytes: UnsafeBufferPointer<UInt8>.SubSequence, sameRead: Bool) {
            for byte in bytes {
                guard trailer.count < 8 else {
                    failure = sameRead ? .dataAfterEnd : .continuesAfterEnd
                    return
                }
                trailer.append(byte)
                if trailer.count == 8 {
                    let crc = HTTPClient.crc32(output)
                    let size = UInt32(truncatingIfNeeded: output.count)
                    let expected = [crc, size].flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
                    if trailer != expected {
                        failure = .corrupt
                        return
                    }
                }
            }
        }

        // MARK: zlib's checks (inflate.c TYPEDO...MATCH, inftrees.c inflate_table, zlib 1.3.1)

        /// Walks the DEFLATE block structure of the member over the same bytes as the decoders,
        /// without producing output, and makes every validity check zlib's inflate makes. GLib's
        /// decompressor is zlib, so C fails each of these streams (a GIO error: NETWORK), while
        /// Compression.framework decodes some of them (a stored block whose NLEN is not the one's
        /// complement of LEN, "invalid stored block lengths"). The checks: block type 3; stored
        /// LEN/NLEN; more than 286 literal/length or 30 distance codes; an incomplete or
        /// over-subscribed code-length code; a repeat of no previous length or past the last code
        /// length; no end-of-block code; an over-subscribed or incomplete literal/length or
        /// distance code (incomplete is allowed only as a single 1-bit code); literal/length
        /// symbols 286-287 and distance symbols 30-31; a distance beyond the bytes decoded so far.
        final class DeflateValidator {
            enum Verdict: Equatable {
                /// Valid so far; more input is needed.
                case more
                /// The final block ended; the gzip trailer starts at the next byte boundary.
                case end
                /// zlib refuses the stream; `decodedBefore` bytes were decoded before the construct.
                case invalid(decodedBefore: Int)
            }

            /// A canonical Huffman code as inflate_table checks it (puff.c's representation), with
            /// a lookup table for the codes of at most `rootBits` bits.
            private final class Code: Sendable {
                let count: [Int]
                let symbols: [Int]
                let maxLength: Int
                static let rootBits = 9
                /// Indexed by the next `rootBits` stream bits: symbol << 8 | length, 0 when the
                /// code is longer than `rootBits` (or unused).
                let table: [Int]

                /// nil for an over-subscribed set, or an incomplete one (allowed only when
                /// `incompleteAllowed` and the longest code is 1 bit long); a set of zero lengths
                /// only is a code with no symbols (zlib decodes one bit of it as invalid).
                init?(_ lengths: ArraySlice<Int>, incompleteAllowed: Bool) {
                    var count = [Int](repeating: 0, count: 16)
                    for length in lengths { count[length] += 1 }
                    let maxLength = (1...15).last { count[$0] != 0 } ?? 0
                    var symbols: [Int] = []
                    var table: [Int] = []
                    if maxLength > 0 {
                        var left = 1
                        for length in 1...15 {
                            left = left << 1 - count[length]
                            if left < 0 { return nil }
                        }
                        if left > 0 && !(incompleteAllowed && maxLength == 1) { return nil }
                        var offsets = [Int](repeating: 0, count: 16)
                        for length in 1..<15 { offsets[length + 1] = offsets[length] + count[length] }
                        symbols = [Int](repeating: 0, count: offsets[15] + count[15])
                        for (symbol, length) in zip(0..., lengths) where length != 0 {
                            symbols[offsets[length]] = symbol
                            offsets[length] += 1
                        }
                        // Canonical codes (RFC 1951 3.2.2) are sent most significant bit first, so
                        // a table index is the code with its bits reversed.
                        table = [Int](repeating: 0, count: 1 << Self.rootBits)
                        var next = [Int](repeating: 0, count: 16)
                        var code = 0
                        for length in 2...15 {
                            code = (code + count[length - 1]) << 1
                            next[length] = code
                        }
                        for (symbol, length) in zip(0..., lengths) where length != 0 {
                            let c = next[length]
                            next[length] += 1
                            guard length <= Self.rootBits else { continue }
                            var reversed = 0
                            for k in 0..<length { reversed |= (c >> k & 1) << (length - 1 - k) }
                            var index = reversed
                            while index < 1 << Self.rootBits {
                                table[index] = symbol << 8 | length
                                index += 1 << length
                            }
                        }
                    }
                    self.count = count
                    self.symbols = symbols
                    self.maxLength = maxLength
                    self.table = table
                }
            }

            private enum Mode {
                case header, storedLengths, stored(remaining: Int), tableSizes, codeLengthCodes, codeLengths, codes
            }

            /// RFC 1951 3.2.5 / inftrees.c lbase, lext, dbase, dext.
            private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                             35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
            private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                              3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
            private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
                                               513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
            private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
                                                8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
            /// inflate.c order[19].
            private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            /// fixedtables (inflate.c): 288 literal/length and 32 distance codes.
            private static let fixedLiterals = Code(
                (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 }[...], incompleteAllowed: true)!
            private static let fixedDistances = Code([Int](repeating: 5, count: 32)[...], incompleteAllowed: true)!

            private var input: [UInt8] = []
            private var bitPosition = 0
            private var verdict = Verdict.more
            private var mode = Mode.header
            private var lastBlock = false
            /// Bytes decoded so far (saturating), for the distance check and the verdict.
            private var decoded = 0
            private var literalCount = 0, distanceCount = 0, codeLengthCount = 0
            private var lengths: [Int] = []
            private var codeLengthCode: Code?
            private var literalCode: Code?
            private var distanceCode: Code?

            /// Feeds the next bytes of the DEFLATE data; once the verdict is not `.more` it stays.
            func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> Verdict {
                guard verdict == .more else { return verdict }
                input.append(contentsOf: bytes)
                while verdict == .more {
                    let start = bitPosition
                    guard step() else {
                        bitPosition = start  // the unit is incomplete: wait for more input
                        break
                    }
                }
                if bitPosition >= 1 << 19 {
                    input.removeFirst(bitPosition >> 3)
                    bitPosition &= 7
                }
                return verdict
            }

            private var availableBits: Int { input.count * 8 - bitPosition }

            /// The next `n` (<= 16) bits, LSB first (RFC 1951 3.1.1), without consuming them; the
            /// caller has checked that they have arrived.
            private func peek(_ n: Int) -> Int {
                var value = 0, got = 0, p = bitPosition
                while got < n {
                    let take = min(8 - p & 7, n - got)
                    value |= (Int(input[p >> 3]) >> (p & 7) & (1 << take - 1)) << got
                    got += take
                    p += take
                }
                return value
            }

            /// The next `n` (<= 16) bits, or nil when they have not arrived.
            private func bits(_ n: Int) -> Int? {
                guard availableBits >= n else { return nil }
                let value = peek(n)
                bitPosition += n
                return value
            }

            private enum Symbol {
                case symbol(Int)
                /// A bit pattern no symbol has (an incomplete single-code set).
                case unused
                /// The code has no symbols at all (zlib: one bit read, an invalid entry of value 0).
                case none
            }

            /// One Huffman symbol (puff.c decode), or nil when more input is needed.
            private func decode(_ code: Code) -> Symbol? {
                if code.maxLength == 0 { return bits(1) == nil ? nil : Symbol.none }
                // Table first: an entry whose length the arrived bits cover is the symbol (a code of
                // length L fills every index whose low L bits are its reversed code).
                let available = min(availableBits, Code.rootBits)
                if available > 0 {
                    let entry = code.table[peek(available)]
                    if entry != 0 {
                        let length = entry & 0xFF
                        guard length <= available else { return nil }
                        bitPosition += length
                        return .symbol(entry >> 8)
                    }
                }
                var value = 0, first = 0, index = 0
                for length in 1...code.maxLength {
                    guard let bit = bits(1) else { return nil }
                    value |= bit
                    let count = code.count[length]
                    if value - count < first { return .symbol(code.symbols[index + value - first]) }
                    index += count
                    first = (first + count) << 1
                    value <<= 1
                }
                return .unused
            }

            private func refuse() -> Bool {
                verdict = .invalid(decodedBefore: decoded)
                return true
            }

            private func produce(_ n: Int) {
                decoded = min(decoded + n, 1 << 40)
            }

            /// Completes one unit (a block header, stored lengths, a piece of stored data, the
            /// table sizes, the code-length code, one code length, one symbol); false when its bits
            /// have not all arrived (nothing is changed then).
            private func step() -> Bool {
                switch mode {
                case .header:
                    if lastBlock {
                        verdict = .end
                        return true
                    }
                    guard let header = bits(3) else { return false }
                    lastBlock = header & 1 == 1
                    switch header >> 1 {
                    case 0: mode = .storedLengths
                    case 1:
                        literalCode = Self.fixedLiterals
                        distanceCode = Self.fixedDistances
                        mode = .codes
                    case 2: mode = .tableSizes
                    default: return refuse()  // "invalid block type"
                    }
                    return true
                case .storedLengths:
                    let aligned = (bitPosition + 7) & ~7
                    guard input.count * 8 - aligned >= 32 else { return false }
                    bitPosition = aligned
                    let length = bits(16)!, complement = bits(16)!
                    guard length == complement ^ 0xFFFF else { return refuse() }  // "invalid stored block lengths"
                    mode = length == 0 ? .header : .stored(remaining: length)
                    return true
                case .stored(let remaining):
                    let available = input.count - bitPosition >> 3
                    guard available > 0 else { return false }
                    let n = min(remaining, available)
                    bitPosition += n * 8
                    produce(n)
                    mode = n == remaining ? .header : .stored(remaining: remaining - n)
                    return true
                case .tableSizes:
                    guard let sizes = bits(14) else { return false }
                    literalCount = sizes & 31 + 257
                    distanceCount = sizes >> 5 & 31 + 1
                    codeLengthCount = sizes >> 10 + 4
                    if literalCount > 286 || distanceCount > 30 { return refuse() }  // "too many length or distance symbols"
                    mode = .codeLengthCodes
                    return true
                case .codeLengthCodes:
                    guard availableBits >= 3 * codeLengthCount else { return false }
                    var codeLengths = [Int](repeating: 0, count: 19)
                    for k in 0..<codeLengthCount { codeLengths[Self.codeLengthOrder[k]] = bits(3)! }
                    guard let code = Code(codeLengths[...], incompleteAllowed: false) else { return refuse() }  // "invalid code lengths set"
                    codeLengthCode = code
                    lengths = []
                    mode = .codeLengths
                    return true
                case .codeLengths:
                    guard let symbol = decode(codeLengthCode!) else { return false }
                    var value = 0
                    switch symbol {
                    case .symbol(let s): value = s
                    case .none: value = 0       // zlib uses the invalid entry's value 0 here
                    case .unused: return refuse()  // cannot happen: the code-length code is complete
                    }
                    let total = literalCount + distanceCount
                    if value < 16 {
                        lengths.append(value)
                    } else {
                        var repeated = 0, copies = 0
                        switch value {
                        case 16:
                            guard let r = bits(2) else { return false }
                            guard let previous = lengths.last else { return refuse() }  // "invalid bit length repeat"
                            repeated = previous
                            copies = 3 + r
                        case 17:
                            guard let r = bits(3) else { return false }
                            copies = 3 + r
                        default:
                            guard let r = bits(7) else { return false }
                            copies = 11 + r
                        }
                        if lengths.count + copies > total { return refuse() }  // "invalid bit length repeat"
                        lengths += repeatElement(repeated, count: copies)
                    }
                    if lengths.count == total {
                        if lengths[256] == 0 { return refuse() }  // "invalid code -- missing end-of-block"
                        guard let literals = Code(lengths[..<literalCount], incompleteAllowed: true) else {
                            return refuse()  // "invalid literal/lengths set"
                        }
                        guard let distances = Code(lengths[literalCount...], incompleteAllowed: true) else {
                            return refuse()  // "invalid distances set"
                        }
                        literalCode = literals
                        distanceCode = distances
                        mode = .codes
                    }
                    return true
                case .codes:
                    guard let symbol = decode(literalCode!) else { return false }
                    guard case .symbol(let s) = symbol, s <= 285 else { return refuse() }  // "invalid literal/length code"
                    if s < 256 {
                        produce(1)
                        return true
                    }
                    if s == 256 {
                        mode = .header
                        return true
                    }
                    guard let lengthBits = bits(Self.lengthExtra[s - 257]) else { return false }
                    let length = Self.lengthBase[s - 257] + lengthBits
                    guard let distanceSymbol = decode(distanceCode!) else { return false }
                    guard case .symbol(let d) = distanceSymbol, d <= 29 else { return refuse() }  // "invalid distance code"
                    guard let distanceBits = bits(Self.distanceExtra[d]) else { return false }
                    if Self.distanceBase[d] + distanceBits > decoded { return refuse() }  // "invalid distance too far back"
                    produce(length)
                    return true
                }
            }
        }
    }

    /// A raw DEFLATE decoder (Compression.framework COMPRESSION_ZLIB) fed by the caller.
    private final class InflateStream {
        enum Step {
            /// Every input byte was consumed and the stream has not ended.
            case more
            /// The stream ended; `unused` input bytes were left over.
            case end(unused: Int)
            /// Invalid data (or no progress).
            case corrupt
            /// The sink refused more output.
            case stopped
        }

        private var stream: compression_stream
        private let ready: Bool
        private let buffer: UnsafeMutablePointer<UInt8>
        private let capacity = HTTPPolicy.readChunk

        init() {
            stream = compression_stream(
                dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
            ready = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
            buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        }

        deinit {
            if ready { compression_stream_destroy(&stream) }
            buffer.deallocate()
        }

        /// Decodes all of `input`, handing each produced piece to `sink` (false: stop).
        func process(_ input: UnsafeBufferPointer<UInt8>, _ sink: (UnsafeBufferPointer<UInt8>) -> Bool) -> Step {
            guard ready else { return .corrupt }
            guard let base = input.baseAddress, !input.isEmpty else { return .more }
            stream.src_ptr = base
            stream.src_size = input.count
            while true {
                let before = stream.src_size
                stream.dst_ptr = buffer
                stream.dst_size = capacity
                let status = compression_stream_process(&stream, 0)
                let produced = capacity - stream.dst_size
                if produced > 0, !sink(UnsafeBufferPointer(start: buffer, count: produced)) { return .stopped }
                switch status {
                case COMPRESSION_STATUS_END:
                    return .end(unused: stream.src_size)
                case COMPRESSION_STATUS_OK:
                    if stream.src_size == 0 && stream.dst_size > 0 { return .more }
                    if produced == 0 && stream.src_size == before { return .corrupt }
                default:
                    return .corrupt
                }
            }
        }
    }

    /// CRC-32 (IEEE 802.3, reflected 0xEDB88320), as in the gzip trailer.
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crc32Update(c, byte) }
        return c ^ 0xFFFF_FFFF
    }

    /// One step of the running (pre-inverted) CRC-32.
    static func crc32Update(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
}
