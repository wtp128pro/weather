// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// LoopbackServer.swift - scriptable HTTP/1.1 fake server for the unhosted
// WeatherCoreTests bundle. It is the Swift counterpart of the GSocketService
// fakes in the C tests (src/net/test-http.c:1503-1523 step kinds,
// :1645-1755 handle_request, :1795-1815 fake_new; the path-routed fakes of
// test-nws.c, test-metno.c and test-openmeteo.c). Differences from the C
// fakes, on purpose:
//   - it binds 127.0.0.1 only (the C fakes bind every interface);
//   - it runs on its own serial dispatch queue (Network.framework), not on
//     the test's main loop, so tests await it instead of iterating a loop;
//   - STEP_RAW and STEP_BYTES are one step, `.raw(Data)`;
//   - STEP_BYTES_SPLIT generalises to `.bytesSplit(_:at:interval:)` (any
//     number of split points; `.drip` builds evenly spaced ones);
//   - `.truncated` (test-nws.c R_TRUNCATED) and `.hold` + `release()`
//     (test-metno.c R_HOLD) are steps of the same server;
//   - test-metno.c's ReplyFn (fake_new_fn, :1708) is the `.compute` step (or
//     `init(reply:)`), evaluated when the request arrives, so it can read
//     state the test changes mid-test (test-metno.c:4209 `state.calm`);
//   - `closedEarlyCount` (test-metno.c:1536 closed_early, counted at
//     :1657-1663) also counts `.bytesHang` and `.hold` connections, and
//     `connectionCount` is test-metno.c:1691 `fake->connections`.
//
// Usage:
//   let server = try LoopbackServer([.respond(status: 503), .respond(body: Data("{}".utf8))])
//   defer { server.stop() }
//   let (data, response) = try await session.data(from: server.url("/v1/forecast?x=1"))
//   #expect(server.requests.map(\.path) == ["/v1/forecast?x=1", ...])
//
// Every request reads the request head (up to CRLF CRLF), is recorded, and is
// answered by the next step of the script it routes to; the last step of a
// script repeats. Every answer carries `Connection: close` (or, for raw
// steps, whatever the test wrote) and the server closes the connection after
// it, like the C fakes.

import Foundation
import Network

/// A scriptable HTTP/1.1 server on 127.0.0.1:<ephemeral port> for tests.
///
/// Thread safety: all mutable state is confined to the private serial
/// `queue`; every public accessor hops onto it synchronously. That is why the
/// class is `@unchecked Sendable` (NWListener/NWConnection are not Sendable).
final class LoopbackServer: @unchecked Sendable {

    // MARK: Script

    /// One scripted answer (C: `Step`/`StepKind`, src/net/test-http.c:1503-1523).
    enum Step: Sendable {
        /// STEP_RESPOND: `HTTP/1.1 <status> X`, `Content-Type: application/json`,
        /// the extra `headers` lines (each "Name: value", no CRLF), a matching
        /// `Content-Length`, `Connection: close`, then `body`; sent after
        /// `delay`, then the connection is closed.
        case respond(status: Int = 200, headers: [String] = [], body: Data = Data(), delay: Duration = .zero)
        /// STEP_HANG: read the request, never answer (the connection stays
        /// open and counted active until `stop()`).
        case hang
        /// STEP_CLOSE: close the connection without answering.
        case close
        /// STEP_BIG_STREAMED: `200 OK` without Content-Length, then `size`
        /// zero bytes in 64 KiB chunks, then close. A `size` <= 0 means the
        /// 5 MiB default, as in C (`step->size > 0 ? step->size : 5 MiB`,
        /// src/net/test-http.c:1737).
        case bigStreamed(size: Int = 5 * 1024 * 1024)
        /// STEP_BIG_DECLARED: `200 OK` declaring `Content-Length: size`, then
        /// only the two bytes `{}`, then close.
        case bigDeclared(size: Int)
        /// STEP_GZIP: `200 OK`, `Content-Encoding: gzip`, the extra
        /// `headers`, the gzip member of `body` with a matching
        /// Content-Length, then close.
        case gzip(body: Data, headers: [String] = [])
        /// Truncated body (test-nws.c R_TRUNCATED): like `.respond` with a
        /// Content-Length of the whole `body`, but only its first `sent`
        /// bytes are written before the connection is closed.
        case truncated(status: Int = 200, headers: [String] = [], body: Data, sent: Int)
        /// STEP_RAW / STEP_BYTES: the complete raw response (binary allowed),
        /// sent verbatim, then close.
        case raw(Data)
        /// STEP_BYTES_HANG: the bytes verbatim, then the connection stays open
        /// and silent until `stop()`.
        case bytesHang(Data)
        /// STEP_BYTES_SPLIT, generalised: the raw bytes cut at the offsets
        /// `at` (ascending; out-of-range offsets are ignored); the first piece
        /// is sent at once, each further piece `interval` after the previous
        /// one, then close.
        case bytesSplit(Data, at: [Int], interval: Duration)
        /// Held answer (test-metno.c R_HOLD): an answer built like `.respond`
        /// that is sent only when the test calls `release()`.
        case hold(status: Int = 200, headers: [String] = [], body: Data = Data())
        /// A reply computed when the request arrives (C: test-metno.c ReplyFn,
        /// :1512, fake_new_fn :1708). `index` is the 0-based number of this
        /// request among the requests answered by the same script (for a
        /// one-script server it is C's `index`, the request number); `request`
        /// is the request just recorded. The closure runs on the server's
        /// queue, may read state the test mutates during the test (use
        /// `LoopbackServer.Shared`), and returns the step that answers; a
        /// returned `.compute` is evaluated again (at most 8 levels, then the
        /// connection is closed).
        case compute(@Sendable (_ index: Int, _ request: Request) -> Step)

