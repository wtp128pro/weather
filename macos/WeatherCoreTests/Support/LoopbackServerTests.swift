// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// LoopbackServerTests.swift - self-test of the loopback fake server: every
// step kind is observed through URLSession (the transport the port uses), so
// a downstream HTTP/provider test that relies on a step relies on behaviour
// proven here, offline. The step semantics are the C fake's
// (src/net/test-http.c:1503-1523, handle_request :1645-1755); expected
// literals are chosen by the test, not read back from the server.

import Foundation
import Network
import Testing

@Suite(.serialized) struct LoopbackServerTests {

    // MARK: Binding and records

    @Test func bindsOnlyLoopbackOnAnEphemeralPort() async throws {
        let server = try LoopbackServer([.text("{}")])
        defer { server.stop() }
        #expect(server.port != 0)
        #expect(server.baseURL.absoluteString == "http://127.0.0.1:\(server.port)")
        // Positive control: the probe reaches the listener on 127.0.0.1.
        #expect(await Self.tcpConnects(host: "127.0.0.1", port: server.port))
        // Not bound to the IPv6 loopback nor to any non-loopback interface
        // address of this machine (a wildcard bind would accept them).
        #expect(!(await Self.tcpConnects(host: "::1", port: server.port)), "listener accepts on ::1")
        let others = Self.nonLoopbackIPv4Addresses()
        for address in others {
            #expect(!(await Self.tcpConnects(host: address, port: server.port)), "listener accepts on \(address)")
        }
        // The probes sent no request.
        #expect(server.requestCount == 0)
    }

    @Test func recordsPathHeaderLinesAndMonotonicArrival() async throws {
        // C: fake->paths / heads / arrivals_us (src/net/test-http.c:1648-1655).
        let server = try LoopbackServer([.text("{}")])
        defer { server.stop() }
        let session = Self.session()
        var request = URLRequest(url: server.url("/v1/forecast?latitude=25.7617&longitude=-80.1918"))
        request.setValue("LoopbackTest/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("first", forHTTPHeaderField: "X-Probe")
        let before = ContinuousClock.now
        _ = try await session.data(for: request)
        _ = try await session.data(from: server.url("/second"))
        let after = ContinuousClock.now

        let recorded = server.requests
        try #require(recorded.count == 2)
        #expect(server.paths == ["/v1/forecast?latitude=25.7617&longitude=-80.1918", "/second"])
        #expect(recorded[0].method == "GET")
        #expect(recorded[0].head.hasPrefix("GET /v1/forecast?latitude=25.7617&longitude=-80.1918 HTTP/1.1\r\n"))
        #expect(recorded[0].head.hasSuffix("\r\n\r\n"))
        #expect(recorded[0].header("user-agent") == "LoopbackTest/1.0")
        #expect(recorded[0].headerLines.contains("X-Probe: first"), "\(recorded[0].headerLines)")
        #expect(recorded[0].header("Host") == "127.0.0.1:\(server.port)")
        #expect(recorded[1].header("X-Probe") == nil)
        #expect(before <= recorded[0].arrival && recorded[0].arrival <= recorded[1].arrival
            && recorded[1].arrival <= after)
    }