        /// `.respond` with a UTF-8 text body.
        static func text(_ body: String, status: Int = 200, headers: [String] = [], delay: Duration = .zero) -> Step {
            .respond(status: status, headers: headers, body: Data(body.utf8), delay: delay)
        }

        /// `.raw` with a UTF-8 text response.
        static func rawText(_ response: String) -> Step {
            .raw(Data(response.utf8))
        }

        /// `.bytesSplit` that drip-feeds `bytes` in pieces of `chunkSize`
        /// bytes, `interval` apart.
        static func drip(_ bytes: Data, chunkSize: Int, interval: Duration) -> Step {
            let size = max(1, chunkSize)
            return .bytesSplit(bytes, at: Array(stride(from: size, to: bytes.count, by: size)), interval: interval)
        }
    }

    /// A path-routed script: requests whose request target starts with
    /// `prefix` are answered by `steps` in order (the last step repeats).
    struct Route: Sendable {
        let prefix: String
        let steps: [Step]

        init(_ prefix: String, _ steps: [Step]) {
            self.prefix = prefix
            self.steps = steps
        }
    }

    /// One recorded request (C: `fake->paths`, `fake->heads`, `fake->arrivals_us`).
    struct Request: Sendable {
        /// The request method, e.g. "GET".
        let method: String
        /// The request target as sent, e.g. "/points/25.7617,-80.1918".
        let path: String
        /// The complete request head, request line through the final CRLF CRLF.
        let head: String
        /// The header lines of the head (without the request line and CRLFs).
        let headerLines: [String]
        /// Monotonic arrival time (when the complete head had been read).
        let arrival: ContinuousClock.Instant

        /// Every value of the header `name` (case-insensitive), in order.
        func headers(_ name: String) -> [String] {
            headerLines.compactMap { line in
                guard let colon = line.firstIndex(of: ":"),
                    line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
                else { return nil }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }

        /// The first value of the header `name` (case-insensitive), or nil.
        func header(_ name: String) -> String? {
            headers(name).first
        }
    }

    /// A lock-protected value a test shares with `.compute` closures (which
    /// run on the server's queue) and mutates during the test, e.g. the
    /// stress test's `state.calm` (test-metno.c:4209).
    final class Shared<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) {
            stored = value
        }

        /// The current value (read and written under the lock).
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }

        /// Runs `body` with exclusive access to the value.
        @discardableResult
        func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
            lock.lock()
            defer { lock.unlock() }
            return try body(&stored)
        }
    }

    /// Thrown when the listener cannot be started.
    struct StartError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Public state

    /// The ephemeral port the server listens on (127.0.0.1 only).
    var port: UInt16 { boundPort }

    /// `http://127.0.0.1:<port>`.
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// `baseURL` followed by `pathAndQuery` (which starts with "/").
    func url(_ pathAndQuery: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(pathAndQuery)")!
    }

    /// Every request received so far, in arrival order.
    var requests: [Request] { onQueue { recorded } }
    /// The request targets of every request, in arrival order.
    var paths: [String] { onQueue { recorded.map(\.path) } }
    /// The number of requests received so far (C: `fake->requests`).
    var requestCount: Int { onQueue { recorded.count } }
    /// Requests between arrival and the end of their answer (C: `fake->active`);
    /// hanging requests stay counted until `stop()`.
    var activeCount: Int { onQueue { active } }
    /// The largest `activeCount` seen (C: `fake->max_active`).
    var maxActiveCount: Int { onQueue { maxActive } }
    /// The number of `.hold` answers waiting for `release()`.
    var heldCount: Int { onQueue { conns.values.filter { $0.heldAnswer != nil }.count } }
    /// `.bigStreamed` body bytes handed to the network stack (C: `fake->big_sent`).
    var bigStreamedBytesSent: Int { onQueue { bigSent } }
    /// Connections whose client closed (end of stream or error) while their
    /// request was parked by `.hang`, `.bytesHang` or an unreleased `.hold`
    /// (C: test-metno.c:1536 `closed_early`, counted at :1657-1663). `stop()`
    /// does not count. Such a connection stays in `activeCount` (and a held
    /// answer in `heldCount`) until `stop()`/`release()`, as before.
    var closedEarlyCount: Int { onQueue { closedEarly } }
    /// Connections accepted, with or without a request (C: test-metno.c:1691
    /// `fake->connections`, asserted at :2650 and :3652).
    var connectionCount: Int { onQueue { accepted } }

    // MARK: Lifecycle

    /// A server whose single script answers every request.
    convenience init(_ steps: [Step]) throws {
        try self.init(routes: [Route("", steps)])
    }

    /// A server whose every reply is computed when the request arrives
    /// (C: test-metno.c fake_new_fn(ReplyFn, data), :1708); `index` is the
    /// request number from 0. Same as `init([.compute(reply)])`.
    convenience init(reply: @escaping @Sendable (_ index: Int, _ request: Request) -> Step) throws {
        try self.init([.compute(reply)])
    }

    /// A path-routed server: the first route whose prefix starts the request
    /// target answers it; unmatched requests get `fallback` (default: 404).
    init(routes: [Route], fallback: [Step] = [.text("{}", status: 404)]) throws {
        precondition(routes.allSatisfy { !$0.steps.isEmpty } && !fallback.isEmpty, "empty script")
        self.routes = routes
        self.fallback = fallback
        self.routeCounters = Array(repeating: 0, count: routes.count + 1)
        queue.setSpecific(key: queueKey, value: ())

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartError(description: "NWListener: \(error)")
        }
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let outcome = StartOutcome()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.set(ready: true)
                ready.signal()
            case .failed(let error), .waiting(let error):
                outcome.set(error: "\(error)")
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        let signalled = ready.wait(timeout: .now() + 5) == .success
        listener.stateUpdateHandler = nil
        guard signalled, outcome.isReady, let bound = listener.port?.rawValue, bound != 0 else {
            stop()
            throw StartError(description: "listener did not become ready: \(outcome.error ?? "timeout")")
        }
        boundPort = bound
    }

    deinit {
        // Either no callback holds the server (they capture it weakly) or this
        // runs inside one, on `queue`: direct access is confined either way.
        tearDown()
    }

    /// Stops listening and closes every connection, including hanging and
    /// held ones (C: fake_free). Idempotent.
    func stop() {
        onQueue { tearDown() }
    }

    /// Sends every held answer now; returns how many were released. Answers
    /// held after this call wait for the next `release()`.
    @discardableResult
    func release() -> Int {
        onQueue {
            let held = conns.values.filter { $0.heldAnswer != nil }.sorted { $0.id < $1.id }
            for conn in held {
                let answer = conn.heldAnswer!
                conn.heldAnswer = nil
                conn.parked = false
                sendFinal(conn, answer)
            }
            return held.count
        }
    }

    /// Polls `condition` every 5 ms until it holds or `timeout` elapses;
    /// returns whether it held.
    func waitUntil(timeout: Duration = .seconds(5), _ condition: (LoopbackServer) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if condition(self) { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits until at least `count` requests have arrived.
    func waitForRequests(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        await waitUntil(timeout: timeout) { $0.requestCount >= count }
    }

    /// The gzip member (RFC 1952) of `data`: header, raw DEFLATE, CRC-32 and
    /// ISIZE trailer. Used by `.gzip`; available to tests that need gzip bytes.
    static func gzip(_ data: Data) -> Data {
        var member = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        if data.isEmpty {
            member.append(contentsOf: [0x03, 0x00])  // one empty final fixed-Huffman block
        } else {
            // NSData's .zlib algorithm emits raw DEFLATE (RFC 1951), no zlib wrapper.
            guard let deflated = try? (data as NSData).compressed(using: .zlib) else {
                preconditionFailure("DEFLATE of \(data.count) bytes failed")
            }
            member.append(deflated as Data)
        }
        appendLittleEndian(crc32(data), to: &member)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &member)
        return member
    }

    // MARK: Private

    /// One accepted connection (C: `Conn`). Confined to `queue`.
    private final class Conn: @unchecked Sendable {
        let id: Int
        let connection: NWConnection
        var buffer = Data()
        var active = false
        var heldAnswer: Data?
        /// Parked by `.hang`, `.bytesHang` or `.hold`: a client close counts
        /// in `closedEarly`.
        var parked = false
        var clientClosed = false

        init(id: Int, connection: NWConnection) {
            self.id = id
            self.connection = connection
        }
    }

    /// The listener's start result, written by its state handler.
    private final class StartOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var storedError: String?
        var isReady: Bool { lock.withLock { ready } }
        var error: String? { lock.withLock { storedError } }
        func set(ready: Bool) { lock.withLock { self.ready = ready } }
        func set(error: String) { lock.withLock { if storedError == nil { storedError = error } } }
    }

    private static let headEnd = Data("\r\n\r\n".utf8)
    private static let chunkSize = 64 * 1024

    private let queue = DispatchQueue(label: "LoopbackServer")
    private let queueKey = DispatchSpecificKey<Void>()
    private let listener: NWListener
    private let routes: [Route]
    private let fallback: [Step]
    private var routeCounters: [Int]
    private var recorded: [Request] = []
    private var conns: [Int: Conn] = [:]
    private var nextID = 0
    private var active = 0
    private var maxActive = 0
    private var bigSent = 0
    private var closedEarly = 0
    private var accepted = 0
    private var stopped = false
    private var boundPort: UInt16 = 0

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? body() : queue.sync(execute: body)
    }

    private func tearDown() {
        guard !stopped else { return }
        stopped = true
        listener.newConnectionHandler = nil
        listener.cancel()
        for conn in conns.values.sorted(by: { $0.id < $1.id }) {
            finish(conn)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        nextID += 1
        accepted += 1
        let conn = Conn(id: nextID, connection: connection)
        conns[conn.id] = conn
        connection.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .failed:
                // The client reset the connection (finish() clears this
                // handler first, so stop() never gets here).
                if let self, let conn {
                    self.noteClientClosed(conn)
                    self.finish(conn)
                }
            case .cancelled:
                if let self, let conn { self.finish(conn) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        readHead(conn)
    }

    /// C: conn_read/read_done — read until CRLF CRLF, then answer.
    private func readHead(_ conn: Conn) {
        conn.connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) {
            [weak self] data, _, isComplete, error in
            guard let self, self.conns[conn.id] != nil else { return }
            if let data { conn.buffer.append(data) }
            if let end = conn.buffer.range(of: Self.headEnd) {
                self.handle(conn, head: conn.buffer[..<end.upperBound])
            } else if isComplete || error != nil {
                self.finish(conn)
            } else {
                self.readHead(conn)
            }
        }
    }

    /// C: R_HANG's `conn_read` after the answer was parked (test-metno.c:1643-1646,
    /// :1660-1667): keep reading; end of stream or an error means the client
    /// gave up. Bytes the client sends meanwhile are ignored.
    private func watchParked(_ conn: Conn) {
        conn.connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) {
            [weak self] _, _, isComplete, error in
            guard let self, self.conns[conn.id] != nil, conn.parked, !conn.clientClosed else { return }
            if isComplete || error != nil {
                self.noteClientClosed(conn)
            } else {
                self.watchParked(conn)
            }
        }
    }

    /// C: `closed_early++` (test-metno.c:1660-1661), once per parked connection.
    private func noteClientClosed(_ conn: Conn) {
        guard conn.parked, !conn.clientClosed else { return }
        conn.clientClosed = true
        closedEarly += 1
    }

    /// C: conn_free — closes the connection and ends its active span.
    private func finish(_ conn: Conn) {
        guard conns.removeValue(forKey: conn.id) != nil else { return }
        if conn.active {
            conn.active = false
            active -= 1
        }
        conn.heldAnswer = nil
        conn.connection.stateUpdateHandler = nil
        conn.connection.cancel()
    }

    /// C: handle_request.
    private func handle(_ conn: Conn, head: Data) {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        let method = requestLine.first.map(String.init) ?? ""
        let path = requestLine.count > 1 ? String(requestLine[1]) : ""
        recorded.append(
            Request(method: method, path: path, head: text, headerLines: Array(lines.dropFirst()),
                    arrival: .now))
        conn.active = true
        active += 1
        maxActive = max(maxActive, active)

        let routeIndex = routes.firstIndex { path.hasPrefix($0.prefix) } ?? routes.count
        let steps = routeIndex < routes.count ? routes[routeIndex].steps : fallback
        let index = routeCounters[routeIndex]
        var step = steps[min(index, steps.count - 1)]
        routeCounters[routeIndex] += 1
        var depth = 0
        while case .compute(let reply) = step {
            depth += 1
            step = depth <= 8 ? reply(index, recorded[recorded.count - 1]) : .close
        }

        switch step {
        case .respond(let status, let headers, let body, let delay):
            let answer = Self.response(status: status, headers: headers, body: body)
            if delay > .zero {
                queue.asyncAfter(deadline: .now() + Self.interval(delay)) { [weak self] in
                    guard let self, self.conns[conn.id] != nil else { return }
                    self.sendFinal(conn, answer)
                }
            } else {
                sendFinal(conn, answer)
            }
        case .hang:
            conn.parked = true
            watchParked(conn)
        case .close:
            finish(conn)
        case .bigStreamed(let size):
            let head = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".utf8)
            sendPartial(conn, head) { $0.streamBig(conn, remaining: size > 0 ? size : 5 * 1024 * 1024) }
        case .bigDeclared(let size):
            sendFinal(conn, Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(size)"
                + "\r\nConnection: close\r\n\r\n{}").utf8))
        case .gzip(let body, let headers):
            let packed = Self.gzip(body)
            var answer = Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\n"
                + headers.map { $0 + "\r\n" }.joined()
                + "Content-Length: \(packed.count)\r\nConnection: close\r\n\r\n").utf8)
            answer.append(packed)
            sendFinal(conn, answer)
        case .truncated(let status, let headers, let body, let sent):
            let answer = Self.response(status: status, headers: headers, body: body)
            let headLength = answer.count - body.count
            sendFinal(conn, answer.prefix(headLength + min(max(0, sent), body.count)))
        case .raw(let bytes):
            sendFinal(conn, bytes)
        case .bytesHang(let bytes):
            conn.parked = true
            watchParked(conn)
            sendPartial(conn, bytes) { _ in }
        case .bytesSplit(let bytes, let offsets, let interval):
            var cuts = [0]
            for offset in offsets.sorted() where offset > cuts.last! && offset < bytes.count {
                cuts.append(offset)
            }
            cuts.append(bytes.count)
            let pieces = zip(cuts, cuts.dropFirst()).map { bytes[bytes.startIndex + $0 ..< bytes.startIndex + $1] }
            dripPieces(conn, ArraySlice(pieces.map { Data($0) }), interval: interval)
        case .hold(let status, let headers, let body):
            conn.heldAnswer = Self.response(status: status, headers: headers, body: body)
            conn.parked = true
            watchParked(conn)
        case .compute:
            finish(conn)  // unreachable: resolved above
        }
    }

    private func streamBig(_ conn: Conn, remaining: Int) {
        guard remaining > 0 else {
            sendFinal(conn, Data())
            return
        }
        let n = min(remaining, Self.chunkSize)
        bigSent += n
        sendPartial(conn, Data(count: n)) { $0.streamBig(conn, remaining: remaining - n) }
    }

    private func dripPieces(_ conn: Conn, _ pieces: ArraySlice<Data>, interval: Duration) {
        guard let first = pieces.first else { return }
        if pieces.count == 1 {
            sendFinal(conn, first)
            return
        }
        sendPartial(conn, first) { server in
            server.queue.asyncAfter(deadline: .now() + Self.interval(interval)) { [weak server] in
                guard let server, server.conns[conn.id] != nil else { return }
                server.dripPieces(conn, pieces.dropFirst(), interval: interval)
            }
        }
    }

    /// Sends `bytes`, then closes the write side and the connection.
    private func sendFinal(_ conn: Conn, _ bytes: Data) {
        conn.connection.send(
            content: bytes, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.finish(conn)
            })
    }

    /// Sends `bytes` and calls `next` once the stack took them; closes the
    /// connection instead when the send failed (the client went away).
    private func sendPartial(_ conn: Conn, _ bytes: Data, then next: @escaping @Sendable (LoopbackServer) -> Void) {
        conn.connection.send(
            content: bytes,
            completion: .contentProcessed { [weak self] error in
                guard let self, self.conns[conn.id] != nil else { return }
                if error != nil {
                    self.finish(conn)
                } else {
                    next(self)
                }
            })
    }

    /// C: the STEP_RESPOND head (src/net/test-http.c:1666-1668).
    private static func response(status: Int, headers: [String], body: Data) -> Data {
        var answer = Data(("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n"
            + headers.map { $0 + "\r\n" }.joined()
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
        answer.append(body)
        return answer
    }

    private static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }

    /// CRC-32 (ISO-HDLC, reflected polynomial 0xEDB88320) as gzip uses it.
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF),
                                 UInt8(value >> 24)])
    }
}