    @Test func countsActiveAndMaxActiveConnections() async throws {
        // C: fake->active / max_active (src/net/test-http.c:1656-1658).
        let server = try LoopbackServer([.text("{\"slow\":true}", delay: .milliseconds(400))])
        defer { server.stop() }
        let session = Self.session()
        let bodies = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<3 {
                group.addTask {
                    let (data, _) = try await session.data(from: server.url("/c\(index)"))
                    return String(decoding: data, as: UTF8.self)
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(bodies == Array(repeating: "{\"slow\":true}", count: 3))
        #expect(server.maxActiveCount == 3)
        #expect(await server.waitUntil { $0.activeCount == 0 }, "active stayed \(server.activeCount)")
        #expect(server.requestCount == 3)
    }

    // MARK: Step kinds

    @Test func respondSendsStatusHeadersAndBody() async throws {
        // C: STEP_RESPOND head "HTTP/1.1 %u X", application/json, extra lines,
        // Content-Length, Connection: close (src/net/test-http.c:1666-1668).
        let body = Data("{\"answer\":42}".utf8)
        let server = try LoopbackServer([.respond(status: 201, headers: ["X-Fake: one", "Cache-Control: max-age=5"],
                                                  body: body)])
        defer { server.stop() }
        let (data, response) = try await Self.session().data(from: server.url("/r"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 201)
        #expect(http.value(forHTTPHeaderField: "X-Fake") == "one")
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "max-age=5")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "13")
        #expect(data == body)
    }

    @Test func respondWaitsForItsDelay() async throws {
        // C: STEP_RESPOND delay_ms (src/net/test-http.c:1674-1676).
        let server = try LoopbackServer([.text("late", delay: .milliseconds(300))])
        defer { server.stop() }
        let start = ContinuousClock.now
        let (data, _) = try await Self.session().data(from: server.url("/d"))
        let elapsed = ContinuousClock.now - start
        #expect(String(decoding: data, as: UTF8.self) == "late")
        #expect(elapsed >= .milliseconds(300), "answered after \(elapsed)")
    }

    @Test func stepsAnswerInOrderAndTheLastRepeats() async throws {
        // C: fake_new "the last step repeats" (src/net/test-http.c:1795, 1654).
        let server = try LoopbackServer([.text("first", status: 503), .text("second", status: 200)])
        defer { server.stop() }
        let session = Self.session()
        var seen: [String] = []
        for index in 0..<3 {
            let (data, response) = try await session.data(from: server.url("/s\(index)"))
            seen.append("\((response as? HTTPURLResponse)?.statusCode ?? 0) \(String(decoding: data, as: UTF8.self))")
        }
        #expect(seen == ["503 first", "200 second", "200 second"])
    }

    @Test func hangNeverAnswersAndStaysActive() async throws {
        // C: STEP_HANG (src/net/test-http.c:1728-1731).
        let server = try LoopbackServer([.hang])
        defer { server.stop() }
        let error = await Self.urlError { _ = try await Self.session(timeout: 0.5).data(from: server.url("/h")) }
        #expect(error?.code == .timedOut, "\(String(describing: error))")
        #expect(server.requestCount >= 1)
        #expect(server.activeCount >= 1, "a hanging request is still being answered")
        server.stop()
        #expect(server.activeCount == 0)
    }

    @Test func closeDropsTheConnectionWithoutAnswer() async throws {
        // C: STEP_CLOSE (src/net/test-http.c:1732-1734).
        let server = try LoopbackServer([.close])
        defer { server.stop() }
        let start = ContinuousClock.now
        let error = await Self.urlError { _ = try await Self.session(timeout: 5).data(from: server.url("/x")) }
        #expect(error != nil)
        #expect(error?.code != .timedOut, "\(String(describing: error))")
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(server.requestCount >= 1)
    }

    @Test func bigStreamedSendsFiveMebibytesWithoutContentLength() async throws {
        // C: STEP_BIG_STREAMED default size 5 * 1024 * 1024 (src/net/test-http.c:1735-1743).
        let server = try LoopbackServer([.bigStreamed()])
        defer { server.stop() }
        let (data, response) = try await Self.session(timeout: 10).data(from: server.url("/big"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(http.expectedContentLength == -1)
        #expect(data.count == 5 * 1024 * 1024)
        #expect(data.allSatisfy { $0 == 0 })
        #expect(server.bigStreamedBytesSent == 5 * 1024 * 1024)
    }

    @Test func bigDeclaredNeverSatisfiesContentLength() async throws {
        // C: STEP_BIG_DECLARED, "{}" of a declared `size` (src/net/test-http.c:1744-1752).
        let server = try LoopbackServer([.bigDeclared(size: 1_000_000)])
        defer { server.stop() }
        let (received, length, error) = await Self.stream(server.url("/declared"), timeout: 5)
        #expect(length == 1_000_000)
        #expect(Data("{}".utf8).starts(with: received), "\(Array(received))")
        #expect(error != nil, "a short body must fail the transfer")
        // URLSession may drop the bytes that preceded the failure, so the
        // exact wire bytes are read with a plain TCP client.
        let (wire, closed) = await Self.rawExchange(port: server.port, path: "/declared")
        #expect(String(decoding: wire, as: UTF8.self) == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: 1000000\r\nConnection: close\r\n\r\n{}")
        #expect(closed, "the server must close after the short body")
    }

    @Test func truncatedSendsAPrefixOfTheDeclaredBody() async throws {
        // test-nws.c R_TRUNCATED: the declared body cut short, then close.
        let server = try LoopbackServer([.truncated(body: Data("0123456789".utf8), sent: 4)])
        defer { server.stop() }
        let (received, length, error) = await Self.stream(server.url("/t"), timeout: 5)
        #expect(length == 10)
        #expect(Data("0123".utf8).starts(with: received), "\(Array(received))")
        #expect(error != nil, "a truncated body must fail the transfer")
        let (wire, closed) = await Self.rawExchange(port: server.port, path: "/t")
        #expect(String(decoding: wire, as: UTF8.self) == "HTTP/1.1 200 X\r\nContent-Type: application/json\r\n"
            + "Content-Length: 10\r\nConnection: close\r\n\r\n0123")
        #expect(closed, "the server must close after the truncated body")
    }

    @Test func gzipBodyIsAValidGzipMember() async throws {
        // C: STEP_GZIP, Content-Encoding: gzip + matching Content-Length
        // (src/net/test-http.c:1689-1702). URLSession's own decoder is the oracle.
        let body = Data(String(repeating: "{\"temperature\":21.5}", count: 200).utf8)
        let server = try LoopbackServer([.gzip(body: body, headers: ["X-Fake: zipped"])])
        defer { server.stop() }
        let (data, response) = try await Self.session().data(from: server.url("/gz"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(http.value(forHTTPHeaderField: "X-Fake") == "zipped")
        #expect(data == body)
        #expect(LoopbackServer.gzip(body).count < body.count / 4, "the wire body is compressed")
    }

    @Test func gzipTrailerCarriesCRC32AndSize() {
        // RFC 1952 member layout; CRC-32/ISO-HDLC check value of "123456789"
        // is 0xCBF43926 (standard CRC catalogue check value).
        let member = LoopbackServer.gzip(Data("123456789".utf8))
        #expect(Array(member.prefix(4)) == [0x1F, 0x8B, 0x08, 0x00])
        #expect(Array(member.suffix(8)) == [0x26, 0x39, 0xF4, 0xCB, 0x09, 0x00, 0x00, 0x00])
        let empty = LoopbackServer.gzip(Data())
        #expect(Array(empty.suffix(8)) == [0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func rawBytesAreSentVerbatim() async throws {
        // C: STEP_RAW / STEP_BYTES (src/net/test-http.c:1683-1688, 1703-1708).
        var response = Data("HTTP/1.1 418 Teapot\r\nX-Raw: yes\r\nContent-Length: 4\r\nConnection: close\r\n\r\n".utf8)
        response.append(contentsOf: [0x00, 0xFF, 0x80, 0x0A])
        let server = try LoopbackServer([.raw(response), .rawText("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")])
        defer { server.stop() }
        let session = Self.session()
        let (data, first) = try await session.data(from: server.url("/raw"))
        let http = try #require(first as? HTTPURLResponse)
        #expect(http.statusCode == 418)
        #expect(http.value(forHTTPHeaderField: "X-Raw") == "yes")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == nil, "raw responses add no header")
        #expect(Array(data) == [0x00, 0xFF, 0x80, 0x0A])
        let (empty, second) = try await session.data(from: server.url("/raw"))
        #expect((second as? HTTPURLResponse)?.statusCode == 204)
        #expect(empty.isEmpty)
    }

    @Test func bytesHangSendsThenFallsSilent() async throws {
        // C: STEP_BYTES_HANG (src/net/test-http.c:1718-1727). The head names a
        // Content-Type: without one URLSession withholds the response while it
        // sniffs the first body bytes.
        let server = try LoopbackServer([.bytesHang(Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n0123".utf8))])
        defer { server.stop() }
        let (received, length, error) = await Self.stream(server.url("/bh"), timeout: 0.5)
        #expect(length == 10)
        #expect(received == Data("0123".utf8))
        #expect(error?.code == .timedOut, "\(String(describing: error))")
        #expect(server.activeCount >= 1)
    }

    @Test func bytesSplitDripFeedsAtTheInterval() async throws {
        // C: STEP_BYTES_SPLIT, first part now, rest after delay_ms
        // (src/net/test-http.c:1709-1717); here three pieces 150 ms apart.
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nabcdef".utf8)
        let headLength = response.count - 6
        let server = try LoopbackServer([
            .bytesSplit(response, at: [headLength + 2, headLength + 4], interval: .milliseconds(150)),
            .drip(response, chunkSize: 16, interval: .milliseconds(20)),
        ])
        defer { server.stop() }
        let session = Self.session(timeout: 5)
        let start = ContinuousClock.now
        let (split, _) = try await session.data(from: server.url("/split"))
        let elapsed = ContinuousClock.now - start
        #expect(split == Data("abcdef".utf8))
        #expect(elapsed >= .milliseconds(300), "two gaps of 150 ms, got \(elapsed)")
        let pieces = (response.count + 15) / 16
        let dripStart = ContinuousClock.now
        let (dripped, _) = try await session.data(from: server.url("/drip"))
        #expect(dripped == Data("abcdef".utf8))
        #expect(ContinuousClock.now - dripStart >= .milliseconds(20 * (pieces - 1)))
    }

    @Test func holdAnswersOnlyAfterRelease() async throws {
        // test-metno.c R_HOLD: the answer waits until the test releases it.
        let server = try LoopbackServer([.hold(status: 200, body: Data("{\"held\":1}".utf8))])
        defer { server.stop() }
        let session = Self.session(timeout: 5)
        let task = Task { try await session.data(from: server.url("/held")) }
        #expect(await server.waitUntil { $0.heldCount == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.heldCount == 1, "released without release()")
        #expect(server.activeCount == 1)
        #expect(server.release() == 1)
        let (data, response) = try await task.value
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == Data("{\"held\":1}".utf8))
        #expect(server.heldCount == 0)
        #expect(server.release() == 0)
    }

    @Test func routesByPathPrefixWithPerRouteScripts() async throws {
        // test-nws.c / test-metno.c / test-openmeteo.c path-routed fakes.
        let server = try LoopbackServer(routes: [
            .init("/points/", [.text("P1"), .text("P2")]),
            .init("/gridpoints/", [.text("busy", status: 503)]),
        ])
        defer { server.stop() }
        let session = Self.session()
        var seen: [String] = []
        for path in ["/points/1", "/gridpoints/a", "/points/2", "/points/3", "/other"] {
            let (data, response) = try await session.data(from: server.url(path))
            seen.append("\((response as? HTTPURLResponse)?.statusCode ?? 0) \(String(decoding: data, as: UTF8.self))")
        }
        #expect(seen == ["200 P1", "503 busy", "200 P2", "200 P2", "404 {}"])
        #expect(server.paths == ["/points/1", "/gridpoints/a", "/points/2", "/points/3", "/other"])
    }

    @Test func stopClosesHangingConnections() async throws {
        // C: fake_free closes held connections (src/net/test-http.c:1825-1840).
        let server = try LoopbackServer([.hang])
        let session = Self.session(timeout: 10)
        let task = Task { try await session.data(from: server.url("/h")) }
        #expect(await server.waitForRequests(1))
        let start = ContinuousClock.now
        server.stop()
        let error = await Self.urlError { _ = try await task.value }
        #expect(error != nil)
        #expect(ContinuousClock.now - start < .seconds(5), "the client waited for its own timeout")
        #expect(server.activeCount == 0)
    }

    // MARK: Client closes, accepted connections (test-metno.c fake)

    @Test func closedEarlyCountsAClientCancellingAHangingRequest() async throws {
        // C: R_HANG "notes when the client closes" (test-metno.c:1498),
        // closed_early (:1536) counted on end of stream (:1660-1661); the C
        // tests wait for it after cancelling (:2659, :3572, :3715).
        let server = try LoopbackServer([.hang])
        defer { server.stop() }
        let task = Task { try await Self.session(timeout: 10).data(from: server.url("/hang")) }
        #expect(await server.waitForRequests(1))
        try await Task.sleep(for: .milliseconds(100))
        // C :3563: while the client still waits nothing is counted.
        #expect(server.closedEarlyCount == 0, "counted before the client closed")
        task.cancel()
        let error = await Self.urlError { _ = try await task.value }
        #expect(error?.code == .cancelled, "\(String(describing: error))")
        #expect(await server.waitUntil { $0.closedEarlyCount == 1 }, "closedEarly \(server.closedEarlyCount)")
        // C :3778: every request that reached the server ended.
        #expect(server.closedEarlyCount == server.requestCount)
        #expect(server.connectionCount == 1)
    }

    @Test func closedEarlyCountsAClientCancellingAHeldRequest() async throws {
        // test-metno.c R_HOLD whose client gives up before fake_release().
        let server = try LoopbackServer([.hold(body: Data("{}".utf8))])
        defer { server.stop() }
        let task = Task { try await Self.session(timeout: 10).data(from: server.url("/held")) }
        #expect(await server.waitUntil { $0.heldCount == 1 })
        #expect(server.closedEarlyCount == 0)
        task.cancel()
        #expect(await server.waitUntil { $0.closedEarlyCount == 1 }, "closedEarly \(server.closedEarlyCount)")
    }

    @Test func answeredAndStoppedRequestsAreNotClosedEarly() async throws {
        // closed_early counts only clients that gave up: an answered request
        // (including a released hold) and stop() do not count.
        let server = try LoopbackServer([.hold(body: Data("{\"held\":1}".utf8)), .hang])
        let session = Self.session(timeout: 10)
        let task = Task { try await session.data(from: server.url("/held")) }
        #expect(await server.waitUntil { $0.heldCount == 1 })
        #expect(server.release() == 1)
        let (data, _) = try await task.value
        #expect(data == Data("{\"held\":1}".utf8))
        let hanging = Task { try await session.data(from: server.url("/hang")) }
        #expect(await server.waitForRequests(2))
        server.stop()
        _ = await Self.urlError { _ = try await hanging.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.closedEarlyCount == 0)
    }

    @Test func connectionCountCountsAcceptedConnections() async throws {
        // C: fake->connections++ in on_incoming (test-metno.c:1691), asserted
        // 0 when no connection was opened (:2650, :3652).
        let server = try LoopbackServer([.text("{}")])
        defer { server.stop() }
        #expect(server.connectionCount == 0)
        // A bare TCP connection without a request is a connection, not a request.
        let (silent, _) = await Self.rawExchange(port: server.port, path: "", request: "", wait: 0.2)
        #expect(silent.isEmpty)
        #expect(await server.waitUntil { $0.connectionCount == 1 }, "connections \(server.connectionCount)")
        #expect(server.requestCount == 0)
        // Every answer carries Connection: close, so each request needs its own connection.
        let session = Self.session()
        _ = try await session.data(from: server.url("/one"))
        _ = try await session.data(from: server.url("/two"))
        #expect(await server.waitUntil { $0.connectionCount == 3 }, "connections \(server.connectionCount)")
        #expect(server.requestCount == 2)
    }

    // MARK: Replies computed at request time

    @Test func computeReadsStateTheTestChangesMidTest() async throws {
        // C: fake_new_fn(ReplyFn, data) (test-metno.c:1708); the stress test
        // flips state.calm = TRUE mid-test (:4209) and later replies change.
        let calm = LoopbackServer.Shared(false)
        let seen = LoopbackServer.Shared([String]())
        let server = try LoopbackServer(reply: { index, request in
            seen.withLock { $0.append("\(index) \(request.path)") }
            return calm.value ? .text("{\"calm\":true}") : .text("{}", status: 503)
        })
        defer { server.stop() }
        let session = Self.session()
        let (_, first) = try await session.data(from: server.url("/a"))
        #expect((first as? HTTPURLResponse)?.statusCode == 503)
        calm.value = true
        let (body, second) = try await session.data(from: server.url("/b"))
        #expect((second as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data("{\"calm\":true}".utf8))
        #expect(seen.value == ["0 /a", "1 /b"])
    }

    @Test func computeInARouteCountsThatRoutesRequests() async throws {
        // A computed reply may answer with any step; its index counts the
        // requests of its own script, as script_reply's index (test-metno.c:1698-1704).
        let server = try LoopbackServer(routes: [
            .init("/hang", [.hang]),
            .init("/n/", [.compute { index, _ in .text("n\(index)") }]),
        ])
        defer { server.stop() }
        let session = Self.session()
        var seen: [String] = []
        for path in ["/n/x", "/other", "/n/y"] {
            let (data, _) = try await session.data(from: server.url(path))
            seen.append(String(decoding: data, as: UTF8.self))
        }
        #expect(seen == ["n0", "{}", "n1"])
    }

    @Test func bigStreamedSizeZeroMeansTheFiveMebibyteDefault() async throws {
        // C: `step->size > 0 ? step->size : (gsize)5 * 1024 * 1024`
        // (src/net/test-http.c:1737).
        let server = try LoopbackServer([.bigStreamed(size: 0)])
        defer { server.stop() }
        let (data, response) = try await Self.session(timeout: 10).data(from: server.url("/big0"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.count == 5 * 1024 * 1024)
        #expect(server.bigStreamedBytesSent == 5 * 1024 * 1024)
    }

    // MARK: Step faults the first self-test missed (U03 verify, finding 2)

    @Test func hangWritesNothingAndKeepsTheConnectionOpen() async throws {
        // C: STEP_HANG / R_HANG, "read the request, never answer"
        // (src/net/test-http.c:1728-1731, test-metno.c:1498, :1643-1646).
        // Raw TCP, so no client retry can hide a close or a stray head.
        let server = try LoopbackServer([.hang])
        defer { server.stop() }
        let (wire, closed) = await Self.rawExchange(port: server.port, path: "/hang", wait: 1.5)
        #expect(wire.isEmpty, "hang wrote \(String(decoding: wire, as: UTF8.self))")
        #expect(!closed, "hang closed the connection")
        #expect(server.requestCount == 1)
        #expect(server.activeCount == 1)
        // The raw client cancelled after 1.5 s: that is a client close.
        #expect(await server.waitUntil { $0.closedEarlyCount == 1 })
    }

    @Test func routeCountersArePerRouteAndTheFirstMatchWins() async throws {
        // Path-routed fakes (test-nws.c, test-metno.c): each route keeps its
        // own step index, and the first matching route answers.
        let server = try LoopbackServer(routes: [
            .init("/a", [.text("a1"), .text("a2")]),
            .init("/b", [.text("b1"), .text("b2")]),
            .init("/x", [.text("x")]),
            .init("/x/long", [.text("long")]),
        ])
        defer { server.stop() }
        let session = Self.session()
        var seen: [String] = []
        for path in ["/a/1", "/b/1", "/b/2", "/a/2", "/x/long/1"] {
            let (data, _) = try await session.data(from: server.url(path))
            seen.append(String(decoding: data, as: UTF8.self))
        }
        #expect(seen == ["a1", "b1", "b2", "a2", "x"])
    }

    @Test func headerLinesExcludeTheRequestLine() async throws {
        // C: fake->heads keeps the whole head; header lines are the lines
        // after the request line (src/net/test-http.c:1648-1655).
        let server = try LoopbackServer([.text("{}")])
        defer { server.stop() }
        _ = await Self.rawExchange(port: server.port, path: "/h",
                                   request: "GET /h HTTP/1.1\r\nHost: 127.0.0.1\r\nX-One: 1\r\n\r\n")
        let recorded = try #require(server.requests.first)
        #expect(recorded.headerLines == ["Host: 127.0.0.1", "X-One: 1"])
        #expect(recorded.head == "GET /h HTTP/1.1\r\nHost: 127.0.0.1\r\nX-One: 1\r\n\r\n")
    }

    // MARK: Helpers

    private static func session(timeout: TimeInterval = 5) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 10)
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    private static func urlError(_ body: () async throws -> Void) async -> URLError? {
        do {
            try await body()
            return nil
        } catch let error as URLError {
            return error
        } catch {
            return URLError(.unknown)
        }
    }

    /// Streams `url`: the body bytes received before the end or the error,
    /// the declared length, and the error (nil when the body completed).
    private static func stream(_ url: URL, timeout: TimeInterval) async -> (Data, Int64, URLError?) {
        var received = Data()
        var length: Int64 = -2
        let error = await urlError {
            let (bytes, response) = try await session(timeout: timeout).bytes(from: url)
            length = response.expectedContentLength
            for try await byte in bytes { received.append(byte) }
        }
        return (received, length, error)
    }

    /// Sends a bare GET (or `request`, verbatim) over plain TCP and reads
    /// until the server closes or `wait` seconds pass: the bytes the server
    /// wrote and whether it closed. The client then closes its socket.
    ///
    /// A BSD socket, not an NWConnection: on macOS 27 a client NWConnection
    /// to 127.0.0.1 can bind a source port that a just-stopped server used
    /// and fail with EADDRINUSE (seen as an empty, never-closed exchange);
    /// connect(2) lets the kernel pick a free source port.
    private static func rawExchange(port: UInt16, path: String, request: String? = nil,
                                    wait: Double = 2) async -> (Data, Bool) {
        let bytes = Data((request ?? "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").utf8)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: blockingExchange(port: port, request: bytes, wait: wait))
            }
        }
    }

    /// `rawExchange` on the calling thread (blocking).
    private static func blockingExchange(port: UInt16, request: Data, wait: Double) -> (Data, Bool) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (Data(), false) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return (Data(), false) }
        var offset = 0
        while offset < request.count {
            let written = request.withUnsafeBytes { write(fd, $0.baseAddress! + offset, request.count - offset) }
            guard written > 0 else { return (Data(), false) }
            offset += written
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = ContinuousClock.now + .milliseconds(Int(wait * 1000))
        while true {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { return (received, false) }
            let (seconds, attoseconds) = left.components
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(max(1, seconds * 1000 + attoseconds / 1_000_000_000_000_000)))
            if ready < 0 && errno != EINTR { return (received, false) }
            guard ready > 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                received.append(contentsOf: buffer[0..<count])
            } else {
                return (received, true)  // 0: end of stream; < 0: reset, also a close
            }
        }
    }

    /// Whether a TCP connection to host:port reaches the ready state within 1 s.
    private static func tcpConnects(host: String, port: UInt16) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "LoopbackServerTests.probe")
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(true)
                case .waiting, .failed, .cancelled: once.resume(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) { once.resume(false) }
        }
        connection.cancel()
        return result
    }

    /// Every non-loopback IPv4 address of this machine's interfaces.
    private static func nonLoopbackIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("127.") { addresses.append(text) }
        }
        return addresses
    }

    /// Resumes a continuation exactly once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
