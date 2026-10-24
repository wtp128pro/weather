// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HTTPClientWireTests.swift - part of suite HTTPClientTests: responses built
// byte by byte (C: framed_response & co., test-http.c:2373-2520). It holds
//  - the gzip, chunked, content-coding, no-content and TLS tests of
//    test-http.c, minus the gzip-strictness rows URLSession cannot reproduce
//    (DECISIONS #30, listed at each test and in the U13 debrief);
//  - the OUTCOME tests that replace the 12 libsoup wire-framing cases
//    (DECISIONS #10): truncated, oversized and garbled responses fail with
//    the C error codes.
// Where CFNetwork itself decides differently from libsoup and no public-API fix
// was found among the signals probed (per item in the U13 debrief) for the
// responses CFNetwork accepts (for status lines
// it cannot parse it falls back on HTTP/0.9 and hands the raw answer over as
// body bytes, which only DECISIONS #10's AVOID of a hand-written HTTP parser
// rules out reading: DECISIONS #36 N1), the test asserts the PLATFORM outcome,
// labelled with the decision that accepted it ("DECISIONS #34 item N" for the
// URLSession platform differences, "DECISIONS #30" for gzip strictness, "NEW
// U13-N1".."N10" for the differences of U13 iteration 3's contract sweep,
// DECISIONS #36; "NEW U13-N9" is rule (b) of DECISIONS #40) or, for those found
// in the Phase-7 revision and decided in DECISIONS #45, "NEW U13-N11".."N16" (and
// "NEW U13-N17", found in the fix pass of DECISIONS #53 and decided in #57), and the C lines it differs from, so that a CFNetwork
// change turns the test red; the U13 debrief and the contract sweep list every
// such row with its probe evidence. C outcomes that come from libsoup 3.6.6 or
// zlib rather than from test-http.c cite those sources by file and line.

import Foundation
import Network
import Security
import Synchronization
import Testing
@testable import WeatherCore

extension HTTPClientTests {

    // MARK: Byte-level responses (C: test-http.c:2373-2520)

    /// Framing (test-http.c:2373-2377).
    enum Framing { case contentLength, chunked, close }

    /// framed_response (test-http.c:2383-2410): a `status` response with the
    /// extra header lines (each CRLF-terminated), framed by Content-Length
    /// `declared`, by one chunk declaring `declared` bytes, or by the close;
    /// `sendLen` payload bytes are sent.
    static func framed(
        _ status: Int, _ framing: Framing, _ extra: String, _ payload: [UInt8], sendLen: Int, declared: Int,
        terminate: Bool = true
    ) -> Data {
        let framingHeader = switch framing {
        case .contentLength: "Content-Length: \(declared)\r\n"
        case .chunked: "Transfer-Encoding: chunked\r\n"
        case .close: ""
        }
        var all = Data("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n\(extra)\(framingHeader)Connection: close\r\n\r\n".utf8)
        if framing == .chunked {
            if declared > 0 {
                all += Data(String(declared, radix: 16).utf8) + Data("\r\n".utf8)
                all += payload.prefix(sendLen)
                if sendLen == declared { all += Data("\r\n".utf8) }
            }
            if terminate { all += Data("0\r\n\r\n".utf8) }
        } else {
            all += payload.prefix(sendLen)
        }
        return all
    }

    /// response_with (test-http.c:2412-2416).
    static func responseWith(_ extra: String, _ payload: [UInt8], sendLen: Int, declared: Int) -> Data {
        framed(200, .contentLength, extra, payload, sendLen: sendLen, declared: declared)
    }

    /// chunked_response (test-http.c:2420-2425).
    static func chunkedResponse(_ extra: String, _ payload: [UInt8], sendLen: Int, declared: Int, terminate: Bool) -> Data {
        framed(200, .chunked, extra, payload, sendLen: sendLen, declared: declared, terminate: terminate)
    }

    /// cut_position_wanted (test-http.c:2518-2523), without the slow-suite branch.
    static func cutPositionWanted(_ k: Int, _ n: Int) -> Bool {
        k < 3 || (k >= 9 && k <= 12) || k == n / 2 || (k + 12 >= n && k + 6 <= n) || k + 3 >= n
    }

    /// run_split_case_delay (test-http.c:2496-2505): the first `first` bytes, then the rest
    /// `delayMs` later.
    static func split(_ response: Data, first: Int, delayMs: Int = 100) -> LoopbackServer.Step {
        .bytesSplit(response, at: [first], interval: .milliseconds(delayMs))
    }

    static let gzHeader = "Content-Encoding: gzip\r\n"                      // test-http.c:2571
    static var gzipJSON: [UInt8] { Array(LoopbackServer.gzip(Data(kGzipJson.utf8))) }

    // MARK: Content coding

    // C: /http/net/gzip (test-http.c:2525-2562)
    @Test func gzip() async throws {
        let json = #"{"data":null,"status":{"rCode":200}}"#                  // test-http.c:2528
        let server = try LoopbackServer([.gzip(body: Data(json.utf8))])
        defer { server.stop() }
        let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
        #expect(Self.body(await Self.fetch(http)) == Data(json.utf8))
        #expect(server.requestCount == 1)
        let head = try #require(server.requests.first).head
        #expect(head.contains("\r\nAccept-Encoding: gzip\r\n"))                   // test-http.c:2542
        #expect(!head.contains("deflate"))                                         // test-http.c:2543
        #expect(!head.contains(", br"))                                            // test-http.c:2544
        // The cap applies AFTER decoding (test-http.c:2548-2551): gzip of zero bytes, served
        // like STEP_GZIP (test-http.c:1689-1700). The members above the cap carry a zero trailer
        // (zeroBomb): decoding stops at cap + 1 decoded bytes, long before the trailer, in C too
        // (inflate_chunk, wx-http.c:930-932), and computing their CRC in the test's debug build
        // took seconds. The 200 MiB bomb (test-http.c:2550) is gzipBombOf200MiB.
        for size in [5 * 1024 * 1024, HTTPPolicy.maxBodyBytes + 1] {                // test-http.c:2548-2549
            try await Self.expectFailure(try Self.zeroBomb(size), .parse, requests: 1, "gzip bomb \(size)")
        }
        // The exact cap of zero bytes is LoopbackServer's .gzip answer (STEP_GZIP), its member built by
        // gzipMember: the .gzip step computes LoopbackServer.gzip's bitwise CRC-32 while the client
        // waits (16 s per 4 MiB in the debug build under load, probe-p7/p14-gzipcap.log), which ran
        // this fetch into the 45 s whole-operation deadline under load
        // (results/U13p7-cfK-20261023123754-96638.log: gzip() 'operation deadline exceeded' after 50 s).
        let zeros = Data(count: HTTPPolicy.maxBodyBytes)
        let packed = try Self.gzipMember(zeros, crc: Self.tableCRC32(zeros))
        let exact = try LoopbackServer([.raw(Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Encoding: gzip\r\nContent-Length: \(packed.count)\r\nConnection: close\r\n\r\n").utf8) + packed)])  // :2553-2560
        defer { exact.stop() }
        let http2 = try Self.client(exact, timeoutMs: 60000, backoffMs: 5)
        #expect(try await Self.fetch(http2).get().body.count == HTTPPolicy.maxBodyBytes)
    }

    // C: /http/net/gzip (test-http.c:2550): the 200 MiB bomb of the cap rows, a test of its own so
    // that gzip() keeps headroom against the suite's 60 s per-test limit (gzip() took 11.5 s,
    // mostly the debug-build CRC-32 of its 4-5 MiB members, now zeroBomb). The member is one
    // zlib-compressed run of zeros with a zero trailer (decoding stops at cap + 1 bytes, long
    // before it) and is refused as PARSE "response too large" after 1 request.
    @Test func gzipBombOf200MiB() async throws {
        try await Self.expectFailure(try Self.zeroBomb(200 * 1024 * 1024), .parse, requests: 1, "gzip bomb 200 MiB")
    }

    /// STEP_GZIP of `size` zero bytes (test-http.c:1689-1700, the answer LoopbackServer's .gzip
    /// sends) with a zero CRC-32 / ISIZE trailer, for members that decode past the cap.
    static func zeroBomb(_ size: Int) throws -> LoopbackServer.Step {
        let deflated = try (Data(count: size) as NSData).compressed(using: .zlib) as Data
        let bomb = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]) + deflated + Data(count: 8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: \(bomb.count)\r\nConnection: close\r\n\r\n"
        return .raw(Data(head.utf8) + bomb)
    }

    // C: /http/net/gzip-truncated (test-http.c:2566-2632). Ported: the control, (a) a cut
    // connection at every wanted position, the over-declared length, a non-gzip body, an
    // empty body, a body split in two reads and the stalled cut. The rows DECISIONS #30 accepted
    // (URLSession inflates gzip without checking the stream end, CRC or trailing data): (b)
    // complete messages carrying a cut stream (:2588-2589), the bit flips (:2598-2604),
    // garbage / second member / one byte / late garbage after the stream (:2611-2624) are pinned
    // at their platform outcome in gzipStrictnessPlatformRows.
    @Test func gzipTruncated() async throws {
        let z = Self.gzipJSON
        let n = z.count
        #expect(n > 30)                                                            // test-http.c:2572
        let okBody = Data(Self.kGzipJson.utf8)
        try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, z, sendLen: n, declared: n)),
                                  code: nil, requests: 1, okBody: okBody, "whole")
        var tried = 0
        for k in 0..<n where Self.cutPositionWanted(k, n) {
            tried += 1
            try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, z, sendLen: k, declared: n)),
                                      code: .network, requests: Self.retried, "(a) cut at \(k)")
        }
        #expect(tried >= 12)                                                       // test-http.c:2591
        try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, z, sendLen: n, declared: n + 10)),
                                  code: .network, requests: Self.retried, "over-declared")  // :2595
        let plain = Array("plain text, not gzip".utf8)                             // test-http.c:2606
        try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, plain, sendLen: 20, declared: 20)),
                                  code: .network, requests: Self.retried, "not gzip")
        try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, z, sendLen: 0, declared: 0)),
                                  code: .network, requests: Self.retried, "empty")  // :2608-2609
        let inTwo = Self.responseWith(Self.gzHeader, z, sendLen: n, declared: n)
        try await Self.expectCase(Self.split(inTwo, first: inTwo.count - n / 2), code: nil, requests: 1,
                                  okBody: okBody, "in two reads")  // :2626-2627
        try await Self.expectHeld(Self.responseWith(Self.gzHeader, z, sendLen: n / 2, declared: n),
                                  code: .timeout, requests: Self.retried, atDeadline: true, "stalled")  // :2630-2631
    }

    // C: /http/net/chunked (test-http.c:2636-2672). DECISIONS #30 rows, pinned in
    // gzipStrictnessPlatformRows: the gzip stream cut inside proper chunks (:2655-2660) and
    // garbage after the gzip stream in a further chunk (:2667-2671). DECISIONS #34 item 2 platform rows: a body without its final
    // chunk (:2645-2646, :2664-2665; C: NETWORK after 1 + WX_HTTP_MAX_RETRIES requests) ends as a complete
    // success, because CFNetwork takes the end of the connection at a chunk boundary as the
    // end of the body; no public-API fix found among the metrics' body byte counts (they count
    // the bytes after the chunk framing, not the final chunk); cut anywhere else it is NETWORK.
    @Test func chunked() async throws {
        let json = Array(#"{"chunked":true}"#.utf8)                                // test-http.c:2638
        let jn = json.count
        try await Self.expectCase(.raw(Self.chunkedResponse("", json, sendLen: jn, declared: jn, terminate: true)),
                                  code: nil, requests: 1, okBody: Data(json), "ok")
        try await Self.expectCase(.raw(Self.chunkedResponse("", json, sendLen: jn / 2, declared: jn, terminate: false)),
                                  code: .network, requests: Self.retried, "short chunk")   // :2643-2644
        let z = Self.gzipJSON
        let n = z.count
        try await Self.expectCase(.raw(Self.chunkedResponse(Self.gzHeader, z, sendLen: n, declared: n, terminate: true)),
                                  code: nil, requests: 1, okBody: Data(Self.kGzipJson.utf8), "gzip ok")  // :2652
        try await Self.expectCase(.raw(Self.chunkedResponse(Self.gzHeader, z, sendLen: n / 2, declared: n, terminate: false)),
                                  code: .network, requests: Self.retried, "gzip short chunk")  // :2662-2663
        // DECISIONS #34 item 2 platform rows (C :2645-2646 and :2664-2665 expect NETWORK x 3).
        try await Self.expectCase(.raw(Self.chunkedResponse("", json, sendLen: jn, declared: jn, terminate: false)),
                                  code: nil, requests: 1, okBody: Data(json), "DECISIONS #34 item 2 platform row (test-http.c:2645-2646): no final chunk")
        try await Self.expectCase(.raw(Self.chunkedResponse(Self.gzHeader, z, sendLen: n, declared: n, terminate: false)),
                                  code: nil, requests: 1, okBody: Data(Self.kGzipJson.utf8), "DECISIONS #34 item 2 platform row (test-http.c:2664-2665): gzip, no final chunk")
        // Cut inside a chunk-size line or after the data's CRLF of the final chunk: NETWORK.
        let noCRLF = Self.chunkedResponse("", json, sendLen: jn, declared: jn, terminate: false).dropLast(2)
        try await Self.expectCase(.raw(Data(noCRLF)), code: .network, requests: Self.retried, "data without its CRLF")
    }

    // C: /http/net/content-coding (test-http.c:2681-2746)
    @Test func contentCoding() async throws {
        let rows: [(String, Bool, Bool)] = [                                        // test-http.c:2689-2727
            ("", false, true), ("Content-Encoding:\r\n", false, true), ("Content-Encoding: \r\n", false, true),
            ("Content-Encoding: ,\r\n", false, true), ("Content-Encoding: identity\r\n", false, true),
            ("Content-Encoding: IDENTITY, identity\r\n", false, true), ("Content-Encoding: identity,\r\n", false, true),
            ("Content-Encoding: gzip\r\n", true, true), ("Content-Encoding: GZIP\r\n", true, true),
            ("Content-Encoding: GZip\r\n", true, true), ("Content-Encoding: x-gzip\r\n", true, true),
            ("Content-Encoding: X-Gzip\r\n", true, true), ("Content-Encoding: gzip,\r\n", true, true),
            ("Content-Encoding: , gzip\r\n", true, true), ("Content-Encoding: ,gzip,,\r\n", true, true),
            ("Content-Encoding:  gzip \r\n", true, true), ("Content-Encoding: identity, gzip\r\n", true, true),
            ("Content-Encoding: gzip, identity\r\n", true, true),
            ("Content-Encoding: identity\r\nContent-Encoding: gzip\r\n", true, true),
            ("Content-Encoding: gzip\r\nContent-Encoding: identity\r\n", true, true),
            ("Content-Encoding:\r\nContent-Encoding: gzip\r\n", true, true),
            ("Content-Encoding: gzip, gzip\r\n", true, false), ("Content-Encoding: gzip\r\nContent-Encoding: gzip\r\n", true, false),
            ("Content-Encoding: x-gzip, gzip\r\n", true, false), ("Content-Encoding: gzip;q=1\r\n", true, false),
            ("Content-Encoding: \"gzip\"\r\n", true, false), ("Content-Encoding: gzip gzip\r\n", true, false),
            ("Content-Encoding: gzip, br\r\n", true, false), ("Content-Encoding: br, gzip\r\n", true, false),
            ("Content-Encoding: deflate\r\n", false, false), ("Content-Encoding: br\r\n", false, false),
            ("Content-Encoding: compress\r\n", false, false), ("Content-Encoding: zstd\r\n", false, false),
            ("Content-Encoding: x-compress\r\n", false, false), ("Content-Encoding: identity, deflate\r\n", false, false),
            ("Content-Encoding: gzipp\r\n", true, false), ("Content-Encoding: gz\r\n", true, false),
        ]
        let z = Self.gzipJSON
        let plain = Array(Self.kBody.utf8)
        for (headers, gzipBody, accepted) in rows {
            let payload = gzipBody ? z : plain
            let response = Self.responseWith(headers, payload, sendLen: payload.count, declared: payload.count)
            if accepted {
                try await Self.expectCase(.raw(response), code: nil, requests: 1,
                                          okBody: Data((gzipBody ? Self.kGzipJson : Self.kBody).utf8), headers.debugDescription)
            } else {
                try await Self.expectCase(.raw(response), code: .parse, requests: 1,
                                          messageContains: "unsupported content coding", headers.debugDescription)
            }
        }
        // The list is parsed whatever the framing (test-http.c:2742-2745).
        try await Self.expectCase(
            .raw(Self.chunkedResponse("Content-Encoding: identity, gzip,\r\n", z, sendLen: z.count, declared: z.count, terminate: true)),
            code: nil, requests: 1, okBody: Data(Self.kGzipJson.utf8), "chunked ok")
        try await Self.expectCase(
            .raw(Self.chunkedResponse("Content-Encoding: gzip, gzip\r\n", z, sendLen: z.count, declared: z.count, terminate: true)),
            code: .parse, requests: 1, "chunked gzip, gzip")
    }

    // C: /http/net/gzip-truncated (test-http.c:2566-2632) rows (b), the bit flips, empty,
    // garbage, second member and one byte, for the Content-Encoding lists that CFNetwork
    // leaves undecoded ("identity, gzip" is gzip for C, test-http.c:2706): the client
    // inflates those itself with the C rules, so the C outcomes hold there.
    @Test func strictGzipWhereURLSessionDoesNotInflate() async throws {
        let list = "Content-Encoding: identity, gzip\r\n"
        let z = Self.gzipJSON
        let n = z.count
        try await Self.expectCase(.raw(Self.responseWith(list, z, sendLen: n, declared: n)), code: nil, requests: 1,
                                  okBody: Data(Self.kGzipJson.utf8), "whole")
        for k in 1..<n where Self.cutPositionWanted(k, n) {                          // test-http.c:2588-2589
            try await Self.expectCase(.raw(Self.responseWith(list, z, sendLen: k, declared: k)),
                                      code: .network, requests: Self.retried, "(b) cut at \(k)")
        }
        for flip in [n / 2, n - 8, n - 7, n - 4, n - 1] {                             // test-http.c:2598
            var bad = z
            bad[flip] ^= 0x01
            try await Self.expectCase(.raw(Self.responseWith(list, bad, sendLen: n, declared: n)),
                                      code: .network, requests: Self.retried, "flip at \(flip)")
        }
        for (tail, label) in [(Array("xyz".utf8), "garbage"), (z, "second member"), ([z[0]], "one byte")] {  // :2611-2621
            let payload = z + tail
            try await Self.expectCase(.raw(Self.responseWith(list, payload, sendLen: payload.count, declared: payload.count)),
                                      code: .parse, requests: 1, label)
        }
        // A member with a wrong CRC-32 followed by 8 bytes that hold the right CRC-32 / ISIZE:
        // the member's OWN trailer decides (zlib), NETWORK, not "trailing bytes found".
        var wrongCRC = z
        wrongCRC[n - 8] ^= 0x01
        let shadowed = wrongCRC + z.suffix(8)
        try await Self.expectCase(.raw(Self.responseWith(list, shadowed, sendLen: shadowed.count, declared: shadowed.count)),
                                  code: .network, requests: Self.retried, "wrong CRC, right trailer after it")
        // The garbage arrives in a later read than the end of the stream (test-http.c:2622-2624).
        let late = Self.responseWith(list, z + Array("xyz".utf8), sendLen: n + 3, declared: n + 3)
        try await Self.expectCase(Self.split(late, first: late.count - 3), code: .parse, requests: 1, "late garbage")
        // A stored block whose NLEN is not the one's complement of LEN, with the right CRC-32 and
        // ISIZE of "hello" (zlib: "invalid stored block lengths", so C: NETWORK; U13 verify V1-D4),
        // and the same block with the right NLEN.
        let hello = Array("hello".utf8)
        let crc = HTTPClient.crc32(Data(hello))
        let trailer = (0..<4).map { UInt8(truncatingIfNeeded: crc >> (8 * $0)) } + [5, 0, 0, 0]
        let header: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]
        let storedRows: [([UInt8], WxError.Code?)] = [([0xFB, 0xFF], .network), ([0xFA, 0xFF], nil)]
        for (nlen, code) in storedRows {
            let member = header + [0x01, 0x05, 0x00] + nlen + hello + trailer
            try await Self.expectCase(.raw(Self.responseWith(list, member, sendLen: member.count, declared: member.count)),
                                      code: code, requests: code == nil ? 1 : Self.retried, okBody: Data(hello),
                                      "stored block NLEN \(nlen)")
        }
    }

    // C: none (executor addition: the strict decoder unit; C uses GLib's zlib decompressor).
    // The strict decoder on its own (C: GLib's zlib decompressor as inflate_chunk feeds it,
    // wx-http.c:907-944): exact end of the DEFLATE data for many members of every kind, fed
    // whole and in arbitrary pieces; the header CRC (FHCRC) is checked. The expected bodies are
    // the members' inputs.
    @Test func gzipMemberDecoderFindsTheExactEnd() throws {
        var rng = SeededRNG(seed: 13)
        for index in 0..<120 {
            let size = index < 60 ? Int.random(in: 0..<600, using: &rng) : Int.random(in: 0..<40_000, using: &rng)
            let kind = index % 3
            let payload = Data((0..<size).map { k -> UInt8 in
                switch kind {
                case 0: UInt8.random(in: 0...255, using: &rng)                 // incompressible
                case 1: UInt8(ascii: "a") + UInt8(k % 7)                        // very compressible
                default: UInt8.random(in: 0x20...0x28, using: &rng)             // text-like
                }
            })
            // LoopbackServer.gzip's bytes, built with the table CRC-32 (its bitwise CRC-32 made this test
            // take up to 16 s under load): the same member, checked on the first ones.
            let member = payload.isEmpty ? LoopbackServer.gzip(payload) : try Self.gzipMember(payload, crc: Self.tableCRC32(payload))
            if index < 6 { #expect(member == LoopbackServer.gzip(payload), "member \(index): the bytes LoopbackServer.gzip makes") }
            let label = "member \(index) (\(size) bytes, kind \(kind))"
            #expect(try HTTPClient.inflateGzipMember(member, limit: HTTPPolicy.maxBodyBytes).get() == payload, "\(label)")
            // The same member in random pieces (each piece goes through the streaming decoder).
            let decoder = HTTPClient.GzipMemberDecoder(limit: HTTPPolicy.maxBodyBytes)
            var at = 0
            while at < member.count {
                let piece = min(member.count - at, Int.random(in: 1...9000, using: &rng))
                #expect(decoder.feed(member.subdata(in: at..<(at + piece))) == nil, "\(label)")
                at += piece
            }
            #expect((try? decoder.finish().get()) == payload, "\(label) in pieces")
            // One byte more, one byte fewer, a corrupted trailer.
            #expect(HTTPClient.inflateGzipMember(member + Data([0x41]), limit: HTTPPolicy.maxBodyBytes).failureCode == .parse, "\(label) + 1")
            #expect(HTTPClient.inflateGzipMember(member.dropLast(), limit: HTTPPolicy.maxBodyBytes).failureCode == .network, "\(label) - 1")
            var badSize = member
            badSize[badSize.count - 1] ^= 0x80
            #expect(HTTPClient.inflateGzipMember(badSize, limit: HTTPPolicy.maxBodyBytes).failureCode == .network, "\(label) ISIZE")
        }
        // FHCRC (RFC 1952 2.3.1): the low 16 bits of the CRC-32 of the header bytes before it.
        let plain = Data(#"{"fhcrc":true}"#.utf8)
        let member = LoopbackServer.gzip(plain)
        var header = Data(member.prefix(10))
        header[3] |= 0x02
        let headerCRC = HTTPClient.crc32(header)
        let withCRC = header + Data([UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8 & 0xFF)]) + member.dropFirst(10)
        #expect(try HTTPClient.inflateGzipMember(withCRC, limit: HTTPPolicy.maxBodyBytes).get() == plain)
        var wrong = withCRC
        wrong[10] ^= 0x01
        #expect(HTTPClient.inflateGzipMember(wrong, limit: HTTPPolicy.maxBodyBytes).failureCode == .network)
    }

    // C: none (executor addition for the OUTCOME TESTS criterion: garbled gzip). C inflates with
    // GLib's zlib decompressor (inflate_chunk, src/net/wx-http.c:907-944); a stream zlib refuses
    // is a GIO error, so NETWORK (wx-http.c:999-1001, normalize_error :706; wx-http.h:111-113
    // "corrupt ... is WX_ERROR_NETWORK"). One crafted member per validity check of zlib's inflate
    // (zlib 1.3.1 inflate.c:858-1139, inftrees.c:111-134), each listed with the message zlib 1.2.12
    // gives for it (the U13 differential generator); the controls are streams zlib accepts.
    // Compression.framework alone accepts the stored block with a wrong NLEN and the incomplete or
    // over-subscribed literal/length and distance codes (U13 differential: 718 of 17584 checks
    // differed without the validator, 0 with it).
    @Test func deflateChecksMatchZlib() throws {
        let members: [(String, String?, [UInt8])] = [
            // zlib inflate.c: "invalid stored block lengths"
            ("stored block, NLEN != ~LEN (U13 verify V1-D4)", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x01, 0x05, 0x00, 0xFB, 0xFF, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x86, 0xA6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00]),
            // zlib: OK
            ("stored block, NLEN == ~LEN (control)", "hello", [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x01, 0x05, 0x00, 0xFA, 0xFF, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x86, 0xA6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid block type"
            ("block type 3", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "too many length or distance symbols"
            ("287 literal/length codes", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xF5, 0xE0, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "too many length or distance symbols"
            ("31 distance codes", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0xFE, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid code lengths set"
            ("incomplete code-length code", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0x20, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid code lengths set"
            ("over-subscribed code-length code", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0x20, 0x02, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid bit length repeat"
            ("repeat of no previous length", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0x20, 0x24, 0x41, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid bit length repeat"
            ("repeat past the last length", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0x20, 0x24, 0x41, 0xFF, 0xFF, 0xFF, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid code -- missing end-of-block"
            ("no end-of-block code", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0xE0, 0x01, 0x90, 0x24, 0x49, 0x92, 0x24, 0x49, 0x46, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x80, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid literal/lengths set"
            ("over-subscribed literal/length code", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0xE0, 0x01, 0x90, 0x24, 0x49, 0x92, 0x24, 0x49, 0xBA, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid literal/lengths set"
            ("incomplete literal/length code (two 2-bit codes)", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0xE0, 0x01, 0x90, 0x24, 0x49, 0x92, 0x24, 0x49, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x90, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib: OK
            ("single 1-bit end-of-block code (control: zlib accepts)", "", [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0xE0, 0x01, 0x90, 0x24, 0x49, 0x92, 0x24, 0x49, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid literal/length code"
            ("unused bit pattern of a single 1-bit code", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0xE0, 0x01, 0x90, 0x24, 0x49, 0x92, 0x24, 0x49, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid distances set"
            ("incomplete distance code (two 2-bit codes)", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x0D, 0xE2, 0x01, 0x90, 0x24, 0x49, 0x92, 0x24, 0x49, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x11, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib: OK
            ("no distance codes, literals only (control: zlib accepts)", "A", [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x05, 0xE0, 0x01, 0x90, 0x24, 0x49, 0x92, 0x24, 0x49, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x08, 0x8B, 0x9E, 0xD9, 0xD3, 0x01, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid literal/length code"
            ("fixed literal/length symbol 286", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x1B, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid literal/length code"
            ("fixed literal/length symbol 287", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x1B, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid distance code"
            ("fixed distance symbol 30", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x4B, 0x4C, 0x02, 0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid distance code"
            ("fixed distance symbol 31", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x4B, 0x4C, 0x02, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib inflate.c: "invalid distance too far back"
            ("distance 3 after 2 bytes (too far back)", nil, [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x4B, 0x4C, 0x02, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            // zlib: OK
            ("distance 2 after 2 bytes (control: zlib accepts)", "ababa", [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x4B, 0x4C, 0x02, 0x42, 0x00, 0x94, 0x6F, 0x34, 0xD7, 0x05, 0x00, 0x00, 0x00]),
        ]
        for (label, body, member) in members {
            let whole = HTTPClient.inflateGzipMember(Data(member), limit: HTTPPolicy.maxBodyBytes)
            // The same member one byte at a time through the streaming decoder.
            let decoder = HTTPClient.GzipMemberDecoder(limit: HTTPPolicy.maxBodyBytes)
            var failure: HTTPClient.GzipMemberDecoder.Failure?
            for byte in member where failure == nil { failure = decoder.feed(Data([byte])) }
            let pieces: Result<Data, WxError> = failure.map { .failure($0.error) } ?? decoder.finish().mapError(\.error)
            for (way, result) in [("whole", whole), ("byte by byte", pieces)] {
                if let body {
                    #expect((try? result.get()) == Data(body.utf8), "\(label) \(way): \(result)")
                } else {
                    #expect(result.failureCode == .network, "\(label) \(way): \(result)")
                }
            }
        }
        // Stream order (C: inflate_chunk gives zlib at most cap + 1 bytes of room and checks the
        // cap after each call, wx-http.c:920-933; zlib stops inside a stored block when the room is
        // full, inflate.c COPY): stored blocks of more than the cap, then block type 3, are PARSE
        // "response too large"; the same block type 3 before the cap is NETWORK.
        func stored(_ count: Int, final: Bool) -> [UInt8] {
            var out: [UInt8] = []
            var left = count
            repeat {
                let n = min(left, 65_535)
                left -= n
                let last: UInt8 = final && left == 0 ? 1 : 0
                out += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8(~n >> 8 & 0xFF)]
                out += [UInt8](repeating: 0x61, count: n)
            } while left > 0
            return out
        }
        let header: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]
        let past = header + stored(HTTPPolicy.maxBodyBytes + 11, final: false) + [0x07] + [UInt8](repeating: 0, count: 8)
        #expect(HTTPClient.inflateGzipMember(Data(past), limit: HTTPPolicy.maxBodyBytes).failureCode == .parse,
                "block type 3 after cap + 11 decoded bytes")
        let before = header + stored(1000, final: false) + [0x07] + [UInt8](repeating: 0, count: 8)
        #expect(HTTPClient.inflateGzipMember(Data(before), limit: HTTPPolicy.maxBodyBytes).failureCode == .network,
                "block type 3 after 1000 decoded bytes")
    }


    // C: /http/net/gzip (test-http.c:2549-2560) on a list CFNetwork leaves undecoded, without a
    // Content-Length: the cap counts DECODED bytes (inflate_chunk, wx-http.c:918-934), so an
    // incompressible body of exactly the cap (whose member is larger than the cap) is accepted
    // and one byte more is PARSE. The members are LoopbackServer.gzip's bytes (checked on a 4 KiB
    // sample), built by gzipMember with one table CRC-32 over the cap and its one-byte extension:
    // LoopbackServer.gzip's bitwise CRC-32 took 16 s per 4 MiB payload in the debug build under load
    // (probe-p7/p14-gzipcap.log; the rest of the test under 2 s), which ran the test into the
    // suite's 60 s limit.
    @Test func undecodedGzipCapCountsDecodedBytes() async throws {
        var rng = SeededRNG(seed: 4194304)
        var words = [UInt64](repeating: 0, count: HTTPPolicy.maxBodyBytes / 8 + 1)
        for i in words.indices { words[i] = rng.next() }
        let random = words.withUnsafeBytes { Data($0) }
        let cap = HTTPPolicy.maxBodyBytes
        let sample = random.prefix(4096)
        #expect(try Self.gzipMember(sample, crc: Self.tableCRC32(sample)) == LoopbackServer.gzip(sample))
        let crcOfCap = Self.tableCRC32(random.prefix(cap))
        let crcs = [cap: crcOfCap, cap + 1: Self.tableCRC32(random[cap..<cap + 1], continuing: crcOfCap)]
        for (size, accepted) in [(cap, true), (cap + 1, false)] {
            let payload = random.prefix(size)
            let member = try Self.gzipMember(payload, crc: try #require(crcs[size]))
            #expect(member.count > HTTPPolicy.maxBodyBytes)
            for framing in [Framing.close, .chunked] {
                let response = Self.framed(200, framing, "Content-Encoding: identity, gzip\r\n", [UInt8](member),
                                           sendLen: member.count, declared: member.count)
                let server = try LoopbackServer([.raw(response)])
                defer { server.stop() }
                let http = try Self.client(server, timeoutMs: 30000, backoffMs: 5)
                let outcome = await Self.fetch(http)
                if accepted {
                    #expect(Self.body(outcome) == payload, "\(size) \(framing): \(Self.wxError(outcome)?.message ?? "ok")")
                } else {
                    #expect(Self.wxError(outcome)?.code == .parse, "\(size) \(framing)")
                    #expect(Self.wxError(outcome)?.message == HTTPPolicy.Message.responseTooLarge)
                }
                #expect(server.requestCount == 1)
            }
        }
    }

    /// The gzip member LoopbackServer.gzip makes of a non-empty `payload` (RFC 1952: header, NSData's
    /// raw DEFLATE, CRC-32, ISIZE), given the payload's CRC-32.
    private static func gzipMember(_ payload: Data, crc: UInt32) throws -> Data {
        var member = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        member.append(try (payload as NSData).compressed(using: .zlib) as Data)
        for value in [crc, UInt32(truncatingIfNeeded: payload.count)] {
            member.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        return member
    }

    /// gzip's CRC-32 (ISO-HDLC, reflected polynomial 0xEDB88320) of `data` following bytes whose
    /// CRC-32 is `crc`, by a 256-entry table over the raw bytes.
    private static func tableCRC32(_ data: Data, continuing crc: UInt32 = 0) -> UInt32 {
        let table = crc32Table
        var c = ~crc
        data.withUnsafeBytes { raw in
            table.withUnsafeBufferPointer { t in
                for byte in raw { c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return ~c
    }

    private static let crc32Table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
    }

    // C: /http/net/gzip-late-trailing-data (test-http.c:2767-2820). Ported: the control (a
    // clean chunked gzip body split before its final chunk) and the longer Content-Length
    // never completed. DECISIONS #30 rows, pinned in gzipStrictnessPlatformRows: every
    // trailing-bytes case (:2773-2813), which URLSession delivers as the decoded stream.
    @Test func gzipLateTrailingDataControls() async throws {
        let z = Self.gzipJSON
        let n = z.count
        let clean = Self.chunkedResponse(Self.gzHeader, z, sendLen: n, declared: n, terminate: true)
        try await Self.expectCase(Self.split(clean, first: clean.count - 5), code: nil, requests: 1,
                                  okBody: Data(Self.kGzipJson.utf8), "clean split")   // :2815-2816
        try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, z, sendLen: n, declared: n + 5)),
                                  code: .network, requests: Self.retried, "never completed")  // :2818-2819
    }

    // C: /http/net/gzip-truncated (test-http.c:2566-2632), /http/net/chunked (:2636-2672) and
    // /http/net/gzip-late-trailing-data (:2767-2820), the gzip rows DECISIONS #30 accepted as
    // documented differences (DECISIONS #34 condition 8 lists the chunked ones by line), pinned at
    // their observed outcome when CFNetwork inflates the body itself ("Content-Encoding: gzip"),
    // so that a CFNetwork change turns a row red. CFNetwork checks neither the end of the stream,
    // nor the CRC-32 / ISIZE, nor bytes after the member: a correctly framed message with such a
    // stream is a success with whatever the system decoder produced: a prefix, a corrupted body
    // (the flip at n/2), or an EMPTY body from 20 or more bytes. Fewer than 20 encoded bytes
    // cannot be a gzip member; those cuts ((b) at the sampled k = 1, 2, 9-12) are C rows now
    // (DECISIONS #45). Chunked cuts that CFNetwork decodes to nothing are NETWORK x3 as in C (the
    // 105-byte member's at k = 1, 2, 9-12); a chunked cut under 20 payload bytes that it decodes to
    // a prefix is a DECISIONS #30 success with that prefix (kBody's member, whose single
    // fixed-Huffman block decodes from its first bytes: k = 12-19; probe-p7/p14-earlydecode.log;
    // V1-P7-D6). C for every row: NETWORK after 1 + WX_HTTP_MAX_RETRIES requests for a cut or
    // corrupt stream, PARSE after 1 for bytes after it (the literals at each line). Rows where
    // CFNetwork agrees with C are asserted as C.
    @Test func gzipStrictnessPlatformRows() async throws {
        let z = Self.gzipJSON
        let n = z.count
        let full = Data(Self.kGzipJson.utf8)
        #expect(n == 105, "the DECISIONS #30 rows were pinned with the 105-byte member LoopbackServer.gzip makes of kGzipJson")
        // Decoded bytes CFNetwork hands over for a member cut after k bytes (all of it from k = 97).
        let decodedLength: [Int: Int] = [52: 14, 93: 80, 94: 82, 95: 84, 96: 85]
        for k in 1..<n where Self.cutPositionWanted(k, n) {
            let body = Data(full.prefix(decodedLength[k] ?? full.count))
            if k < HTTPClient.Transfer.minimumGzipMember {
                // C: NETWORK after 1 + WX_HTTP_MAX_RETRIES requests (test-http.c:2588-2589). Fewer than
                // 20 encoded bytes (the metrics' wire count) cannot hold a gzip member, so the client
                // refuses the EMPTY body CFNetwork hands over for k = 1, 2, 9-12 (DECISIONS #45).
                try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, z, sendLen: k, declared: k)), code: .network,
                                          requests: Self.retried, "test-http.c:2588-2589: (b) k=\(k)")
            } else {
                try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, z, sendLen: k, declared: k)), code: nil, requests: 1,
                                          okBody: body, "DECISIONS #30 row (test-http.c:2588-2589; C: NETWORK x 3): (b) k=\(k)")
            }
            // C: NETWORK after 1 + WX_HTTP_MAX_RETRIES requests for every chunked cut (test-http.c:2655-2660).
            let chunkedCut = Self.chunkedResponse(Self.gzHeader, z, sendLen: k, declared: k, terminate: true)
            if k <= 12 {
                try await Self.expectCase(.raw(chunkedCut), code: .network, requests: Self.retried, "test-http.c:2658-2659: chunked cut k=\(k)")
            } else {
                try await Self.expectCase(.raw(chunkedCut), code: nil, requests: 1, okBody: body,
                                          "DECISIONS #30 row (test-http.c:2655-2660; C: NETWORK x 3): chunked cut k=\(k)")
            }
        }
        let early = [UInt8](LoopbackServer.gzip(Data(Self.kBody.utf8)))
        #expect(early.count == 54 && early[10] & 0x07 == 0x03, "kBody's member: 54 bytes, one final fixed-Huffman block")
        for k in 12...19 {
            try await Self.expectCase(.raw(Self.chunkedResponse(Self.gzHeader, early, sendLen: k, declared: k, terminate: true)),
                                      code: nil, requests: 1, okBody: Data(Self.kBody.utf8.prefix(k - 11)),
                                      "DECISIONS #30 row (test-http.c:2655-2660; C: NETWORK x 3): prefix-decoding chunked cut k=\(k)")
            try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, early, sendLen: k, declared: k)), code: .network,
                                      requests: Self.retried, "test-http.c:2588-2589: prefix-decoding member, (b) k=\(k)")
        }
        for flip in [n / 2, n - 8, n - 7, n - 4, n - 1] {                              // test-http.c:2598
            var bad = z
            bad[flip] ^= 0x01
            let server = try LoopbackServer([.raw(Self.responseWith(Self.gzHeader, bad, sendLen: n, declared: n))])
            defer { server.stop() }
            let body = Self.body(await Self.fetch(try Self.client(server, timeoutMs: 2000, backoffMs: 5)))
            let label = "DECISIONS #30 row (test-http.c:2598-2604; C: NETWORK x 3): flip at \(flip)"
            if flip == n / 2 {
                #expect(body?.count == full.count && body != full, "\(label): \(String(describing: body))")
            } else {
                #expect(body == full, "\(label): \(String(describing: body))")
            }
            #expect(server.requestCount == 1, "\(label)")
        }
        let trailing: [([UInt8], String)] = [(Array("xyz".utf8), "garbage :2615"), (z, "second member :2618"), ([z[0]], "one byte :2620")]
        for (tail, label) in trailing {
            let payload = z + tail
            try await Self.expectCase(.raw(Self.responseWith(Self.gzHeader, payload, sendLen: payload.count, declared: payload.count)),
                                      code: nil, requests: 1, okBody: full, "DECISIONS #30 row (test-http.c:2611-2621; C: PARSE x 1): \(label)")
        }
        let late = Self.responseWith(Self.gzHeader, z + Array("xyz".utf8), sendLen: n + 3, declared: n + 3)
        try await Self.expectCase(Self.split(late, first: late.count - 3), code: nil, requests: 1, okBody: full,
                                  "DECISIONS #30 row (test-http.c:2622-2624; C: PARSE x 1): late garbage")
        let zz = Self.chunkedResponse(Self.gzHeader, z + Array("zz".utf8), sendLen: n + 2, declared: n + 2, terminate: true)
        try await Self.expectCase(.raw(zz), code: nil, requests: 1, okBody: full,
                                  "DECISIONS #30 row (test-http.c:2666-2671; C: PARSE x 1): garbage in a further chunk")
        let tails: [([UInt8], String)] = [(Array("x".utf8), "x"), ([0, 0, 0, 0], "zero padding"), (Array("\n".utf8), "newline"), (z, "member")]
        for (index, (tail, name)) in tails.enumerated() {                              // test-http.c:2776-2781
            for delay in index == 0 ? [100, 700] : [100] {                               // test-http.c:2782-2786
                let label = "DECISIONS #30 row (test-http.c:2773-2813; C: PARSE x 1): \(name), \(delay) ms"
                let withTail = z + tail
                let cl = Self.framed(200, .contentLength, Self.gzHeader, withTail, sendLen: withTail.count, declared: withTail.count)
                try await Self.expectCase(Self.split(cl, first: cl.count - tail.count, delayMs: delay), code: nil, requests: 1,
                                          okBody: full, "\(label), Content-Length")
                let close = Self.framed(200, .close, Self.gzHeader, withTail, sendLen: withTail.count, declared: 0)
                try await Self.expectCase(Self.split(close, first: close.count - tail.count, delayMs: delay), code: nil, requests: 1,
                                          okBody: full, "\(label), close-delimited")
                let first = Self.chunkedResponse(Self.gzHeader, z, sendLen: n, declared: n, terminate: false)
                let chunked = first + Data("\(String(tail.count, radix: 16))\r\n".utf8) + Data(tail) + Data("\r\n0\r\n\r\n".utf8)
                try await Self.expectCase(Self.split(chunked, first: first.count, delayMs: delay), code: nil, requests: 1,
                                          okBody: full, "\(label), chunked")
            }
        }
    }

    // C: /http/net/no-content-statuses (test-http.c:2826-2868)
    @Test func noContentStatuses() async throws {
        let codings = ["", "Content-Encoding: gzip\r\n", "Content-Encoding: br\r\n", "Content-Encoding: deflate\r\n",
                       "Content-Encoding: gzip, gzip\r\n", "Content-Encoding: identity\r\n"]  // :2828-2830
        let statuses: [(Int, String?)] = [(204, nil), (205, nil), (304, Self.imsValue)]   // :2834
        for (status, ims) in statuses {
            for coding in codings {
                for framing in [Framing.contentLength, .close] {
                    let response = Self.framed(status, framing, coding, [], sendLen: 0, declared: 0)
                    let server = try LoopbackServer([.raw(response)])
                    defer { server.stop() }
                    let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
                    let outcome = await Self.fetch(http, ims: ims)
                    let label = "\(status) \(coding.debugDescription) \(framing)"
                    guard case .success(let r) = outcome else {
                        Issue.record("\(label): \(outcome)")
                        continue
                    }
                    #expect(r.status == status, "\(label)")
                    #expect(r.body.isEmpty, "\(label)")
                    #expect(server.requestCount == 1, "\(label)")
                }
            }
        }
        try await Self.expectCase(.raw(Self.responseWith("Content-Encoding: gzip\r\n", [], sendLen: 0, declared: 0)),
                                  code: .network, requests: Self.retried, "empty gzip 200")  // :2861-2862
        try await Self.expectCase(.raw(Self.responseWith("", [], sendLen: 0, declared: 0)),
                                  code: nil, requests: 1, okBody: Data(), "empty plain 200")  // :2863-2864
        try await Self.expectFailure(.respond(status: 304, headers: ["Content-Encoding: gzip"]), .http, requests: 1)  // :2866
        try await Self.expectFailure(.respond(status: 304), .http, requests: 1)    // :2867
    }

    // MARK: Outcome tests replacing the libsoup wire-framing cases (DECISIONS #10)

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/content-length-values (test-http.c:2944-2992),
    // /http/net/content-length-repeated (:2998) and /http/net/content-length-random (:3154):
    // the single-line value table x {identity, gzip} x {complete, cut}, each value judged from
    // the raw header before any body byte. '@' is the payload size, '$' a different number.
    @Test func contentLengthValueOutcomes() async throws {
        enum Kind { case large, invalid, conflict, length, cap }
        let values: [(String, Kind)] = [                                            // test-http.c:2950-2975
            ("18446744073709551615", .large), ("18446744073709551614", .large), ("18446744073709551616", .large),
            ("99999999999999999999999", .large), ("9223372036854775808", .large), ("9223372036854775807", .large),
            ("4194305", .large), ("0000000000000000000000004194305", .large), ("4194304", .cap),
            ("-1", .invalid), ("-2", .invalid), ("-9223372036854775808", .invalid), ("+5", .invalid), ("", .invalid),
            ("5x", .invalid), ("0x10", .invalid), ("1e3", .invalid), ("5 5", .invalid), ("5.0", .invalid),
            ("@, @", .length), ("@,@", .length), ("@, $", .conflict), ("@ ,", .invalid), ("@", .length),
            (" @ ", .length), ("00@", .length),
        ]
        for gzip in [false, true] {
            let payload = gzip ? Self.gzipJSON : Array(Self.kBody.utf8)
            let plain = Data((gzip ? Self.kGzipJson : Self.kBody).utf8)
            let len = payload.count
            for (template, kind) in values {
                let value = template.replacingOccurrences(of: "@", with: "\(len)").replacingOccurrences(of: "$", with: "\(len + 1)")
                for complete in [false, true] {
                    let extra = (gzip ? Self.gzHeader : "") + "Content-Length: \(value)\r\n"
                    let response = Self.framed(200, .close, extra, payload, sendLen: complete ? len : len / 2, declared: 0)
                    let label = "gzip \(gzip) Content-Length '\(value)' complete \(complete)"
                    switch kind {
                    case .large:
                        try await Self.expectCase(.raw(response), code: .parse, requests: 1, messageContains: "response too large", label)
                    case .invalid:
                        try await Self.expectCase(.raw(response), code: .parse, requests: 1, messageContains: "invalid Content-Length", label)
                    case .conflict:
                        try await Self.expectCase(.raw(response), code: .parse, requests: 1, messageContains: "conflicting Content-Length", label)
                    case .length where complete:
                        try await Self.expectCase(.raw(response), code: nil, requests: 1, okBody: plain, label)
                    case .length, .cap:
                        try await Self.expectCase(.raw(response), code: .network, requests: Self.retried, label)
                    }
                }
            }
        }
    }

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/content-length-repeated (test-http.c:2998-3059): the C table of
    // repeated and listed Content-Length lines (:3004-3025) x {identity, gzip} x {complete,
    // cut}, and the lines a chunked body ignores (:3027-3034, :3050-3056). DECISIONS #34 item 3
    // platform rows: CFNetwork refuses a head with two or more Content-Length lines whose texts
    // differ ("@" + "00@" included) before the head is visible (NSURLError -1017) and re-sends
    // it within the task, so those rows are NETWORK after 3 requests (C: OK, or PARSE after 1).
    // DECISIONS #34 item 4 platform rows: chunked framing as CFNetwork reads it, next to any
    // Content-Length line whose value does not read as a negative decimal ("3", "5x", "", "7, 3",
    // the huge values; see HTTPClient.chunkedMayCarry) is refused at the end (-1005, re-sent):
    // NETWORK after 3 requests (C: the chunked body is read, OK). Lines with identical text
    // arrive joined ("@, @") and keep the C outcome.
    @Test func contentLengthRepeatedOutcomes() async throws {
        enum Kind { case length, conflict, invalid }
        let rows: [(String, Kind)] = [                                                // test-http.c:3004-3025
            ("Content-Length: @\r\nContent-Length: @\r\n", .length), ("Content-Length: @\r\nContent-Length: 00@\r\n", .length),
            ("Content-Length: 00@\r\nContent-Length: @\r\n", .length),
            ("Content-Length: @\r\nContent-Length: @\r\nContent-Length: @\r\n", .length),
            ("Content-Length: @\r\nContent-Length: $\r\n", .conflict), ("Content-Length: $\r\nContent-Length: @\r\n", .conflict),
            ("Content-Length: @\r\nContent-Length: $\r\nContent-Length: @\r\n", .conflict),
            ("Content-Length: @\r\nContent-Length: 99999999999999999999999\r\n", .conflict),
            ("Content-Length: 9223372036854775808\r\nContent-Length: @\r\n", .conflict),
            ("Content-Length: 7\r\nContent-Length: 3\r\n", .conflict), ("Content-Length: @\r\nContent-Length: \r\n", .invalid),
            ("Content-Length: \r\nContent-Length: @\r\n", .invalid), ("Content-Length: x\r\nContent-Length: @\r\n", .invalid),
            ("Content-Length: @\r\nContent-Length: x\r\n", .invalid), ("Content-Length: @, @\r\n", .length),
            ("Content-Length: @, $\r\n", .conflict), ("Content-Length: @ , @ \r\nContent-Length: @\r\n", .length),
            ("Content-Length: \t@\t,\t00@ ,@\r\nContent-Length: @\r\n", .length),
            ("Content-Length: @ , $ \r\nContent-Length: @\r\n", .conflict), ("Content-Length: @ ,  \r\nContent-Length: @\r\n", .invalid),
        ]
        let ignored = ["Content-Length: 3\r\n", "Content-Length: 5x\r\n", "Content-Length: 9223372036854775808\r\n",  // :3027-3034
                       "Content-Length: 18446744073709551615\r\n", "Content-Length: -1\r\n", "Content-Length: \r\n",
                       "Content-Length: 7, 3\r\n", "Content-Length: @\r\nContent-Length: $\r\n"]
        /// CFNetwork refuses the head itself: several Content-Length lines of different text.
        func refusedBySystem(_ lines: String) -> Bool {
            let values = lines.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            return values.count > 1 && Set(values).count > 1
        }
        var platformRows = 0
        for gzip in [false, true] {
            let payload = gzip ? Self.gzipJSON : Array(Self.kBody.utf8)
            let plain = Data((gzip ? Self.kGzipJson : Self.kBody).utf8)
            let len = payload.count
            let coding = gzip ? Self.gzHeader : ""
            func substitute(_ template: String) -> String {
                template.replacingOccurrences(of: "@", with: "\(len)").replacingOccurrences(of: "$", with: "\(len + 1)")
            }
            for (template, kind) in rows {
                let lines = substitute(template)
                for complete in [false, true] {
                    let response = Self.framed(200, .close, coding + lines, payload, sendLen: complete ? len : len / 2, declared: 0)
                    let label = "gzip \(gzip) \(lines.debugDescription) complete \(complete)"
                    if refusedBySystem(lines) {
                        platformRows += 1
                        try await Self.expectCase(.raw(response), code: .network, requests: Self.retried,
                                                  messageContains: "-1017",
                                                  "DECISIONS #34 item 3 platform row (test-http.c:3004-3025): \(label)")
                        continue
                    }
                    switch kind {
                    case .length where complete:
                        try await Self.expectCase(.raw(response), code: nil, requests: 1, okBody: plain, label)
                    case .length:
                        try await Self.expectCase(.raw(response), code: .network, requests: Self.retried, label)
                    case .conflict:
                        try await Self.expectCase(.raw(response), code: .parse, requests: 1,
                                                  messageContains: "conflicting Content-Length", label)
                    case .invalid:
                        try await Self.expectCase(.raw(response), code: .parse, requests: 1, messageContains: "invalid Content-Length", label)
                    }
                }
            }
            // Transfer-Encoding: chunked wins (test-http.c:3050-3056).
            for template in ignored {
                let lines = substitute(template)
                let response = Self.framed(200, .chunked, coding + lines, payload, sendLen: len, declared: len)
                if lines.contains("Content-Length: -") {
                    try await Self.expectCase(.raw(response), code: nil, requests: 1, okBody: plain, "chunked + \(lines.debugDescription)")
                } else {
                    platformRows += 1
                    try await Self.expectCase(.raw(response), code: .network, requests: Self.retried,
                                              "DECISIONS #34 item \(refusedBySystem(lines) ? "3+4" : "4") platform row (test-http.c:3027-3034, :3050-3056): chunked + \(lines.debugDescription)")
                }
            }
        }
        #expect(platformRows == 2 * (16 * 2 + 7))  // 16 multi-line rows x {cut, complete} + 7 ignored lines
    }

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/content-length-vs-status (test-http.c:3201-3244): the status
    // decides first; hostile Content-Length values never change a bodiless success or an
    // error status. DECISIONS #34 item 3 platform rows: the two-line values (:3214-3215) are
    // refused by CFNetwork before the status is visible (-1017, re-sent): NETWORK after 3
    // requests for every status, also for 429 (so no RATE_LIMITED reaches a provider).
    @Test func contentLengthVersusStatusOutcomes() async throws {
        let lengths = ["Content-Length: 9223372036854775808\r\n", "Content-Length: 18446744073709551614\r\n",
                       "Content-Length: 18446744073709551615\r\n", "Content-Length: -2\r\n", "Content-Length: -16\r\n",
                       "Content-Length: 99999999999999999999\r\n", "Content-Length: 99999999999999999999999\r\n",
                       "Content-Length: -1\r\n", "Content-Length: 5x\r\n", "Content-Length: \r\n", "Content-Length: 7, 3\r\n",
                       "Content-Length: 3\r\nContent-Length: 7\r\n",
                       "Content-Length: 9223372036854775808\r\nContent-Length: -2\r\n"]          // test-http.c:3203-3215
        let cases: [(Int, String?, WxError.Code?, Int)] = [                          // test-http.c:3224-3232
            (200, nil, .parse, 1), (204, nil, nil, 1), (205, nil, nil, 1), (304, Self.imsValue, nil, 1),
            (304, nil, .http, 1), (302, nil, .http, 1), (404, nil, .notFound, 1), (429, nil, .rateLimited, 1),
            (500, nil, .http, Self.retried),
        ]
        let body = Array(Self.kBody.utf8)
        for (status, ims, code, requests) in cases {
            for length in lengths {
                for coding in ["", Self.gzHeader] {
                    let bodiless = code == nil
                    let response = Self.framed(status, .close, coding + length, body,
                                               sendLen: bodiless ? 0 : body.count, declared: 0)
                    let label = "status \(status) length \(length.debugDescription) coding \(coding.debugDescription)"
                    if length.components(separatedBy: "Content-Length").count > 2 {
                        try await Self.expectCase(.raw(response), ims: ims, code: .network, requests: Self.retried,
                                                  messageContains: "-1017",
                                                  "DECISIONS #34 item 3 platform row (test-http.c:3214-3215): \(label)")
                    } else {
                        try await Self.expectCase(.raw(response), ims: ims, code: code, requests: requests, okBody: Data(), label)
                    }
                }
            }
        }
    }

    /// The body of the Transfer-Encoding tests: a valid chunked encoding of kBody
    /// (test-http.c:3312, :3358).
    static var chunkedKBody: [UInt8] {
        Array("\(String(kBody.utf8.count, radix: 16))\r\n\(kBody)\r\n0\r\n\r\n".utf8)
    }

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/transfer-encoding-lines (test-http.c:3284-3340): the joined list
    // must be exactly "chunked"; everything else is PARSE "unsupported response framing" in
    // one request, and the status decides first. CFNetwork removes one chunked framing and
    // reports "Identity" only for a single "chunked"; every other list reaches the client as
    // another value. DECISIONS #34 item 4 platform row: "chunked" with a Content-Length (:3309) is refused by
    // CFNetwork (-1005, re-sent; C reads the chunked body). Executor row: a server that sends
    // "Identity" itself (no chunk framing removed) is PARSE as in C.
    @Test func transferEncodingOutcomes() async throws {
        let rows: [(String, Bool)] = [                                                // test-http.c:3290-3310
            ("Transfer-Encoding: chunked\r\n", true), ("Transfer-Encoding: Chunked\r\n", true),
            ("transfer-encoding: CHUNKED\r\n", true), ("Transfer-Encoding:  chunked \t\r\n", true),
            ("Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n", false),
            ("Transfer-Encoding: bogus\r\nTransfer-Encoding: chunked\r\n", false),
            ("Transfer-Encoding: chunked\r\nTransfer-Encoding: identity\r\n", false),
            ("Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n", false),
            ("Transfer-Encoding: identity\r\nTransfer-Encoding: chunked\r\n", false),
            ("Transfer-Encoding: chunked\r\nTransfer-Encoding: \r\n", false),
            ("Transfer-Encoding: \r\nTransfer-Encoding: chunked\r\n", false), ("Transfer-Encoding: gzip, chunked\r\n", false),
            ("Transfer-Encoding: chunked, chunked\r\n", false), ("Transfer-Encoding: chunked, identity\r\n", false),
            ("Transfer-Encoding: identity, chunked\r\n", false), ("Transfer-Encoding: identity\r\n", false),
            ("Transfer-Encoding: bogus\r\n", false), ("Transfer-Encoding: gzip\r\n", false), ("Transfer-Encoding:\r\n", false),
            ("Transfer-Encoding: chunked\r\nContent-Length: 9223372036854775808\r\n", true),
            ("Transfer-Encoding: gzip\r\nContent-Length: 9223372036854775808\r\n", false),
            ("Transfer-Encoding: Identity\r\n", false),                                  // executor row
        ]
        let chunked = Self.chunkedKBody
        let others: [(Int, WxError.Code?, Int)] = [(204, nil, 1), (205, nil, 1), (404, .notFound, 1),  // :3327-3332
                                                   (429, .rateLimited, 1), (500, .http, Self.retried), (302, .http, 1)]
        for (lines, ok) in rows {
            let response = Self.framed(200, .close, lines, chunked, sendLen: chunked.count, declared: 0)
            if ok && lines.contains("Content-Length") {
                try await Self.expectCase(.raw(response), code: .network, requests: Self.retried,
                                          "DECISIONS #34 item 4 platform row (test-http.c:3309): \(lines.debugDescription)")
            } else if ok {
                try await Self.expectCase(.raw(response), code: nil, requests: 1, okBody: Data(Self.kBody.utf8), lines.debugDescription)
            } else {
                try await Self.expectCase(.raw(response), code: .parse, requests: 1,
                                          messageContains: "unsupported response framing", lines.debugDescription)
                for (status, code, requests) in others {
                    let other = Self.framed(status, .close, lines, chunked, sendLen: chunked.count, declared: 0)
                    try await Self.expectCase(.raw(other), code: code, requests: requests, okBody: Data(),
                                              "\(status) \(lines.debugDescription)")
                }
            }
        }
    }

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/transfer-encoding-random (test-http.c:3349-3393): instead of 300
    // draws, every combination of its value and length tables (:3351-3357) as one line, and
    // two lines with a further value; C oracle (:3373): accepted only for ONE line that is
    // "chunked" after trimming (case-insensitive), else PARSE in one request. DECISIONS #34
    // item 5 platform rows: CFNetwork also de-chunks the single values "chunked;x", "xchunked"
    // and "chunkedd" and reports them as "Identity" (accepted, C: PARSE). DECISIONS #34 item 4
    // platform rows: it refuses such a chunked line next to a Content-Length that is not
    // negative (-1005, re-sent; C: OK or PARSE).
    @Test func transferEncodingValueOutcomes() async throws {
        let names = ["Transfer-Encoding", "transfer-encoding", "TRANSFER-ENCODING"]   // test-http.c:3351
        let values = ["chunked", "Chunked", "CHUNKED", " chunked ", "\tchunked\t", "gzip", "identity", "", "bogus",
                      "chunked, chunked", "gzip, chunked", "chunked,", ",chunked", ",", "chunked;x", "xchunked", "chunke",
                      "chunkedd"]                                                       // test-http.c:3352-3355
        let lengths = ["", "Content-Length: 3\r\n", "Content-Length: 9223372036854775808\r\n", "Content-Length: -2\r\n",
                       "Content-Length: \r\n"]                                          // test-http.c:3356-3357
        let systemChunked: Set<String> = ["chunked", "chunked;x", "xchunked", "chunkedd"]
        let chunked = Self.chunkedKBody
        var accepted = 0, platform = 0
        for (index, value) in values.enumerated() {
            for length in lengths {
                let lines = "\(names[index % names.count]): \(value)\r\n" + length
                let response = Self.framed(200, .close, lines, chunked, sendLen: chunked.count, declared: 0)
                let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\u{0B}\u{0C}\r")).lowercased()
                let cOK = trimmed == "chunked"                                          // test-http.c:3373
                let label = lines.debugDescription
                if systemChunked.contains(trimmed) && !(length.isEmpty || length.contains(": -")) {
                    platform += 1
                    try await Self.expectCase(.raw(response), code: .network, requests: Self.retried,
                                              "DECISIONS #34 \(cOK ? "item 4" : "items 4+5") platform row (test-http.c:3352-3357, :3373): \(label)")
                } else if systemChunked.contains(trimmed) {
                    if cOK { accepted += 1 } else { platform += 1 }
                    try await Self.expectCase(.raw(response), code: nil, requests: 1, okBody: Data(Self.kBody.utf8),
                                              cOK ? label : "DECISIONS #34 item 5 platform row (test-http.c:3352-3355, :3373): \(label)")
                } else {
                    try await Self.expectCase(.raw(response), code: .parse, requests: 1,
                                              messageContains: "unsupported response framing", label)
                }
            }
            for second in ["chunked", "identity", "", "gzip, chunked"] {
                for length in lengths {
                    let lines = "\(names[index % names.count]): \(value)\r\n\(names[(index + 1) % names.count]): \(second)\r\n" + length
                    let response = Self.framed(200, .close, lines, chunked, sendLen: chunked.count, declared: 0)
                    try await Self.expectCase(.raw(response), code: .parse, requests: 1,
                                              messageContains: "unsupported response framing", lines.debugDescription)
                }
            }
        }
        #expect(accepted == 5 * 2)  // the 5 "chunked" spellings, without a length or with "-2"
        #expect(platform == 5 * 3 + 3 * 5)
        // NEW documented difference U13-N8 platform rows: the mechanism of DECISIONS #34 item 5 is
        // wider than its three values. CFNetwork de-chunks every single Transfer-Encoding value
        // without a comma that contains "chunked" (case-insensitive), obs-fold included, and
        // reports it as "Identity" (accepted; C: PARSE x 1, :3373).
        for value in ["chunked gzip", "gzip chunked", "\"chunked\"", "chunked=1", "achunkedb", "chunked identity",
                      "chunked\r\n gzip"] {
            let response = Self.framed(200, .close, "Transfer-Encoding: \(value)\r\n", chunked, sendLen: chunked.count, declared: 0)
            try await Self.expectCase(.raw(response), code: nil, requests: 1, okBody: Data(Self.kBody.utf8),
                                      "NEW U13-N8 platform row (wx-http.c:1240; test-http.c:3373; C: PARSE x 1): \(value.debugDescription)")
        }
    }

    // C: /http/net/transfer-encoding-lines and /http/net/transfer-encoding-random (test-http.c:3280-3283
    // comment, oracle :3373): anything but exactly "chunked" is PARSE "unsupported response
    // framing" after 1 request, before the body (transfer_coding_is_chunked, src/net/wx-http.c:1240;
    // inspect_framing :1288-1290; on_sent :1519-1520), whatever Content-Encoding and Content-Length
    // say. CFNetwork reports a de-chunked body as "Transfer-Encoding: Identity", so a server that
    // sends "Identity" itself is told apart from the task metrics: no chunk framing removed (wire
    // body bytes equal the bytes after CFNetwork's decoding, or 0 wire bytes when CFNetwork
    // inflates), or a Content-Length that chunked framing cannot carry on a transfer that
    // completed (CFNetwork fails chunked framing with it, -1005). Controls: the same codings with
    // real chunked framing, and with a negative Content-Length (which CFNetwork carries), are
    // read. NEW documented difference U13-N4 platform rows: when CFNetwork inflates the body itself
    // (first Content-Encoding element gzip / x-gzip) and the body is close-delimited, the wire
    // count holds the compressed size and the chunk framing alike, so a non-empty body is the
    // decoded member (C: PARSE x 1), and chunk-framed bytes fail CFNetwork's inflater (-1015,
    // NETWORK x 3; C: PARSE x 1).
    @Test func serverSentIdentityOutcomes() async throws {
        let member = [UInt8](LoopbackServer.gzip(Data(#"{"a":"identity"}"#.utf8)))
        func chunk(_ payload: [UInt8]) -> [UInt8] {
            Array("\(String(payload.count, radix: 16))\r\n".utf8) + payload + Array("\r\n0\r\n\r\n".utf8)
        }
        for coding in ["", "gzip", "x-gzip", "identity, gzip"] {
            let codingLine = coding.isEmpty ? "" : "Content-Encoding: \(coding)\r\n"
            let payload = coding.isEmpty ? Array("{}".utf8) : member
            let decoded = Data((coding.isEmpty ? "{}" : #"{"a":"identity"}"#).utf8)
            let systemInflated = coding == "gzip" || coding == "x-gzip"
            func answer(_ te: String, _ extra: String, _ body: [UInt8]) -> LoopbackServer.Step {
                .raw(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: \(te)\r\n\(codingLine)\(extra)Connection: close\r\n\r\n".utf8) + body)
            }
            let label = "Content-Encoding \(coding.debugDescription)"
            // C outcomes.
            for (te, extra, body, row) in [("Identity", "Content-Length: \(payload.count)\r\n", payload, "Content-Length"),
                                           (" Identity", "Content-Length: \(payload.count)\r\n", payload, "' Identity', Content-Length"),
                                           ("Identity", "Content-Length: -1\r\n", payload, "Content-Length: -1"),
                                           ("Identity", "", [], "empty body")] {
                try await Self.expectCase(answer(te, extra, body), code: .parse, requests: 1,
                                          messageContains: "unsupported response framing", "\(label) Identity \(row)")
            }
            if systemInflated {
                try await Self.expectCase(answer("Identity", "", payload), code: nil, requests: 1, okBody: decoded,
                                          "NEW U13-N4 platform row (wx-http.c:1240, :1288-1290; C: PARSE x 1): \(label) Identity close-delimited")
                try await Self.expectCase(answer("Identity", "", chunk(payload)), code: .network, requests: Self.retried,
                                          "NEW U13-N4 platform row (wx-http.c:1240, :1288-1290; C: PARSE x 1): \(label) Identity, chunk-framed bytes")
            } else {
                for (body, row) in [(payload, "close-delimited"), (chunk(payload), "chunk-framed bytes")] {
                    try await Self.expectCase(answer("Identity", "", body), code: .parse, requests: 1,
                                              messageContains: "unsupported response framing", "\(label) Identity \(row)")
                }
            }
            // Controls: real chunked framing is read.
            try await Self.expectCase(answer("chunked", "", chunk(payload)), code: nil, requests: 1, okBody: decoded, "\(label) chunked")
            try await Self.expectCase(answer("chunked", "Content-Length: -1\r\n", chunk(payload)), code: nil, requests: 1,
                                      okBody: decoded, "\(label) chunked, Content-Length: -1")
        }
    }


    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/status-framing-table (test-http.c:3992-4044): all 780 rows of the
    // C table (2 x 3 x 5 x 4 + 12 x 2 x 5 + 9 x 3 x 2 x 10, :4043) built as table_run builds
    // them (table_run, :3920-3989), checked against the C oracle table_oracle (:3816-3875). Rows where
    // CFNetwork decides differently assert the platform outcome instead:
    //  - DECISIONS #34 item 3: two Content-Length lines (DL_CONFLICT, :3891-3893): refused by
    //    CFNetwork before the status is visible (-1017) and re-sent: NETWORK after 3 requests,
    //    for every status (54 rows);
    //  - DECISIONS #34 item 6: 204 / 205 whose head carries Transfer-Encoding lines and whose
    //    connection ends right after the head (DL_TE_* x PL_TRUNCATED, :4029-4042): -1017,
    //    NETWORK x 3 (C: OK; 24 rows);
    //  - DECISIONS #30 (gzip strictness): a gzip body with bytes after the member (PL_TRAILING,
    //    oracle :3866-3868; 6 rows of :4004-4012) is the decoded member (C: PARSE), and a
    //    close-delimited cut gzip stream (PL_TRUNCATED, oracle :3857-3860; 2 rows) is the
    //    decoded prefix (C: NETWORK x 3).
    @Test func statusFramingOutcomes() async throws {
        enum Coding: CaseIterable { case none, gzip, identity, br, badList }          // test-http.c:3760
        enum Payload: CaseIterable { case complete, truncated, trailing, empty }       // test-http.c:3761
        enum Declared: CaseIterable {                                                  // test-http.c:3764-3776
            case honest, huge, overflow, negative, empty, garbage, conflict, teGzip, teBogus, teIdentity, teChunked
            var isTransferEncoding: Bool { [.teGzip, .teBogus, .teIdentity, .teChunked].contains(self) }
        }
        struct Row: CustomStringConvertible {
            var status: Int, ims: Bool, framing: Framing, coding: Coding, payload: Payload, declared: Declared
            var description: String { "\(status) ims \(ims) \(framing) \(coding) \(payload) \(declared)" }
            var noContent: Bool { status == 204 || status == 205 || (status == 304 && ims) }  // :3808-3811
        }
        func codingHeader(_ coding: Coding) -> String {                                // test-http.c:3787-3803
            switch coding {
            case .gzip: "Content-Encoding: gzip\r\n"
            case .identity: "Content-Encoding: identity\r\n"
            case .br: "Content-Encoding: br\r\n"
            case .badList: "Content-Encoding: gzip, gzip\r\n"
            case .none: ""
            }
        }
        func declaredHeader(_ declared: Declared, _ length: Int) -> String {           // test-http.c:3878-3906
            switch declared {
            case .huge: "Content-Length: 9223372036854775808\r\n"
            case .overflow: "Content-Length: 99999999999999999999999\r\n"
            case .negative: "Content-Length: -1\r\n"
            case .empty: "Content-Length: \r\n"
            case .garbage: "Content-Length: 5x\r\n"
            case .conflict: "Content-Length: \(length)\r\nContent-Length: \(length + 1)\r\n"
            case .teGzip: "Transfer-Encoding: gzip\r\n"
            case .teBogus: "Transfer-Encoding: bogus\r\n"
            case .teIdentity: "Transfer-Encoding: identity\r\n"
            case .teChunked: "Transfer-Encoding: chunked\r\n"
            case .honest: ""
            }
        }
        let trail = Array("TRAIL".utf8)                                                // kTrail, test-http.c:3805
        /// table_oracle (test-http.c:3816-3875): the code (nil: success), requests and body.
        func oracle(_ row: Row) -> (WxError.Code?, Int, String) {
            if !row.noContent && !(200...299).contains(row.status) {
                let code: WxError.Code = row.status == 404 ? .notFound : row.status == 429 ? .rateLimited : .http
                return (code, (500...599).contains(row.status) ? Self.retried : 1, "")
            }
            if row.noContent { return (nil, 1, "") }
            if row.declared != .honest { return (.parse, 1, "") }
            if row.coding == .br || row.coding == .badList { return (.parse, 1, "") }
            let gzip = row.coding == .gzip
            switch row.payload {
            case .complete: return (nil, 1, gzip ? Self.kGzipJson : Self.kBody)
            case .empty: return gzip || row.framing != .contentLength ? (.network, Self.retried, "") : (nil, 1, "")
            case .truncated:
                return gzip || row.framing != .close
                    ? (.network, Self.retried, "") : (nil, 1, String(Self.kBody.prefix(Self.kBody.utf8.count / 2)))
            case .trailing: return gzip ? (.parse, 1, "") : (nil, 1, Self.kBody + "TRAIL")
            }
        }
        var rows: [Row] = []
        for status in [200, 206] {                                                     // test-http.c:4004-4012
            for framing in [Framing.contentLength, .chunked, .close] {
                for coding in Coding.allCases {
                    for payload in Payload.allCases { rows.append(Row(status: status, ims: false, framing: framing, coding: coding, payload: payload, declared: .honest)) }
                }
            }
        }
        let other: [(Int, Bool)] = [(204, false), (205, false), (304, true), (304, false), (301, false), (302, true),
                                    (400, false), (404, false), (429, false), (500, false), (503, false), (599, false)]  // :4017-4024
        for (status, ims) in other {
            for framing in [Framing.contentLength, .close] {
                for coding in Coding.allCases { rows.append(Row(status: status, ims: ims, framing: framing, coding: coding, payload: .complete, declared: .honest)) }
            }
        }
        for status in [200, 206, 204, 205, 304, 404, 500, 302] {                         // test-http.c:4029-4042
            for ims in status == 304 ? [false, true] : [false] {
                for coding in [Coding.none, .gzip, .br] {
                    for payload in [Payload.complete, .truncated] {
                        for declared in Declared.allCases where declared != .honest {
                            rows.append(Row(status: status, ims: ims, framing: declared.isTransferEncoding ? .chunked : .close,
                                            coding: coding, payload: payload, declared: declared))
                        }
                    }
                }
            }
        }
        let cRows: Int = 2 * 3 * 5 * 4 + 12 * 2 * 5 + 9 * 3 * 2 * 10                    // test-http.c:4043
        #expect(rows.count == cRows)
        let z = Self.gzipJSON
        var platformRows = 0
        for row in rows {
            // table_run's wire (test-http.c:3920-3966).
            var data = (row.coding == .gzip ? z : Array(Self.kBody.utf8)) + trail
            var length = data.count - trail.count
            var sendLength = length, declared = length, terminate = true
            switch row.payload {
            case .complete: break
            case .truncated: sendLength = length / 2; terminate = false
            case .trailing: sendLength = length + trail.count; declared = sendLength
            case .empty: sendLength = 0; declared = 0
            }
            if row.noContent {
                sendLength = 0
                declared = 0
            } else if !(200...299).contains(row.status) {
                data = Array(Self.kBody.utf8) + trail
                length = Self.kBody.utf8.count
                sendLength = length
                declared = length
            }
            let extra = codingHeader(row.coding) + declaredHeader(row.declared, declared)
            let response = Self.framed(row.status, row.framing, extra, data, sendLen: sendLength, declared: declared, terminate: terminate)
            let ims = row.ims ? Self.imsValue : nil
            let label = row.description
            let (code, requests, body) = oracle(row)
            let honestGzip = row.declared == .honest && row.coding == .gzip && (200...299).contains(row.status)
            if row.declared == .conflict
                || (row.status == 204 || row.status == 205) && row.declared.isTransferEncoding && row.payload == .truncated
            {
                platformRows += 1
                try await Self.expectCase(.raw(response), ims: ims, code: .network, requests: Self.retried,
                                          timeoutMs: 5000, messageContains: "-1017",
                                          row.declared == .conflict
                                              ? "DECISIONS #34 item 3 platform row (test-http.c:3891-3893, :4029-4042): \(label)"
                                              : "DECISIONS #34 item 6 platform row (test-http.c:4029-4042): \(label)")
            } else if honestGzip && row.payload == .trailing {
                platformRows += 1  // DECISIONS #30
                try await Self.expectCase(.raw(response), ims: ims, code: nil, requests: 1, okBody: Data(Self.kGzipJson.utf8),
                                          timeoutMs: 5000, "DECISIONS #30 row (test-http.c:4004-4012, oracle :3866-3868): \(label)")
            } else if honestGzip && row.payload == .truncated && row.framing == .close {
                platformRows += 1  // DECISIONS #30
                let server = try LoopbackServer([.raw(response)])
                defer { server.stop() }
                let http = try Self.client(server, timeoutMs: 5000, backoffMs: 2)
                let decoded = Self.body(await Self.fetch(http, ims: ims)) ?? Data()
                #expect(Data(Self.kGzipJson.utf8).starts(with: decoded) && decoded.count < Self.kGzipJson.utf8.count,
                        "DECISIONS #30 row (test-http.c:4004-4012, oracle :3857-3860): \(label): \(decoded.count) bytes")
                #expect(server.requestCount == 1, "\(label)")
            } else {
                let server = try LoopbackServer([.raw(response)])
                defer { server.stop() }
                let http = try Self.client(server, timeoutMs: 5000, backoffMs: 2)              // test-http.c:3971
                let outcome = await Self.fetch(http, ims: ims)
                if let code {
                    #expect(Self.wxError(outcome)?.code == code, "\(label): \(outcome)")
                    #expect(Self.wxError(outcome).map { !$0.message.contains("SENTINEL") } == true, "\(label)")
                } else {
                    #expect(Self.body(outcome) == Data(body.utf8), "\(label): \(outcome)")
                    if case .success(let response) = outcome { #expect(response.status == row.status, "\(label)") }
                }
                #expect(server.requestCount == requests, "\(label): requests")
            }
        }
        #expect(platformRows == 54 + 24 + 8)
    }

    // C: none (executor addition for the OUTCOME TESTS criterion; C contract wx-http.h:191-196:
    // "only the 3 digit status ... is used (server text is never copied) ... a malformed status
    // line is a libsoup error (N)"; N = WX_ERROR_NETWORK and retried, wx-http.h:136-137). The C
    // outcome of each line is libsoup 3.6's soup_headers_parse_status_line (soup-headers.c:286-343,
    // after soup_headers_parse_response skips leading CR/LF, :376-385), evaluated by a verbatim
    // copy of it in the U13 C oracle. Rows here are lines libsoup and CFNetwork both refuse
    // (NETWORK after 1 + WX_HTTP_MAX_RETRIES requests, no server text in the message) or both
    // accept. CFNetwork turns an unparseable answer into an HTTP/0.9-style 200 whose body is the
    // raw answer and whose metrics report 0 head bytes, which the client refuses; a status
    // outside 100...999 is refused as well. The lines where the two parsers differ are the
    // platform rows of statusLineGrammarPlatformRows.
    @Test func malformedStatusLinesAreNetworkErrors() async throws {
        let rest = "\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        let refused = ["HTTP/1.1 2OO OK", "HTTP/1.1 abc OK", "HTTP/1.1 2000 OK", "HTTP/1.1 20 OK", "HTTP/1.1 099 X",
                       "HTTP/1.1 20x OK", "HTTP/1.1 0200 OK", "HTTP/1.1 2 00 OK", "HTTP/1.1 +200 OK", "HTTP/2 200 OK",
                       "HTTP/1.2 200 OK", "HTTP/1.10 200 OK", "HTTP/0.9 200 OK", "HTTPS/1.1 200 OK", "HTTP/1 200 OK",
                       "HTTP/1. 200 OK", "HTTP/1.1200 OK"]
        for line in refused {
            let answer = line + rest
            let server = try LoopbackServer([.rawText(answer)])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let outcome = await Self.fetch(http)
            let error = Self.wxError(outcome)
            #expect(error?.code == .network, "\(line.debugDescription): \(outcome)")
            #expect(server.requestCount == Self.retried, "\(line.debugDescription)")
            for text in ["abc", "2OO", "HTTP", "{"] {
                #expect(error.map { !$0.message.contains(text) } == true, "\(line.debugDescription): \(error?.message ?? "")")
            }
        }
        // Not HTTP at all.
        try await Self.expectCase(.rawText("garbage line\r\n\r\n{\"a\":1}"), code: .network, requests: Self.retried, "garbage")
        // Accepted by both: real heads without header lines, blanks and tabs between the fields,
        // no phrase, any 3-digit status (999 and 600 are WX_ERROR_HTTP, final).
        for answer in ["HTTP/1.1 200 OK\r\n\r\n{\"a\":1}", "HTTP/1.0 200 OK\r\n\r\n{\"a\":1}"] {
            try await Self.expectCase(.rawText(answer), code: nil, requests: 1, okBody: Data(#"{"a":1}"#.utf8), answer.debugDescription)
        }
        for line in ["HTTP/1.1  200 OK", "HTTP/1.1\t200 OK", "HTTP/1.1 200", "HTTP/1.1 200\tOK", "HTTP/1.0 200 OK"] {
            try await Self.expectCase(.rawText(line + rest), code: nil, requests: 1, okBody: Data("{}".utf8), line.debugDescription)
        }
        for line in ["HTTP/1.1 999 X", "HTTP/1.1 600 X"] {
            try await Self.expectCase(.rawText(line + rest), code: .http, requests: 1, line.debugDescription)
        }
    }

    // C: none (executor addition; C contract wx-http.h:191-196, libsoup 3.6
    // soup_headers_parse_status_line, soup-headers.c:286-343, and the leading CR/LF skip of
    // soup_headers_parse_response, :376-385, outcomes from the verbatim C oracle). NEW documented
    // difference U13-N1 platform rows: libsoup's status-line grammar is not CFNetwork's. For the
    // forms CFNetwork accepts no public-API fix found among networkProtocolName ("http/1.1" for
    // every one of them) and the response fields (neither the reason phrase nor the raw line is
    // exposed); for the forms it falls back on HTTP/0.9 the raw answer arrives
    // as body bytes, and only DECISIONS #10's AVOID of a hand-written HTTP parser rules out
    // reading them (DECISIONS #36 N1).
    //  - libsoup accepts, CFNetwork falls back to HTTP/0.9 (0 head bytes): "ICY" (Shoutcast, read
    //    as HTTP/1.0), the code glued to the phrase, versions read with strtoul ("1.01",
    //    "01.1"), and one or two line breaks before the status line (a libsoup workaround for
    //    servers that send extra line breaks on a kept-open connection). C: success; Swift:
    //    NETWORK after 1 + WX_HTTP_MAX_RETRIES requests.
    //  - libsoup refuses, CFNetwork accepts: "http/" or "Http/" (libsoup compares "HTTP/"
    //    case-sensitively), versions 2.0 and 3.0 on an HTTP/1.1 connection, a blank before the
    //    status line, a NUL byte in the phrase (soup_headers_parse refuses any NUL in a head).
    //    C: NETWORK after 1 + WX_HTTP_MAX_RETRIES requests; Swift: success.
    @Test func statusLineGrammarPlatformRows() async throws {
        let rest = "\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        for answer in ["ICY 200 OK" + rest, "ICY200 OK" + rest, "HTTP/1.1 200OK" + rest, "HTTP/1.01 200 OK" + rest,
                       "HTTP/01.1 200 OK" + rest, "\r\nHTTP/1.1 200 OK" + rest, "\nHTTP/1.1 200 OK" + rest,
                       "\r\n\r\nHTTP/1.1 200 OK" + rest, "\r\nHTTP/1.1 429 X" + rest] {
            try await Self.expectCase(.rawText(answer), code: .network, requests: Self.retried,
                                      "NEW U13-N1 platform row (soup-headers.c:298-316, :376-385; C: success or the status's outcome): \(answer.prefix(20).debugDescription)")
        }
        for line in ["http/1.1 200 OK", "Http/1.1 200 OK", "HTTP/2.0 200 OK", "HTTP/3.0 200 OK", " HTTP/1.1 200 OK",
                     "\tHTTP/1.1 200 OK", "HTTP/1.1 200 O\u{0}K"] {
            try await Self.expectCase(.rawText(line + rest), code: nil, requests: 1, okBody: Data("{}".utf8),
                                      "NEW U13-N1 platform row (soup-headers.c:54-56, :298-316; C: NETWORK x 3): \(line.debugDescription)")
        }
    }

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/truncated-head (test-http.c:3713-3752): a 2xx response cut inside
    // its head is never a success; the C test accepts NETWORK or PARSE (:3746-3747). C's exact
    // outcome, from libsoup 3.6: a cut inside a line leaves a line without its LF, which
    // soup_headers_parse refuses (soup-headers.c:87-98, "Could not parse HTTP response": N), and a
    // cut after a whole line leaves a head whose body is empty or short (on_read: an empty body
    // of unknown length, or fewer bytes than Content-Length, wx-http.c:1012-1023; a chunked body
    // cut before its first size line, soup-body-input-stream.c:186-193): N. So every cut is
    // NETWORK after 1 + WX_HTTP_MAX_RETRIES requests, which is what is asserted.
    @Test func truncatedHeadOutcomes() async throws {
        let z = Self.gzipJSON
        for framing in [Framing.contentLength, .chunked, .close] {
            for gzip in [false, true] {
                let payload = gzip ? z : Array(Self.kBody.utf8)
                let response = Self.framed(200, framing, gzip ? Self.gzHeader : "", payload, sendLen: payload.count,
                                           declared: payload.count)
                let headLength = try #require(response.range(of: Data("\r\n\r\n".utf8))).upperBound
                for k in 1...headLength where Self.cutPositionWanted(k, headLength) {
                    let server = try LoopbackServer([.raw(response.prefix(k))])
                    defer { server.stop() }
                    let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
                    let outcome = await Self.fetch(http)
                    let code = Self.wxError(outcome)?.code
                    #expect(code == .network,
                            "cut head: framing \(framing) gzip \(gzip) after \(k) of \(headLength) bytes: \(outcome)")
                    #expect(server.requestCount == Self.retried, "cut head: framing \(framing) gzip \(gzip) after \(k)")
                }
            }
        }
    }

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/chunk-size-garbage (test-http.c:3618-3655): a damaged first
    // chunk-size line is a failed transfer (C: NETWORK after 1 + WX_HTTP_MAX_RETRIES requests,
    // :3628-3630). For a damaged LATER line the C test accepts an error or just the first chunk
    // (:3631-3651); libsoup 3.6 itself reads every one of these lines with strtoul as size 0 or
    // a negative size (soup-body-input-stream.c:195-199), i.e. as the last chunk, so C returns
    // "abc" (wx-http.h:128-130). CFNetwork returns "abc" only for ";"; the other later lines
    // are NEW documented difference U13-N6 platform rows (NETWORK after 1 + WX_HTTP_MAX_RETRIES
    // requests, inside what the C test accepts).
    @Test func chunkSizeGarbageOutcomes() async throws {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"  // :3620
        for bad in ["zz", "-1", "x", ";", "g3", "\u{01}"] {                          // test-http.c:3625
            try await Self.expectCase(.rawText("\(head)\(bad)\r\nabc\r\n0\r\n\r\n"), code: .network,
                                      requests: Self.retried, "first \(bad.debugDescription)")
            let later = LoopbackServer.Step.rawText("\(head)3\r\nabc\r\n\(bad)\r\ndef\r\n0\r\n\r\n")
            if bad == ";" {
                try await Self.expectCase(later, code: nil, requests: 1, okBody: Data("abc".utf8), "later \(bad.debugDescription)")
            } else {
                try await Self.expectCase(later, code: .network, requests: Self.retried,
                                          "NEW U13-N6 platform row (soup-body-input-stream.c:195-199; C: \"abc\"): later \(bad.debugDescription)")
            }
        }
    }

    // C: none (executor addition for the OUTCOME TESTS criterion; wx-http.h:214-224: "lenient
    // chunk framing ... decided by libsoup's parser"). C outcomes from libsoup 3.6's chunked
    // reader (soup-body-input-stream.c:163-262): the chunk-size line is read up to its CRLF into
    // a 128-byte buffer (soup_filter_input_stream_read_until, soup-filter-input-stream.c:320-340;
    // a longer line is an error, N) and converted with strtoul(line, NULL, 16), which skips
    // blanks, takes a sign and a "0x" prefix and stops at the first other byte (an extension);
    // the bytes between a chunk's data and the next CRLF are skipped; trailer lines are skipped
    // up to the empty line, and the end of the stream before it is an error (N). Rows where
    // CFNetwork agrees are asserted with C's outcome; NEW documented difference U13-N6 platform
    // rows where it does not.
    @Test func chunkFramingGrammarRows() async throws {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        let abc = Data("abc".utf8)
        let agree: [(String, WxError.Code?)] = [
            ("3;x\r\nabc\r\n0\r\n\r\n", nil), ("3;ext\r\nabc\r\n0\r\n\r\n", nil), ("3 ;e\r\nabc\r\n0\r\n\r\n", nil),
            ("3; e\r\nabc\r\n0\r\n\r\n", nil), ("3 \r\nabc\r\n0\r\n\r\n", nil), ("0003\r\nabc\r\n0\r\n\r\n", nil),
            ("3;" + String(repeating: "e", count: 123) + "\r\nabc\r\n0\r\n\r\n", nil),   // a 127-byte size line
            ("3;" + String(repeating: "e", count: 124) + "\r\nabc\r\n0\r\n\r\n", nil),   // a 128-byte size line
            ("3\r\nabc\r\n0\r\nX-T: 1\r\n\r\n", nil),                                      // a trailer
            ("3\r\nabc\r\n0\r\nX-T: " + String(repeating: "t", count: 200) + "\r\n\r\n", nil),
            ("3\r\nabc\r\n0\r\n", .network),                                               // no empty line after "0"
            ("3\r\nabc\r\n0\r\nX-T: 1\r\n", .network),
            ("3\nabc\n0\n\n", .network),                                                   // LF-only framing
            ("ffffffffffffffffff\r\nabc\r\n0\r\n\r\n", .network),                          // strtoul overflow first: empty body
            ("7fffffffffffffff\r\nabc", .network),
        ]
        for (body, code) in agree {
            try await Self.expectCase(.rawText(head + body), code: code, requests: code == nil ? 1 : Self.retried, okBody: abc,
                                      body.prefix(24).debugDescription)
        }
        try await Self.expectCase(.rawText(head + "A\r\n0123456789\r\n0\r\n\r\n"), code: nil, requests: 1,
                                  okBody: Data("0123456789".utf8), "upper-case hex")
        // NEW U13-N6 platform rows: C "abc" (strtoul / bytes skipped), CFNetwork refuses (-1017).
        for body in ["3;e=1\r\nabc\r\n0\r\n\r\n", "3;a=b;c=d\r\nabc\r\n0\r\n\r\n", "0x3\r\nabc\r\n0\r\n\r\n",
                     "+3\r\nabc\r\n0\r\n\r\n", " 3\r\nabc\r\n0\r\n\r\n", "3\r\nabcXYZ\r\n0\r\n\r\n",
                     "3\r\nabc\r\nffffffffffffffffff\r\ndef\r\n0\r\n\r\n"] {
            try await Self.expectCase(.rawText(head + body), code: .network, requests: Self.retried,
                                      "NEW U13-N6 platform row (soup-body-input-stream.c:195-232; C: \"abc\"): \(body.prefix(24).debugDescription)")
        }
        // NEW U13-N6 platform rows: C refuses a size line longer than 128 bytes (N), CFNetwork reads it.
        for extra in [125, 296] {
            try await Self.expectCase(.rawText(head + "3;" + String(repeating: "e", count: extra) + "\r\nabc\r\n0\r\n\r\n"),
                                      code: nil, requests: 1, okBody: abc,
                                      "NEW U13-N6 platform row (soup-filter-input-stream.c:320-340; C: NETWORK x 3): size line of \(extra + 4) bytes")
        }
    }

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/informational-heads (test-http.c:3410-3438), the C heads verbatim.
    // The final head has no Content-Type, so CFNetwork holds it back for content sniffing; when
    // the connection then ends before the declared length, the client judges the head from the
    // task metrics, as C judges every head before its body.
    @Test func informationalHeadOutcomes() async throws {
        let body = #"{"ok":true}"#                                                   // test-http.c:3413
        for hostile in ["9223372036854775808", "-2", "18446744073709551614", "5x", "7, 3"] {  // :3412
            for kind in [100, 102] {
                let good = "HTTP/1.1 \(kind) X\r\nContent-Length: \(hostile)\r\nTransfer-Encoding: gzip\r\n\r\n"
                    + "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n\(body)"
                try await Self.expectCase(.rawText(good), code: nil, requests: 1, okBody: Data(body.utf8), "interim \(kind) \(hostile)")
                let bad = "HTTP/1.1 \(kind) X\r\nContent-Length: 11\r\n\r\n"
                    + "HTTP/1.1 200 OK\r\nContent-Length: \(hostile)\r\nConnection: close\r\n\r\n\(body)"   // :3425-3428
                try await Self.expectCase(.rawText(bad), code: .parse, requests: 1, "final \(kind) \(hostile)")
                let error = "HTTP/1.1 \(kind) X\r\n\r\nHTTP/1.1 404 NF\r\nContent-Length: \(hostile)\r\nConnection: close\r\n\r\n\(body)"
                try await Self.expectCase(.rawText(error), code: .notFound, requests: 1, "404 after \(kind) \(hostile)")
            }
        }
    }

    // C: /http/net/informational-heads (test-http.c:3410-3438) with the C contract wx-http.h:192-193
    // ("1xx heads are skipped by libsoup and ignored here"): libsoup 3.6 skips every 1xx head and
    // reads the next one (soup-client-message-io-http1.c:578-603; 101 included, which only a
    // WebSocket request handles, soup-session.c:3869-3871), each head under its own size limit
    // (the head buffer is emptied per head, :560). The end of the stream after a 1xx head is
    // "Connection terminated unexpectedly" (N). NEW documented difference U13-N7 platform rows:
    // CFNetwork takes a 101 as the final response (WX_ERROR_HTTP after 1 request), so the head
    // that follows it is never read.
    @Test func interimHeadOutcomes() async throws {
        let final = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        for interim in ["HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 100 Continue\r\n\r\n",
                        "HTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n",
                        "HTTP/1.1 199 X\r\n\r\n"] {
            try await Self.expectCase(.rawText(interim + final), code: nil, requests: 1, okBody: Data("{}".utf8), interim.debugDescription)
        }
        try await Self.expectCase(.rawText("HTTP/1.1 100 Continue\r\n\r\n"), code: .network, requests: Self.retried, "100, then the end")
        // A 1xx head has no body: what follows is read as the next head ("hello..." is no status line).
        try await Self.expectCase(.rawText("HTTP/1.1 100 Continue\r\nContent-Length: 5\r\n\r\nhello" + final), code: .network,
                                  requests: Self.retried, "100 with body bytes")
        try await Self.expectCase(.rawText("HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\nConnection: Upgrade\r\n\r\n" + final),
                                  code: .http, requests: 1,
                                  "NEW U13-N7 platform row (soup-client-message-io-http1.c:578-603; C: success, the final head)")
        try await Self.expectCase(.rawText("HTTP/1.1 101 Switching Protocols\r\n\r\n"), code: .http, requests: 1,
                                  "NEW U13-N7 platform row (soup-client-message-io-http1.c:578-603; C: NETWORK x 3)")
    }

    /// A 2xx head (status line, Content-Type, Content-Length: 2, Connection: close, one X-Pad
    /// line) whose status line and header lines, with their line ends, are exactly `lineBytes`
    /// long, then the blank line.
    static func paddedHead(lineBytes: Int, status: String = "HTTP/1.1 200 OK", eol: String = "\r\n",
                           contentLength: Int = 2, contentType: Bool = true) -> String {
        var head = status + eol + (contentType ? "Content-Type: application/json" + eol : "")
            + "Content-Length: \(contentLength)" + eol + "Connection: close" + eol
        let fixed = "X-Pad: ".utf8.count + eol.utf8.count
        head += "X-Pad: " + String(repeating: "a", count: lineBytes - head.utf8.count - fixed) + eol
        precondition(head.utf8.count == lineBytes)
        return head + eol
    }

    // C: none (executor addition for the OUTCOME TESTS criterion: oversized responses). C contract
    // wx-http.h:199 ("head above 100 KiB ... : N"): libsoup 3.6 reads the head line by line and,
    // after each line (or each 8 KiB of a longer one), refuses it as "Header too big" once more
    // than 100 * 1024 bytes are buffered (http1/soup-message-io-data.c:20, :102-107); the blank
    // line that ends the head is not checked (:82-100). normalize_error makes it NETWORK
    // (wx-http.c:691-708), retried (wx-http.c:771-779): 1 + WX_HTTP_MAX_RETRIES requests, and the
    // status is never looked at. So C accepts a head whose status line and header lines total
    // 102400 bytes and refuses 102401. The client reads URLSessionTaskMetrics'
    // countOfResponseHeaderBytesReceived (which includes the CRLF blank line) when the transfer
    // ends; CFNetwork has buffered the whole head by then. NEW U13-N2(d), HTTP/2 heads (not
    // limited by the client; libsoup's http2 code has no HEADER_SIZE_LIMIT either): not testable
    // on loopback (no h2 server here); probe evidence only.
    @Test func responseHeadSizeLimit() async throws {
        for (lines, accepted) in [(102_399, true), (102_400, true), (102_401, false), (1024 * 1024, false)] {
            let answer = Self.paddedHead(lineBytes: lines) + "{}"
            if accepted {
                try await Self.expectCase(.rawText(answer), code: nil, requests: 1, okBody: Data("{}".utf8), "head lines \(lines)")
            } else {
                try await Self.expectCase(.rawText(answer), code: .network, requests: Self.retried,
                                          messageContains: "response head too large", "head lines \(lines)")
            }
        }
        // The head is refused before its status and body count (C never parses it).
        try await Self.expectCase(.rawText(Self.paddedHead(lineBytes: 110 * 1024, status: "HTTP/1.1 429 X") + "{}"),
                                  code: .network, requests: Self.retried, "429 with a 110 KiB head")
        try await Self.expectCase(.rawText(Self.paddedHead(lineBytes: 110 * 1024, status: "HTTP/1.1 204 X", contentLength: 0)),
                                  code: .network, requests: Self.retried, "204 with a 110 KiB head")
        // A server that keeps the connection open with an incomplete body: refused when the attempt
        // deadline ends the transfer (C: at once; NEW U13-N2 timing), with or without Content-Type. On a
        // ManualClock (expectHeld): each of the three deadlines is played 1 s after the server's send of
        // the 110 KiB head completed, and no attempt may end before its deadline (DECISIONS #66, #76).
        for contentType in [true, false] {
            let held = Self.paddedHead(lineBytes: 110 * 1024, contentLength: 50, contentType: contentType) + "{\"a\""
            try await Self.expectHeld(Data(held.utf8), code: .network, requests: Self.retried, messageContains: "response head too large",
                                      atDeadline: true,
                                      "NEW U13-N2 platform row (soup-message-io-data.c:102-107; C: three refusals at once): kept open, Content-Type \(contentType)")
        }
        // NEW documented difference U13-N10 platform row: the transport message is the client's fixed
        // phrase; C's is "network error: " + libsoup's own text, here "Header too big" (wx-http.c:706).
        let server = try LoopbackServer([.rawText(Self.paddedHead(lineBytes: 102_401) + "{}")])
        defer { server.stop() }
        let error = Self.wxError(await Self.fetch(try Self.client(server, timeoutMs: 2000, backoffMs: 5)))
        #expect(error?.message == "network error: response head too large",
                "NEW U13-N10 platform row (wx-http.c:706; C: \"network error: Header too big\"): \(String(describing: error))")
        // NEW documented difference U13-N2 platform rows. CFNetwork's count includes the blank line
        // and every 1xx head: a head ended by bare LFs counts one byte less (C refuses 102401 line
        // bytes, here it passes), and a 100 Continue head is added to the final head's count (C
        // limits each head on its own).
        try await Self.expectCase(.rawText(Self.paddedHead(lineBytes: 102_401, eol: "\n") + "{}"), code: nil, requests: 1,
                                  okBody: Data("{}".utf8),
                                  "NEW U13-N2 platform row (soup-message-io-data.c:82-107; C: NETWORK x 3): LF head of 102401 line bytes")
        try await Self.expectCase(.rawText("HTTP/1.1 100 Continue\r\n\r\n" + Self.paddedHead(lineBytes: 102_400) + "{}"),
                                  code: .network, requests: Self.retried,
                                  "NEW U13-N2 platform row (soup-client-message-io-http1.c:560; C: success): 100 Continue + a 102400-byte final head")
    }

    // C: none (executor addition for the OUTCOME TESTS criterion: garbled heads). C contract
    // wx-http.h:199 and :214-218 ("a line libsoup cannot parse: N"; "names with blanks, obs-fold,
    // bare LF, odd bytes, repeated lines ... are decided by libsoup's parser"). libsoup 3.6
    // soup_headers_parse (soup-headers.c:38-150): a NUL byte anywhere in the head refuses it (N,
    // :54-56); a line without ':' or whose name is empty or holds a blank is ignored (:77-91);
    // obs-fold lines are joined to the value with one space (:100-129); a bare CR in a value
    // becomes a space (:138-140); the head ends only at an empty line of CRLF or LF
    // (soup-message-io-data.c:82-100). CFNetwork keeps NUL bytes in header names and values (so
    // the client refuses them as C does), but normalises the rest: NEW documented difference
    // U13-N5 platform rows.
    @Test func headerSyntaxOutcomes() async throws {
        let pre = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        let tail = "Connection: close\r\n\r\n"
        // NUL in a header name or value: N, before the status.
        for (label, answer) in [("NUL in a value", pre + "X-A: a\u{0}b\r\nContent-Length: 2\r\n" + tail + "{}"),
                                ("NUL in a name", pre + "X-\u{0}A: ab\r\nContent-Length: 2\r\n" + tail + "{}"),
                                ("NUL in Content-Length", pre + "Content-Length: 2\u{0}\r\n" + tail + "{}"),
                                ("NUL in a 429 head", "HTTP/1.1 429 X\r\nContent-Type: application/json\r\nX-A: a\u{0}b\r\nContent-Length: 2\r\n" + tail + "{}")] {
            try await Self.expectCase(.rawText(answer), code: .network, requests: Self.retried, messageContains: "malformed response", label)
        }
        // Agreeing rows: ignored lines, a blank inside a name, obs-fold, repeated equal lengths.
        // (label, answer, C's body, C's Last-Modified)
        let agree: [(String, String, String, String?)] = [
            ("no colon", pre + "nocolon\r\nContent-Length: 2\r\n" + tail + "{}", "{}", nil),
            ("empty name", pre + ": ab\r\nContent-Length: 2\r\n" + tail + "{}", "{}", nil),
            ("blank inside a name (ignored)", pre + "Content Length: 2\r\n" + tail + "{}xyz", "{}xyz", nil),
            ("Content-Length line folded into the line before", pre + " Content-Length: 2\r\n" + tail + "{}xyz", "{}xyz", nil),
            ("obs-fold Content-Length", pre + "Content-Length:\r\n 2\r\n" + tail + "{}xyz", "{}", nil),
            ("obs-fold Last-Modified", pre + "Last-Modified: a\r\n b\r\nContent-Length: 2\r\n" + tail + "{}", "{}", "a b"),
            ("repeated equal Content-Length", pre + "Content-Length: 2\r\nContent-Length: 2\r\n" + tail + "{}", "{}", nil),
            ("bare LF line ends", "HTTP/1.1 200 OK\nContent-Type: application/json\nContent-Length: 2\nConnection: close\n\n{}", "{}", nil),
        ]
        for (label, answer, body, lastModified) in agree {
            let server = try LoopbackServer([.rawText(answer)])
            defer { server.stop() }
            let http = try Self.client(server, timeoutMs: 2000, backoffMs: 5)
            let outcome = await Self.fetch(http)
            #expect(Self.body(outcome) == Data(body.utf8), "\(label): \(outcome)")
            if case .success(let response) = outcome { #expect(response.lastModified == lastModified, "\(label)") }
            #expect(server.requestCount == 1, "\(label)")
        }
        // NEW U13-N5 platform rows.
        let rows: [(String, String, WxError.Code?, String?, String)] = [
            ("blank before the colon of Content-Length", pre + "Content-Length : 2\r\n" + tail + "{}xyz", nil, "{}", "C: the line is ignored, body \"{}xyz\""),
            ("tab before the colon of Content-Length", pre + "Content-Length\t: 2\r\n" + tail + "{}xyz", nil, "{}", "C: body \"{}xyz\""),
            ("blank before the colon of Transfer-Encoding", pre + "Transfer-Encoding : chunked\r\n" + tail + "2\r\n{}\r\n0\r\n\r\n", nil, "{}",
             "C: close-delimited, body is the raw chunk framing"),
            ("blank before the colon of Content-Encoding", pre + "Content-Encoding : br\r\nContent-Length: 2\r\n" + tail + "{}", .parse, nil, "C: body \"{}\""),
            ("bare CR in Content-Length", pre + "Content-Length: 2\r3\r\n" + tail + "{}xyz", nil, "{}", "C: \"2 3\", PARSE x 1"),
            ("bare CR in Transfer-Encoding", pre + "Transfer-Encoding: chunked\rx\r\n" + tail + "2\r\n{}\r\n0\r\n\r\n", nil, "{}", "C: \"chunked x\", PARSE x 1"),
            ("NUL in a line CFNetwork drops", pre + "\u{0}\r\nContent-Length: 2\r\n" + tail + "{}", nil, "{}", "C: NETWORK x 3"),
            ("blank line CR CR LF", pre + "Content-Length: 2\r\nConnection: close\r\n\r\r\n{}", nil, "{}", "C: the head does not end there, NETWORK x 3"),
        ]
        for (label, answer, code, body, c) in rows {
            try await Self.expectCase(.rawText(answer), code: code, requests: 1, okBody: body.map { Data($0.utf8) },
                                      "NEW U13-N5 platform row (soup-headers.c:38-150; \(c)): \(label)")
        }
        let bareCR = try LoopbackServer([.rawText(pre + "Last-Modified: a\rb\r\nContent-Length: 2\r\n" + tail + "{}")])
        defer { bareCR.stop() }
        let lastModified = try await Self.fetch(try Self.client(bareCR, timeoutMs: 2000, backoffMs: 5)).get().lastModified
        #expect(lastModified == "a", "NEW U13-N5 platform row (soup-headers.c:138-140; C: \"a b\"): bare CR in Last-Modified")
    }

    // C: (a wire-framing case, replaced by outcome tests: DECISIONS #10) /http/net/unread-headers-ignored (test-http.c:3663-3704). The Alt-Svc row
    // only shows that the cleartext loopback answer is used as is: URLSession ignores Alt-Svc
    // on http, so this row says nothing about HTTP/3 on https origins (a platform behaviour
    // with no public opt-out, recorded in the U13 debrief).
    @Test func unreadHeadersAreIgnored() async throws {
        let body = Array(Self.kBody.utf8)
        let hostile = ["Location: http://evil.example/\r\n", "Content-Location: http://evil.example/x\r\n",
                       "Retry-After: 3600\r\n", "Content-Type: text/html; charset=utf-7\r\n",
                       "Content-Range: bytes 0-1/99999\r\n", "Set-Cookie: a=b; Domain=.example\r\n",
                       // DECISIONS #34 item 9 (Alt-Svc / HTTP/3 on https origins): not probed; not
                       // testable on loopback. This row only shows the cleartext answer is used as is.
                       "Alt-Svc: h3=\":443\"; ma=86400\r\n", "Trailer: Content-Length\r\n",
                       "Link: <http://evil.example/>; rel=preload\r\n", "Refresh: 0; url=http://evil.example/\r\n",
                       "Content-Disposition: attachment; filename=\"x\"\r\n", "X-Content-Length: 5\r\n",
                       "Content-Length-X: 5\r\n", "X-Transfer-Encoding: chunked\r\n", "X-Content-Encoding: gzip\r\n",
                       "Keep-Alive: timeout=0, max=0\r\n", "Strict-Transport-Security: max-age=0\r\n"]  // :3665-3681
        for header in hostile {
            try await Self.expectCase(.raw(Self.framed(200, .contentLength, header, body, sendLen: body.count, declared: body.count)),
                                      code: nil, requests: 1, okBody: Data(body), header.debugDescription)
        }
        let begin = ContinuousClock.now
        try await Self.expectCase(.raw(Self.framed(503, .contentLength, "Retry-After: 3600\r\n", body, sendLen: body.count, declared: body.count)),
                                  code: .http, requests: Self.retried, "503 Retry-After")
        #expect(ContinuousClock.now - begin < .seconds(20))                           // test-http.c:3692
        try await Self.expectCase(.raw(Self.framed(429, .contentLength, "Retry-After: 3600\r\n", body, sendLen: body.count, declared: body.count)),
                                  code: .rateLimited, requests: 1, "429 Retry-After")
        try await Self.expectCase(.raw(Self.framed(401, .contentLength, "WWW-Authenticate: Basic realm=\"x\"\r\n", body, sendLen: body.count, declared: body.count)),
                                  code: .http, requests: 1, "401 challenge")
        try await Self.expectCase(.raw(Self.framed(407, .contentLength, "Proxy-Authenticate: Basic realm=\"x\"\r\n", body, sendLen: body.count, declared: body.count)),
                                  code: .http, requests: 1, "407 challenge")
    }

    // C: /http/net/connection-not-reused (test-http.c:3522-3609; its first head, :3531, verbatim
    // in connectionNotReusedAfterRejection (B)) with on_sent (src/net/wx-http.c:1485-1540): C
    // decides a head as soon as it arrives (the session has no content sniffer), the status first
    // (:1501-1508: 429 RATE_LIMITED, 404 NOT_FOUND, other 3xx/4xx HTTP, final; 5xx HTTP, retried),
    // then the framing (:1518-1521) and the content coding, whatever the body does later. Except
    // 401, 407 and 421: libsoup reads their whole body before on_sent runs (libsoup 3.6.6
    // soup-session.c:2702-2720, :2838-2864), so with a stalled body C times out, and so does the
    // client, which waits for that body too (bodyFirstStatusOutcomes). CFNetwork holds back every
    // head until at least its first body byte arrives, and one without Content-Type longer, until
    // it has sniffed the body (probe-p7/p1b.log:10-12; DECISIONS #45 condition 5), and never
    // delivers it while the server keeps the connection open with an incomplete body; the
    // attempt deadline then cancels the transfer and the client judges the withheld head from
    // the task metrics, so the C outcome and request count hold. NEW documented difference
    // U13-N3 (platform rows): the outcome comes at the attempt deadline's wake-up instead of at
    // once (so a 5xx retry starts later; the system clock wakes about 6.5 % late), and when the
    // whole-operation deadline ends the attempt first, a retryable verdict ends as TIMEOUT
    // "operation deadline exceeded" after that attempt (C would have retried at once). A head
    // with no body byte at all is not in the metrics: NEW U13-N16 (headWithoutAnyBodyByte).
    @Test func withheldHeadsAreJudgedAtTheDeadline() async throws {
        let n3 = "NEW U13-N3 platform row (wx-http.c:1501-1508; C: at once)"
        let rows: [(String, WxError.Code, Int)] = [
            ("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 50\r\n\r\n{\"a\"", .rateLimited, 1),
            ("HTTP/1.1 404 Not Found\r\nContent-Length: 50\r\n\r\n{\"a\"", .notFound, 1),
            ("HTTP/1.1 302 Found\r\nLocation: /y\r\nContent-Length: 50\r\n\r\n{\"a\"", .http, 1),
            ("HTTP/1.1 401 X\r\nContent-Length: 50\r\n\r\n{\"a\"", .timeout, Self.retried),  // the body never ends, soup-session.c:2838-2864, wx-http.c:704
            ("HTTP/1.1 503 X\r\nContent-Length: 50\r\n\r\n{\"a\"", .http, Self.retried),
            ("HTTP/1.1 200 OK\r\nContent-Length: 4194305\r\n\r\n{\"a\"", .parse, 1),
            ("HTTP/1.1 200 OK\r\nContent-Length: 5x\r\n\r\n{\"a\"", .parse, 1),
            ("HTTP/1.1 200 OK\r\nContent-Length: 7, 3\r\n\r\n{\"a\"", .parse, 1),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n{\"a\"", .parse, 1),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: Identity\r\n\r\n{\"a\"", .parse, 1),
            // A 2xx whose body stays incomplete: C reads it until the deadline too (TIMEOUT).
            ("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{\"a\"", .timeout, Self.retried),
        ]
        // On a ManualClock (expectHeld): each deadline is played 1 s after the server's send of the head
        // completed (300 ms for the TIMEOUT rows), and no attempt may end before its deadline
        // (DECISIONS #66, #76).
        for (head, code, requests) in rows {
            try await Self.expectHeld(Data(head.utf8), code: code, requests: requests, atDeadline: true,
                                      "\(n3): \(head.prefix(40).debugDescription)")
        }
        // The whole-operation deadline (4 s on the clock) ends the first attempt (6 s).
        for (head, code, label) in [(rows[0].0, WxError.Code.rateLimited, "429: C's outcome"),
                                    (rows[4].0, .timeout, "NEW U13-N3 platform row (wx-http.c:1501-1508, :766-784; C: HTTP after 3 requests): 503")] {
            try await Self.expectHeld(Data(head.utf8), code: code, requests: 1, timeoutMs: 6000, totalDeadlineMs: 4000,
                                      message: code == .timeout ? HTTPPolicy.Message.deadlineExceeded : nil, atDeadline: true, label)
        }
    }

    // C: /http/net/connection-not-reused (test-http.c:3522-3609) with on_sent (wx-http.c:1485-1540),
    // on_deadline (:807-813) and fail_attempt (:766-784): the race between a withheld head and the
    // attempt deadline (DECISIONS #38, V1-D1). C judges status, framing and coding when the head
    // ARRIVES (:1504-1508, :1519-1521) and a body only once it is complete: a 2xx whose body
    // completes after the deadline is TIMEOUT "request timed out" (:704), retried (:771-779).
    // CFNetwork hands a head over only with its first body byte or the end of its body (later
    // still when it sniffs the body), so a head that came in time can reach the client after the
    // deadline, before the deadline's wake-up (the system clock wakes about 6.5 % late) has
    // cancelled the transfer; Transfer.verdictTime then dates the verdict by the response's first
    // byte (URLSessionTaskTransactionMetrics.responseStartDate), and verdicts on body bytes keep the
    // time they were reached. Each row drives one attempt (HTTPClient.Transfer: the production
    // delegate path, real CFNetwork and metrics) on a ManualClock with no deadline sleeper against
    // a GatedServer that sends each piece only when the row says so (gatedAttempt): the head comes
    // first, the clock is moved past the deadline (or to it, or not at all), and only then is the
    // rest of the body sent (DECISIONS #66). Two real-time windows remain, both long against
    // loopback delivery: verdictTime compares the first byte's REAL offset from the task's start
    // with the clock deadline, so the in-time rows need the first byte within their deadline, 10 s
    // (2 s for the N13 rows, whose rest must come later than that), and the cancel-path row needs the
    // withheld head read by CFNetwork within the 1 s settle after the server's send (DECISIONS #76).
    // The late-head rows (DECISIONS #53, #76) send the head 300 ms after the request with the clock
    // already past a 150 ms deadline: C has timed out before any head byte, whatever the head
    // holds (a status, a 100 KiB head, an HTTP/0.9 answer, a server-sent Identity). C's request count follows from
    // the outcome through the client's retry rule HTTPPolicy.shouldRetry (C: fail_attempt): x1 for
    // a final outcome, x3 otherwise.
    @Test func lateDeliveredHeadsAreDatedByTheirArrival() async throws {
        let inTimeUs: Int64 = 10_000_000                                              // the in-time rows' deadline
        let n13Us: Int64 = 2_000_000                                                  // the N13 rows' deadline
        let lateUs: Int64 = 150_000                                                   // the late-head rows' deadline
        let body = #"{"a":12345}"#
        let length = "Content-Length: \(body.utf8.count)\r\n"
        /// The head and `first` body bytes as one piece, the rest of the body as the next.
        func split(_ head: String, first: Int = 4) -> [Data] {
            let all = Data((head + body).utf8)
            return [Data(all.prefix(head.utf8.count + first)), Data(all.dropFirst(head.utf8.count + first))]
        }
        enum ClockMove { case untouched, atDeadline, past, pastAndExpired }
        let coded401Head = "HTTP/1.1 401 X\r\nContent-Encoding: gzip\r\nContent-Length: \(Self.gzipJSON.count)\r\n\r\n"
        let ct429 = "HTTP/1.1 429 X\r\nContent-Type: application/json\r\n\(length)Connection: close\r\n\r\n\(body)"
        let fiveX = Data("HTTP/1.1 200 OK\r\nContent-Length: 5x\r\nConnection: close\r\n\r\n{\"a\":1}".utf8)
        let identityCT = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: Identity\r\nConnection: close\r\n\r\n{\"a\":1}"
        let identityNoCT = "HTTP/1.1 200 OK\r\nTransfer-Encoding: Identity\r\nConnection: close\r\n\r\n{\"a\":1}"
        let bigHead = Self.paddedHead(lineBytes: 110 * 1024) + "{}"
        let garbled = "XYZZY nonsense\r\n\r\n{}"
        // (label, pieces, clock, head after the deadline, C's outcome: code (nil = success) and HTTP status, C's requests)
        let rows: [(String, [Data], ClockMove, Bool, WxError.Code?, Int, Int)] = [
            ("429, body done before the deadline", split("HTTP/1.1 429 Too Many Requests\r\n\(length)\r\n"), .untouched, false, .rateLimited, 429, 1),  // wx-http.c:661-662
            ("429, body done at the deadline", split("HTTP/1.1 429 Too Many Requests\r\n\(length)\r\n"), .atDeadline, false, .rateLimited, 429, 1),
            ("429, body done in the late-wake window", split("HTTP/1.1 429 Too Many Requests\r\n\(length)\r\n"), .past, false, .rateLimited, 429, 1),
            ("429, body done after the wake-up (cancel path)", split("HTTP/1.1 429 Too Many Requests\r\n\(length)\r\n"), .pastAndExpired, false, .rateLimited, 429, 1),
            ("429 with Content-Type, no body byte with the head, late-wake window",
             split("HTTP/1.1 429 X\r\nContent-Type: application/json\r\n\(length)\r\n", first: 0), .past, false, .rateLimited, 429, 1),
            ("404, late-wake window", split("HTTP/1.1 404 Not Found\r\n\(length)\r\n"), .past, false, .notFound, 404, 1),          // wx-http.c:663-664
            ("302, late-wake window", split("HTTP/1.1 302 Found\r\nLocation: /y\r\n\(length)\r\n"), .past, false, .http, 302, 1),  // wx-http.c:665
            ("503, late-wake window", split("HTTP/1.1 503 X\r\n\(length)\r\n"), .past, false, .http, 503, Self.retried),           // wx-http.c:771-779
            ("200 Content-Length 5x, late-wake window", [Data(fiveX.prefix(60)), Data(fiveX.dropFirst(60))],
             .past, false, .parse, 200, 1),                                                                                    // wx-http.c:1304, :1519-1521
            ("2xx control, body done before the deadline", split("HTTP/1.1 200 OK\r\n\(length)\r\n"), .untouched, false, nil, 200, 1),
            ("2xx control, body done in the late-wake window", split("HTTP/1.1 200 OK\r\n\(length)\r\n"), .past, false, .timeout, 0, Self.retried),  // wx-http.c:704
            ("Content-Type control: head and body at once", [Data(ct429.utf8)], .past, false, .rateLimited, 429, 1),
            ("head arriving after the deadline", [Data(ct429.utf8)], .past, true, .timeout, 0, Self.retried),
            ("401: libsoup reads the body first (soup-session.c:2702-2720, :2838-2864), late-wake window",
             split("HTTP/1.1 401 X\r\n\(length)\r\n"), .past, false, .timeout, 0, Self.retried),
            // C: the 401 body ends after the deadline, TIMEOUT after 1 + WX_HTTP_MAX_RETRIES (soup-session.c:2838-2864;
            // wx-http.c:704). A coded 401 is decided from its head (N14), and verdictTime keeps that verdict's
            // delivery time for the body-first statuses, so it is not re-dated by its first byte.
            ("401 with a Content-Encoding handed over in the late-wake window",
             [Data(coded401Head.utf8) + Data(Self.gzipJSON.prefix(4)), Data(Self.gzipJSON.dropFirst(4))],
             .past, false, .timeout, 0, Self.retried),
            // Body-byte verdicts keep the time they were reached (Transfer.verdictTime's decidedOnHead
            // guard). C: on_deadline cancels the attempt before these bytes arrive (wx-http.c:807-813),
            // TIMEOUT "request timed out" (:704), retried (:771-779): TIMEOUT after 1 + WX_HTTP_MAX_RETRIES.
            ("gzip decoder ('identity, gzip') refusing bytes that arrive after the deadline",
             [Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: identity, gzip\r\nConnection: close\r\n\r\n".utf8)
                + Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF]),
              Data([0x07]) + Data(count: 2 * HTTPClient.GzipMemberDecoder.sliceSize)],  // a block of type 3, a full slice
             .past, false, .timeout, 0, Self.retried),
            ("the 4 MiB cap crossed by bytes that arrive after the deadline",
             [Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{".utf8),
              Data(repeating: 0x61, count: HTTPPolicy.maxBodyBytes)],
             .past, false, .timeout, 0, Self.retried),
            // The head rules C applies before the status (DECISIONS #76): in time, the head's own verdict
            // (C: server-sent Identity PARSE x1, wx-http.c:1240, :1288-1290, :1519-1520, test-http.c:3373;
            // a head above 100 KiB NETWORK x3, wx-http.h:199, http1/soup-message-io-data.c:102-107; a
            // status line libsoup cannot parse NETWORK x3, soup-headers.c:298-343, wx-http.c:691-708);
            // a head that comes after the deadline: TIMEOUT x 3 (on_deadline wx-http.c:807-813, :704,
            // retried :771-779).
            ("server-sent Identity, in time", [Data(identityCT.utf8)], .past, false, .parse, 200, 1),
            ("server-sent Identity, after the deadline", [Data(identityCT.utf8)], .past, true, .timeout, 0, Self.retried),
            ("server-sent Identity without Content-Type, in time", [Data(identityNoCT.utf8)], .past, false, .parse, 200, 1),
            ("server-sent Identity without Content-Type, after the deadline", [Data(identityNoCT.utf8)], .past, true, .timeout, 0, Self.retried),
            ("a 110 KiB head, in time", [Data(bigHead.utf8)], .past, false, .network, 0, Self.retried),
            ("a 110 KiB head, after the deadline", [Data(bigHead.utf8)], .past, true, .timeout, 0, Self.retried),
            ("a status line nobody parses, in time", [Data(garbled.utf8)], .past, false, .network, 0, Self.retried),
            ("a status line nobody parses, after the deadline", [Data(garbled.utf8)], .past, true, .timeout, 0, Self.retried),
        ]
        for (label, pieces, clockMove, headLate, code, status, requests) in rows {
            let budgetUs = headLate ? lateUs : inTimeUs
            let moveTo: Int64? = switch clockMove {
            case .untouched: nil
            case .atDeadline: budgetUs
            case .past, .pastAndExpired: budgetUs + 1_000_000
            }
            let expire = clockMove == .pastAndExpired
            let (outcome, wire) = try await Self.gatedAttempt(pieces, close: true, budgetUs: budgetUs, headLate: headLate,
                                                              moveTo: moveTo, expire: expire, settleMs: expire ? 1000 : 100)
            Self.expectAttempt(outcome, code: code, status: status, requests: requests, label)
            #expect(wire == 1, "\(label): requests on the wire")
        }
        // A 110 KiB head on a connection the server keeps open, judged at the deadline's wake-up from
        // the task metrics: in time NETWORK x3 (the 100 KiB limit, wx-http.h:199); after the deadline
        // TIMEOUT x 3 (on_deadline wx-http.c:807-813, :704, retried :771-779; DECISIONS #76).
        let keptOpenBig = [Data((Self.paddedHead(lineBytes: 110 * 1024, contentLength: 50) + "{\"a\"").utf8)]
        let (bigInTime, _) = try await Self.gatedAttempt(keptOpenBig, close: false, budgetUs: inTimeUs, headLate: false,
                                                         moveTo: inTimeUs + 1_000_000, expire: true, settleMs: 1000)
        Self.expectAttempt(bigInTime, code: .network, status: 0, requests: Self.retried, "a 110 KiB head kept open, in time")
        let (bigLate, _) = try await Self.gatedAttempt(keptOpenBig, close: false, budgetUs: lateUs, headLate: true,
                                                       moveTo: lateUs + 1_000_000, expire: true, settleMs: 1000)
        Self.expectAttempt(bigLate, code: .timeout, status: 0, requests: Self.retried, "a 110 KiB head kept open, after the deadline")
        // NEW U13-N13 platform rows (the head rules, DECISIONS #76, #78): a head whose first byte
        // came in time and whose end came after the deadline is judged by the head rules as if
        // complete, where C times out. No public-API fix found among the transaction dates
        // (fetchStart through responseEnd), the byte counts, task.response and
        // countOfBytesReceived (probe-p7/p1.log, p3.log) for the time the head was complete.
        // C: on_deadline fires before the head is complete (wx-http.c:807-813), TIMEOUT (:704),
        // retried: TIMEOUT after 1 + WX_HTTP_MAX_RETRIES requests.
        for (head, code, status, requests, name) in [(bigHead, WxError.Code.network, 0, Self.retried, "a 110 KiB head"),
                                                     (identityCT, .parse, 200, 1, "a server-sent Identity head")] {
            let all = Data(head.utf8)
            let (split, _) = try await Self.gatedAttempt([Data(all.prefix(1)), Data(all.dropFirst(1))], close: true,
                                                         budgetUs: n13Us, headLate: false, moveTo: n13Us + 1_000_000,
                                                         expire: false, restAfterMs: 2400)
            Self.expectAttempt(split, code: code, status: status, requests: requests,
                               "NEW U13-N13 platform row (wx-http.c:807-813, :704; C: TIMEOUT x 3): \(name) straddling the deadline")
        }
        // NEW U13-N13 platform row: the head itself straddles the deadline (its first byte before the
        // clock passes the deadline, the rest after it, and more than the deadline later in real time,
        // so dating by the response's end would be late). No public-API fix found among the
        // transaction dates (fetchStart through responseEnd), the byte counts, task.response and
        // countOfBytesReceived (probe-p7/p1.log, p3.log): it is dated by its first byte like a
        // withheld one and judged as if complete (here by its status), where C times out. The other way round (C judges the
        // head, the client times out) happens only when no body byte follows the head (NEW U13-N16).
        // C: on_deadline fires before the head is complete (wx-http.c:807-813), TIMEOUT
        // "request timed out" (:704), retried: TIMEOUT after 1 + WX_HTTP_MAX_RETRIES requests.
        let straddle = Data("HTTP/1.1 429 X\r\n\(length)\r\n\(body)".utf8)
        let (outcome, wire) = try await Self.gatedAttempt([Data(straddle.prefix(1)), Data(straddle.dropFirst(1))], close: true,
                                                          budgetUs: n13Us, headLate: false, moveTo: n13Us + 1_000_000,
                                                          expire: false, restAfterMs: 2400)
        Self.expectAttempt(outcome, code: .rateLimited, status: 429, requests: 1,
                           "NEW U13-N13 platform row (wx-http.c:807-813, :704; C: TIMEOUT x 3): head straddling the deadline")
        #expect(wire == 1)
        // NEW U13-N13 platform rows (the extension of DECISIONS #57, V1-P7-D3): an interim 100 Continue
        // head before the deadline, the final head after it. responseStartDate is the first byte of the
        // 1xx head, so the final head is dated as on time and judged by whatever verdict it carries (a
        // 429 RATE_LIMITED x1, a bodiless 204 a success). No public-API fix found among
        // responseStartDate, responseEndDate and didReceiveInformationalResponse (the 1xx head's
        // delivery time does not bound when the final head arrived); the final didReceive(response:)
        // time was not tried (only an upper bound, DECISIONS #57).
        // C: the final head arrives after on_deadline (wx-http.c:807-813), TIMEOUT (:704), retried: TIMEOUT x 3.
        let interim = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        for (finalHead, code, status, name) in [("HTTP/1.1 429 X\r\nContent-Type: application/json\r\n\(length)\r\n\(body)", WxError.Code?.some(.rateLimited), 429, "429"),
                                            ("HTTP/1.1 204 No Content\r\n\r\n", nil, 204, "204")] {
            let (after1xx, wire1xx) = try await Self.gatedAttempt([interim, Data(finalHead.utf8)], close: true, budgetUs: n13Us,
                                                                  headLate: false, moveTo: n13Us + 1_000_000, expire: false,
                                                                  restAfterMs: 2400)
            Self.expectAttempt(after1xx, code: code, status: status, requests: 1,
                               "NEW U13-N13 platform row (wx-http.c:807-813, :704; C: TIMEOUT x 3): final \(name) head after an early 1xx head")
            #expect(wire1xx == 1)
        }
    }

    // C: /http/net/connection-not-reused (test-http.c:3522-3609) with on_sent (wx-http.c:1485-1540) and
    // on_deadline (:807-813): the mirror of lateDeliveredHeadsAreDatedByTheirArrival (DECISIONS #53,
    // V1-P7-D1). Four heads with 4 of 50 body bytes, each in time (sent at once; the attempt deadline
    // 10 s on a ManualClock, which the head's real first-byte offset must stay below) and after the
    // deadline (the clock is moved past a 150 ms deadline first, the head is sent 300 ms after the
    // request), with the connection kept open or closed after the 4 bytes; the deadline's wake-up is
    // played 1 s after the server's send of the head completed (Transfer.expire), the time CFNetwork
    // has to read a withheld head into the task metrics (DECISIONS #76).
    // Kept open, CFNetwork withholds every one of these heads, and the client judges it from the
    // task metrics at the wake-up (the withheld path). Closed after the 4 bytes, CFNetwork hands the
    // 429, 404 and text/plain 503 heads over at the close (the late-delivered path of V1-D1, also
    // dated by the first byte; mutants J and A stay green on them) and fails the Content-Length-above-
    // the-cap one, whose head is then judged from the metrics (the withheld path). When the first
    // byte came after the deadline, C has already timed out; when it came in time, C's verdict
    // holds. Each row drives one production Transfer (gatedAttempt).
    @Test func withheldHeadsAfterTheDeadlineTimeOut() async throws {
        let inTimeUs: Int64 = 10_000_000
        let lateUs: Int64 = 150_000
        let pad = #"{"a""#                                                             // 4 body bytes of 50
        // (label, answer head, C's in-time outcome: code and HTTP status, C's in-time request count)
        let heads: [(String, String, WxError.Code, Int, Int)] = [
            ("429", "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 50\r\n\r\n", .rateLimited, 429, 1),   // wx-http.c:661-662
            ("404", "HTTP/1.1 404 Not Found\r\nContent-Length: 50\r\n\r\n", .notFound, 404, 1),             // wx-http.c:663-664
            ("text/plain 503", "HTTP/1.1 503 X\r\nContent-Type: text/plain\r\nContent-Length: 50\r\n\r\n", .http, 503, Self.retried),  // :771-779
            ("Content-Length above the cap", "HTTP/1.1 200 OK\r\nContent-Length: 4194305\r\n\r\n", .parse, 200, 1),  // wx-http.c:1312
        ]
        for (label, head, code, status, requests) in heads {
            for close in [false, true] {
                let answer = [Data((head + pad).utf8)]
                let path = close && label != "Content-Length above the cap" ? "handed over at the close" : "withheld"
                // In time: the head comes at once. C: the head's verdict at once.
                let (inTime, wireIn) = try await Self.gatedAttempt(answer, close: close, budgetUs: inTimeUs, headLate: false,
                                                                   moveTo: inTimeUs + 1_000_000, expire: true, settleMs: 1000)
                Self.expectAttempt(inTime, code: code, status: status, requests: requests, "\(label), in time, \(path)")
                #expect(wireIn == 1)
                // After the deadline: C: on_deadline fires first (wx-http.c:807-813), TIMEOUT (:704), retried
                // (:771-779): TIMEOUT after 1 + WX_HTTP_MAX_RETRIES requests.
                let (late, wireLate) = try await Self.gatedAttempt(answer, close: close, budgetUs: lateUs, headLate: true,
                                                                   moveTo: lateUs + 850_000, expire: true, settleMs: 1000)
                Self.expectAttempt(late, code: .timeout, status: 0, requests: Self.retried, "\(label), after the deadline, \(path)")
                #expect(wireLate == 1)
            }
        }
        // A coded 401 withheld in time: C reads its body first, which never ends (soup-session.c:2838-2864):
        // TIMEOUT after 1 + WX_HTTP_MAX_RETRIES requests (wx-http.c:704).
        let coded401 = Data("HTTP/1.1 401 X\r\nContent-Encoding: gzip\r\nContent-Length: \(Self.gzipJSON.count)\r\n\r\n".utf8)
            + Data(Self.gzipJSON.prefix(4))                                         // a valid start: CFNetwork waits for more
        let (outcome401, _) = try await Self.gatedAttempt([coded401], close: false, budgetUs: inTimeUs, headLate: false,
                                                          moveTo: inTimeUs + 1_000_000, expire: true, settleMs: 1000)
        Self.expectAttempt(outcome401, code: .timeout, status: 0, requests: Self.retried, "coded 401, in time, body stalled")
    }

    /// One attempt (one production HTTPClient.Transfer, `budgetUs` deadline after the clock's 0) of a
    /// client on a ManualClock against a GatedServer that sends `pieces` in order, each only when this
    /// function says so, then closes (`close`) or keeps the connection open: once the request is in,
    /// the clock is moved to `moveTo` and the head is sent `budgetUs` + 150 ms later in real time
    /// (`headLate`), or the head is sent, given `settleMs` to reach the client and the clock moved
    /// then; the deadline's wake-up is played (`expire`); only then, `restAfterMs` later, are the
    /// further pieces sent. Each step waits for the server's send it needs (DECISIONS #66); what
    /// remains real-time: the head's first byte must reach CFNetwork within `budgetUs` of the task's
    /// start for an in-time row (verdictTime compares that real offset with the clock deadline), and
    /// a withheld head must be in the task metrics `settleMs` after the server's send when the row
    /// plays the wake-up (DECISIONS #76). Returns the outcome and the wire request count.
    static func gatedAttempt(_ pieces: [Data], close: Bool, budgetUs: Int64, headLate: Bool, moveTo: Int64?, expire: Bool,
                             restAfterMs: Int = 0, settleMs: Int = 100) async throws -> (HTTPClient.AttemptOutcome, Int)
    {
        let server = try GatedServer(pieces, autoFirst: false, close: close)
        defer { server.stop() }
        let clock = ManualClock()
        let policy = try HTTPClientPolicy(baseURL: "http://127.0.0.1:\(server.port)", userAgent: ua,
                                          timeoutMs: Int(budgetUs / 1000), backoffBaseMs: 5, minGapMs: 0)
        let http = try HTTPClient(policy: policy, clock: clock, totalDeadlineMs: HTTPPolicy.totalDeadlineMs)
        let request = try http.makeRequest(try http.policy.plan(pathAndQuery: "/x", accept: jsonAccept, ifModifiedSince: nil))
        let session = URLSession(configuration: HTTPClient.makeConfiguration(), delegate: HTTPClient.SessionDelegate(),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let transfer = HTTPClient.Transfer(sentIfModifiedSince: false, clock: clock, deadline: budgetUs, totalFirst: false)
        transfer.begin(session: session, request: request)
        #expect(await server.waitForRequests(1), "the request reached the server")
        if headLate {
            if let moveTo { await clock.advance(by: moveTo) }
            try await Task.sleep(for: .milliseconds(Int(budgetUs / 1000) + 150))  // past the deadline in real time too
        }
        server.send(0)
        #expect(await server.waitForSent(1), "the head was sent")
        try await Task.sleep(for: .milliseconds(settleMs))
        if !headLate, let moveTo { await clock.advance(by: moveTo) }
        if expire { transfer.expire() }
        if pieces.count > 1 {
            if restAfterMs > 0 { try await Task.sleep(for: .milliseconds(restAfterMs)) }
            for index in 1..<pieces.count { server.send(index) }
        }
        // A row that never ends fails at a late wake-up instead of holding the suite.
        let guardTask = Task { try await Task.sleep(for: .seconds(15)); transfer.expire() }
        let outcome = await transfer.outcome()
        guardTask.cancel()
        return (outcome, transfer.requestCount)
    }

    /// expectCase for an answer the server sends at once and then holds open (C: STEP_BYTES_HANG),
    /// on a ManualClock (DECISIONS #66, #76). For each attempt, once the server's send of the answer
    /// has completed, the answer gets `settleMs` of real time to reach CFNetwork (the one real-time
    /// window left: by default 1 s when the outcome needs the head, 300 ms when it is TIMEOUT either
    /// way). With `atDeadline` the attempt must then still be open, and still 1 ms before its
    /// deadline (C decides these heads at once: the NEW U13-N2, N3 and N16 timing), so an answer
    /// decided at once, or a deadline that fires early, turns the row red. Each deadline is then
    /// played exactly, min(attempt time-out, whole-operation deadline) after the attempt's start on
    /// the clock, and each back-off exactly as long as the client's, so every attempt starts at the
    /// clock's now. The attempt time-out on that clock is long against real delivery, since a head
    /// dated by its real first-byte offset must be in time. A row that goes wrong ends within
    /// seconds: the clock is moved past the whole-operation deadline.
    static func expectHeld(_ answer: Data, ims: String? = nil, code: WxError.Code, requests: Int, timeoutMs: Int = 5000,
                           totalDeadlineMs: Int = HTTPPolicy.totalDeadlineMs, messageContains: String? = nil, message: String? = nil,
                           atDeadline: Bool = false, settleMs: Int? = nil, _ label: String,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws
    {
        let settle = settleMs ?? (code == .timeout ? 300 : 1000)
        let server = try GatedServer([answer], autoFirst: true, close: false)
        defer { server.stop() }
        let clock = ManualClock()
        let policy = try HTTPClientPolicy(baseURL: "http://127.0.0.1:\(server.port)", userAgent: ua, timeoutMs: timeoutMs,
                                          backoffBaseMs: 5, minGapMs: 0)
        let http = try HTTPClient(policy: policy, clock: clock, totalDeadlineMs: totalDeadlineMs)
        let finished = LoopbackServer.Shared(false)
        let task = Task { () -> Outcome in
            let outcome = await fetch(http, ims: ims)
            finished.value = true
            return outcome
        }
        let timeoutUs = Int64(timeoutMs) * 1000
        let totalUs = Int64(totalDeadlineMs) * 1000
        var startUs: Int64 = 0                                                      // this attempt's start on the clock
        for attempt in 1...requests {
            let ready = await waitUntil(timeout: .seconds(5)) { server.sentCount >= attempt || finished.value }
            #expect(ready, "\(label): answer \(attempt) sent", sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(settle))
            let open = !finished.value && http.finishedAttemptCount == attempt - 1
            if atDeadline {
                #expect(open, "\(label): attempt \(attempt) ended before its deadline", sourceLocation: sourceLocation)
            }
            if !ready || !open { break }
            let deadline = min(startUs + timeoutUs, totalUs)
            if atDeadline {
                await clock.advance(by: deadline - 1000 - clock.monotonicMicroseconds)
                try await Task.sleep(for: .milliseconds(100))
                let stillOpen = !finished.value && http.finishedAttemptCount == attempt - 1
                #expect(stillOpen, "\(label): attempt \(attempt) ended 1 ms before its deadline", sourceLocation: sourceLocation)
                if !stillOpen { break }
            }
            await clock.advance(by: deadline - clock.monotonicMicroseconds)
            if attempt < requests {
                // The attempt ends and its back-off starts on the clock: play exactly that back-off.
                let backingOff = await waitUntil(timeout: .seconds(5)) {
                    (http.finishedAttemptCount >= attempt && clock.pendingSleeperCount >= 1) || finished.value
                }
                #expect(backingOff, "\(label): back-off after attempt \(attempt)", sourceLocation: sourceLocation)
                if !backingOff || finished.value { break }
                await clock.advance(by: Int64(policy.backoffDelayMs(attempt: attempt - 1)) * 1000)
                startUs = clock.monotonicMicroseconds
            }
        }
        let done = await waitUntil(timeout: .seconds(2)) { finished.value }
        if !done { await clock.advance(by: totalUs + timeoutUs) }                      // a row that went wrong ends now
        guard let outcome = await outcome(of: task, within: .seconds(5), sourceLocation: sourceLocation) else { return }
        guard let error = wxError(outcome) else {
            Issue.record("\(label): expected \(code), got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        #expect(error.code == code, "\(label): \(error.message)", sourceLocation: sourceLocation)
        #expect(!error.message.contains("SENTINEL"), "\(label)", sourceLocation: sourceLocation)
        if let messageContains {
            #expect(error.message.contains(messageContains), "\(label): \(error.message)", sourceLocation: sourceLocation)
        }
        if let message { #expect(error.message == message, "\(label): \(error.message)", sourceLocation: sourceLocation) }
        #expect(server.requestCount == requests, "\(label): requests", sourceLocation: sourceLocation)
    }

    /// A loopback HTTP/1.1 server for the rows whose outcome depends on when bytes reach the client
    /// (DECISIONS #66): it reads each request's head and reports when each piece's send has
    /// completed, and sends only what it is told, so a test acts once the bytes are on their way
    /// (what the client then needs to read them is the callers' settle). `pieces[0]` goes out at once for every request (`autoFirst`) or on send(0),
    /// each later piece on send(i), on the latest connection; after the last piece the connection is
    /// closed (`close`) or kept open until stop().
    private final class GatedServer: Sendable {
        /// The server's state and logic, confined to `queue` for the network calls and to `state`.
        private final class Core: Sendable {
            struct State {
                var connections: [NWConnection] = []
                var latest: NWConnection?
                var requests = 0
                var sent = 0
            }
            let queue = DispatchQueue(label: "HTTPClientTests.GatedServer")
            let state = Mutex(State())
            let pieces: [Data]
            let close: Bool
            let autoFirst: Bool

            init(_ pieces: [Data], close: Bool, autoFirst: Bool) {
                self.pieces = pieces
                self.close = close
                self.autoFirst = autoFirst
            }

            func accept(_ connection: NWConnection) {
                state.withLock { $0.connections.append(connection) }
                connection.start(queue: queue)
                readHead(connection, Data())
            }

            func readHead(_ connection: NWConnection, _ pending: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    let buffer = pending + (data ?? Data())
                    guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                        if done || error != nil { connection.cancel() } else { self.readHead(connection, buffer) }
                        return
                    }
                    self.state.withLock {
                        $0.requests += 1
                        $0.latest = connection
                    }
                    if self.autoFirst { self.transmit(connection, 0) }
                }
            }

            func transmit(_ connection: NWConnection, _ index: Int) {
                connection.send(content: pieces[index], completion: .contentProcessed { _ in
                    self.state.withLock { $0.sent += 1 }
                    if self.close && index == self.pieces.count - 1 { connection.cancel() }
                })
            }
        }

        private let core: Core
        private let listener: NWListener
        let port: UInt16

        init(_ pieces: [Data], autoFirst: Bool, close: Bool) throws {
            let core = Core(pieces, close: close, autoFirst: autoFirst)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { connection in core.accept(connection) }
            listener.start(queue: core.queue)
            _ = ready.wait(timeout: .now() + 5)
            self.core = core
            self.listener = listener
            port = try #require(listener.port?.rawValue)
        }

        var requestCount: Int { core.state.withLock { $0.requests } }
        var sentCount: Int { core.state.withLock { $0.sent } }

        func waitForRequests(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
            await HTTPClientTests.waitUntil(timeout: timeout) { self.requestCount >= count }
        }

        func waitForSent(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
            await HTTPClientTests.waitUntil(timeout: timeout) { self.sentCount >= count }
        }

        /// Sends piece `index` on the latest connection.
        func send(_ index: Int) {
            let core = self.core
            core.queue.async {
                guard let connection = core.state.withLock({ $0.latest }) else { return }
                core.transmit(connection, index)
            }
        }

        func stop() {
            listener.cancel()
            core.state.withLock { $0.connections.forEach { $0.cancel() } }
        }
    }

    /// Checks one attempt's outcome against C's: the error code (nil: success) and HTTP status,
    /// and C's request count through the client's retry rule after a first attempt.
    static func expectAttempt(_ outcome: HTTPClient.AttemptOutcome, code: WxError.Code?, status: Int, requests: Int,
                              _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        switch outcome {
        case .success(let response):
            #expect(code == nil && response.status == status, "\(label): \(response.status)", sourceLocation: sourceLocation)
        case .failure(let error, let got, let totalExpired):
            #expect(error.code == code && got == status, "\(label): \(error.code) \(got) '\(error.message)'", sourceLocation: sourceLocation)
            let retried = HTTPPolicy.shouldRetry(error.code, httpStatus: got, attempt: 0, totalDeadlineExpired: totalExpired)
            #expect((retried ? Self.retried : 1) == requests, "\(label): request count", sourceLocation: sourceLocation)
        case .cancelled:
            Issue.record("\(label): cancelled", sourceLocation: sourceLocation)
        }
    }

    // C: none (executor addition for the OUTCOME TESTS criterion; Phase-7 contract sweep). C
    // contract: on_sent (wx-http.c:1485-1540) judges a head as soon as it arrives (status
    // :1504-1508, framing :1519-1521), whatever the body does later. NEW U13-N16 platform rows:
    // CFNetwork hands a head over only with its first body byte or the end of its body, and when
    // the server sends a head and then nothing (Content-Length above 0, a chunked head without a
    // chunk, a close-delimited head) on a connection it keeps open, the head is neither handed
    // over nor in the task metrics when the attempt deadline cancels the transfer
    // (transactionMetrics.last.response and task.response are nil; only the head byte count is
    // there: U13 probe probe-p7/p1b.log), so the client has nothing to judge: TIMEOUT after
    // 1 + WX_HTTP_MAX_RETRIES requests, each at the attempt deadline. No public-API fix found
    // among transactionMetrics.last.response, task.response, the delegate callbacks and the
    // byte counts. In production that means: a 429 head followed by no body byte on a
    // kept-open connection ends in TIMEOUT after 3 requests (about 33-35 s with the 10 s attempt
    // deadline waking late, probe-p7/p2-10s.log), with no 60 s cool-down and no NWS 5 s pause;
    // and a 205 without a body byte or a 204 with Transfer-Encoding: chunked fails where C
    // succeeds at once (status_is_bodiless, wx-http.c:1504-1513; CFNetwork waits for a body
    // libsoup never reads, http1/soup-client-message-io-http1.c:470-478; probe-p7/p5-bodiless.log).
    // C (each row): on_sent judges the head at once, the outcome named in the row's label.
    @Test func headWithoutAnyBodyByte() async throws {
        let json = "Content-Type: application/json\r\n"
        let rows: [(String, String)] = [
            ("HTTP/1.1 429 Too Many Requests\r\n\(json)Content-Length: 50\r\n\r\n", "RATE_LIMITED x 1 (wx-http.c:661-662)"),
            ("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 50\r\n\r\n", "RATE_LIMITED x 1 (wx-http.c:661-662)"),
            ("HTTP/1.1 429 X\r\n\(json)Transfer-Encoding: chunked\r\n\r\n", "RATE_LIMITED x 1 (wx-http.c:661-662)"),
            ("HTTP/1.1 429 X\r\n\(json)\r\n", "RATE_LIMITED x 1 (wx-http.c:661-662)"),
            ("HTTP/1.1 404 Not Found\r\n\(json)Content-Length: 50\r\n\r\n", "NOT_FOUND x 1 (wx-http.c:663-664)"),
            ("HTTP/1.1 503 X\r\n\(json)Content-Length: 50\r\n\r\n", "HTTP x 3 (wx-http.c:665, :771-779)"),
            ("HTTP/1.1 200 OK\r\n\(json)Content-Length: 4194305\r\n\r\n", "PARSE x 1 (wx-http.c:1312, :1519-1521)"),
            ("HTTP/1.1 205 X\r\n\r\n", "success x 1 (wx-http.c:1504-1513)"),
            ("HTTP/1.1 204 X\r\nTransfer-Encoding: chunked\r\n\r\n", "success x 1 (wx-http.c:1504-1513)"),
        ]
        // On a ManualClock (expectHeld): each deadline is played 300 ms after the server's send of the
        // head completed, and no attempt may end before its deadline (DECISIONS #66, #76).
        for (head, c) in rows {
            try await Self.expectHeld(Data(head.utf8), code: .timeout, requests: Self.retried, atDeadline: true,
                                      "NEW U13-N16 platform row (wx-http.c:1504-1508; C: \(c)): \(head.prefix(40).debugDescription)")
        }
        // Controls: with one body byte the head is handed over at once, and C's outcome holds; a
        // 204 and a 304 to If-Modified-Since are handed over at once (no body to wait for). Decided at
        // once, so a 2 s attempt time-out costs nothing and leaves loopback delivery room under load.
        try await Self.expectCase(.bytesHang(Data("HTTP/1.1 429 X\r\n\(json)Content-Length: 50\r\n\r\n{".utf8)),
                                  code: .rateLimited, requests: 1, timeoutMs: 2000, "one body byte with the head")   // wx-http.c:661-662
        try await Self.expectCase(.bytesHang(Data("HTTP/1.1 204 X\r\n\r\n".utf8)), code: nil, requests: 1, okBody: Data(),
                                  timeoutMs: 2000, "204, connection kept open")                                     // wx-http.c:1504-1513
        try await Self.expectCase(.bytesHang(Data("HTTP/1.1 304 X\r\n\r\n".utf8)), ims: Self.imsValue, code: nil, requests: 1,
                                  okBody: Data(), timeoutMs: 2000, "304 to If-Modified-Since, connection kept open")
    }

    // C: /http/net/status-mapping (test-http.c:2190-2228) on a connection the server keeps open
    // (DECISIONS #45 condition 3, the empty-429 tripwire for NEW U13-N16): a head whose body is
    // complete when it arrives (Content-Length: 0, or a small body) is handed over at once, so C's
    // outcome and request count hold. The KeepAliveServer (test-http.c KaServer) answers every
    // request on the connection it keeps open (probe-p7/p11-tripwire.log).
    @Test func completeHeadsOnAKeptOpenConnection() async throws {
        let rows: [(String, WxError.Code, Int, String)] = [
            // C: run_failure_case(429) -> WX_ERROR_RATE_LIMITED after 1 request (test-http.c:2194)
            ("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n", .rateLimited, 1, "429, Content-Length: 0"),
            // C: run_failure_case(429) -> WX_ERROR_RATE_LIMITED after 1 request (test-http.c:2194)
            ("HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"e\":\"slow\"}",
             .rateLimited, 1, "429, small JSON body"),
            // C: run_failure_case(503) -> WX_ERROR_HTTP after 1 + WX_HTTP_MAX_RETRIES requests (test-http.c:2209)
            ("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n", .http, Self.retried, "503, Content-Length: 0"),
        ]
        for (answer, code, requests, label) in rows {
            let server = try KeepAliveServer([Data(answer.utf8)])
            defer { server.stop() }
            let http = try HTTPClient(baseURL: "http://127.0.0.1:\(server.port)", userAgent: Self.ua, timeoutMs: 2000, backoffBaseMs: 5)
            let begin = ContinuousClock.now
            let error = Self.wxError(await Self.fetch(http))
            #expect(error?.code == code, "\(label): \(String(describing: error))")
            #expect(server.connectionOfRequest.count == requests, "\(label): \(server.connectionOfRequest)")
            #expect(ContinuousClock.now - begin < .milliseconds(1500), "\(label): not at once")
        }
    }

    // C: /http/net/unread-headers-ignored (test-http.c:3663-3707: its 401 and 407 rows) and the
    // 421 rule of the C contract (wx-http.h:196-198), with libsoup 3.6.6's session: its default
    // auth manager (soup-session.c:301-306) and its 421 handling make libsoup read the WHOLE body
    // of a 401, 407 or 421 into memory before soup_session_send_async completes
    // (expected_to_be_requeued :2702-2720, send_async_maybe_complete :2838-2864,
    // async_send_request_finished :2765-2803), so on_sent (wx-http.c:1485-1540) sees the status
    // only then. A complete body, or one cut on a connection that is not kept alive (read up to
    // the close: soup-client-message-io-http1.c:615-625), gives WX_ERROR_HTTP after 1 request (a
    // 421 after 1 or 2: test-http.c:3269-3270); a stalled body gives the attempt deadline's
    // TIMEOUT (wx-http.c:704) and one cut on a kept-alive connection gives NETWORK
    // ("Connection terminated unexpectedly", http1/soup-body-input-stream.c:150-157), both
    // retried (wx-http.c:771-779). The client waits for that body as well (State.bodyFirst; a
    // Content-Length cut is read from the metrics' wire count, since CFNetwork completes a short
    // 4xx body without an error). NEW U13-N14 platform rows: what it cannot wait for, so it fails
    // fast (HTTP after 1 request, from the head) where C reads the body. A 401/407 whose
    // authentication scheme CFNetwork handles raises a challenge; no public-API fix found among
    // the four dispositions (probe-p7/p10b.log, Basic and Digest): useCredential with a nil
    // credential (lines 1-4, 17-20), performDefaultHandling (5-8, 21-24) and rejectProtectionSpace
    // (9-12, 25-28) deliver the body only after a second request (C: one), and
    // cancelAuthenticationChallenge (13-16, 29-32) ends the transfer before the body; NTLM and
    // Negotiate stay cancelled (p10.log: 1 request, no credential header; their default handling
    // was not probed). A body with a Content-Encoding is decoded by CFNetwork, which can fail
    // where C reads the raw body. An HTTP/1.0 answer is not kept alive in libsoup, but CFNetwork
    // reports no version (no public-API fix found among networkProtocolName and allHeaderFields,
    // p4.log).
    @Test func bodyFirstStatusOutcomes() async throws {
        for status in [401, 407, 421] {
            let head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n"
            try await Self.expectCase(.rawText(head + "Content-Length: 2\r\n\r\n{}"), code: .http, requests: 1,
                                      "\(status) complete body")                                  // 421: test-http.c:3269-3270
            try await Self.expectCase(.rawText(head + "Content-Length: 50\r\nConnection: close\r\n\r\n{\"a\""), code: .http, requests: 1,
                                      "\(status) body cut, Connection: close")                    // soup-client-message-io-http1.c:615-625
            try await Self.expectCase(.rawText(head + "Connection: close\r\n\r\n"), code: .http, requests: 1,
                                      "\(status) empty close-delimited body")                     // soup-session.c:2765-2803
            try await Self.expectHeld(Data((head + "Content-Length: 50\r\n\r\n{\"a\"").utf8), code: .timeout,
                                      requests: Self.retried, atDeadline: true, "\(status) body stalled")  // wx-http.c:704
            try await Self.expectCase(.rawText(head + "Content-Length: 50\r\n\r\n{\"a\""), code: .network, requests: Self.retried,
                                      "\(status) body cut on a kept-alive connection")             // http1/soup-body-input-stream.c:150-157
            try await Self.expectHeld(Data((head + "Content-Encoding: identity\r\nContent-Length: 50\r\n\r\n{\"a\"").utf8),
                                      code: .timeout, requests: Self.retried, atDeadline: true, "\(status) identity coding, body stalled")
        }
        let n14 = "NEW U13-N14 platform row (soup-session.c:2838-2864"
        let json = "Content-Type: application/json\r\n"
        // C: the body never ends before on_deadline, TIMEOUT after 1 + WX_HTTP_MAX_RETRIES (soup-session.c:2838-2864; wx-http.c:704)
        try await Self.expectCase(.bytesHang(Data("HTTP/1.1 401 X\r\n\(json)WWW-Authenticate: Basic realm=\"x\"\r\nContent-Length: 50\r\n\r\n{\"a\"".utf8)),
                                  code: .http, requests: 1, timeoutMs: 2000, "\(n14), wx-http.c:704; C: TIMEOUT x 3): Basic challenge, body stalled")
        try await Self.expectCase(.bytesHang(Data("HTTP/1.1 401 X\r\n\(json)Content-Encoding: gzip\r\nContent-Length: 50\r\n\r\n{\"a\"".utf8)),
                                  code: .http, requests: 1, timeoutMs: 2000, "\(n14), wx-http.c:704; C: TIMEOUT x 3): gzip-coded body stalled")
        // C: not kept alive, the body read to the close, WX_ERROR_HTTP after 1 request (soup-message.c:2093-2103; :615-625)
        try await Self.expectCase(.rawText("HTTP/1.0 401 X\r\n\(json)Content-Length: 50\r\n\r\n{\"a\""), code: .network, requests: Self.retried,
                                  "\(n14), soup-message.c:2093-2103; C: HTTP x 1, HTTP/1.0 is not kept alive): HTTP/1.0 body cut")
        try await Self.expectCase(.rawText("HTTP/1.1 401 X\r\n\(json)Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\n{}\r\n"),
                                  code: .http, requests: 1,
                                  "DECISIONS #34 item 2 platform row (http1/soup-body-input-stream.c:178-193; C: NETWORK x 3): chunked body without its final chunk")
        // A chunked body cut inside a chunk: libsoup's chunked reader fails, "Connection terminated
        // unexpectedly" (http1/soup-body-input-stream.c:150-157, :178-193), NETWORK, retried.
        // C: NETWORK after 1 + WX_HTTP_MAX_RETRIES requests (each row).
        let midChunk = "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n32\r\n{\"a\""
        for status in [407, 421] {
            try await Self.expectCase(.rawText("HTTP/1.1 \(status) X\r\n\(json)\(midChunk)"), code: .network, requests: Self.retried,
                                      "\(status) chunked body cut inside a chunk")
        }
        // NEW U13-N17 platform row (DECISIONS #57, V1-P7-D4): for a 401 CFNetwork completes such a body
        // without an error, so the client reports the status. No public-API fix found among the transport
        // error, countOfResponseBodyBytesReceived and countOfResponseBodyBytesAfterDecoding (the chunk
        // framing in the wire count would catch a cut in the first chunk only, and a CFNetwork that stopped
        // counting the framing would turn every chunked 401 into NETWORK).
        try await Self.expectCase(.rawText("HTTP/1.1 401 X\r\n\(json)\(midChunk)"), code: .http, requests: 1,
                                  "NEW U13-N17 platform row (http1/soup-body-input-stream.c:150-157; C: NETWORK x 3): 401 chunked body cut inside a chunk")
    }

    // C: none (executor addition for the OUTCOME TESTS criterion; the Phase-7 sweep of libsoup's
    // header table, DECISIONS #38 V1-D2 and V1-D3). C contract wx-http.h:199 (a head libsoup
    // cannot parse: N), :205-209 (Expires and Last-Modified: the last line), :214-218 (header
    // syntax is libsoup's). libsoup 3.6.6:
    //  - soup_headers_parse appends every line with soup_message_headers_append_untrusted_data
    //    (soup-headers.c:142-143), which refuses a second Host line (soup-message-headers.c:
    //    267-270): "Could not parse HTTP response" (http1/soup-client-message-io-http1.c:
    //    456-465), N, retried. A 1xx head is parsed the same way, and the headers are cleared
    //    between heads (:602).
    //  - soup_headers_parse_response removes, for an HTTP/1.0 response, every header that
    //    Connection names (soup-headers.c:399-400; soup-message-headers.c:232-248) before
    //    wx-http reads Content-Length, Transfer-Encoding, Content-Encoding, Expires or
    //    Last-Modified; a quoted token names no header.
    //  - obs-fold: the blanks and tabs that end a line and start its continuation collapse to
    //    ONE space (soup-headers.c:115-129).
    // NEW U13-N11 platform rows: CFNetwork joins the Host lines ("a, b", exactly what one line
    // "Host: a, b" gives, which C accepts) and parses the head; no public-API fix found among
    // value(forHTTPHeaderField:), allHeaderFields and countOfResponseHeaderBytesReceived. NEW U13-N12 platform rows: CFNetwork keeps the headers Connection names, frames
    // the body by them, and reports networkProtocolName "http/1.1" for an HTTP/1.0 head, so the
    // client cannot apply the rule to HTTP/1.0 only (applying it to HTTP/1.1 too would change
    // answers C accepts). NEW U13-N5 platform rows (DECISIONS #36 N5, here for fold whitespace):
    // CFNetwork keeps fold whitespace verbatim, so Last-Modified differs (a tab is not printable
    // ASCII: no validator); Expires, Content-Length and Content-Encoding read as in C. (U13
    // probes probe-p7/p4.log, p5-host.log, p5-http10.log, p5-fold.log.)
    @Test func headerTableOutcomes() async throws {
        let json = "Content-Type: application/json\r\n"
        let tail = "Content-Length: 2\r\nConnection: close\r\n\r\n{}"
        // Duplicate Host lines.
        // C (N11 rows): the second Host line refuses the head, "Could not parse HTTP response", NETWORK
        // after 1 + WX_HTTP_MAX_RETRIES requests (soup-message-headers.c:267-270; soup-client-message-io-http1.c:456-465).
        // No public-API fix found among value(forHTTPHeaderField:), allHeaderFields and
        // countOfResponseHeaderBytesReceived (p4.log, p5-host.log).
        let n11 = "NEW U13-N11 platform row (soup-message-headers.c:267-270; C: NETWORK x 3)"
        try await Self.expectCase(.rawText("HTTP/1.1 200 OK\r\n\(json)Host: a\r\nHost: b\r\n\(tail)"), code: nil, requests: 1,
                                  okBody: Data("{}".utf8), "\(n11): 200")
        try await Self.expectCase(.rawText("HTTP/1.1 200 OK\r\n\(json)Host: a\r\nHOST: b\r\n\(tail)"), code: nil, requests: 1,
                                  okBody: Data("{}".utf8), "\(n11): 200, names in two cases")
        try await Self.expectCase(.rawText("HTTP/1.1 429 X\r\n\(json)Host: a\r\nHost: b\r\n\(tail)"), code: .rateLimited, requests: 1,
                                  "\(n11): 429")
        try await Self.expectCase(.rawText("HTTP/1.1 100 Continue\r\nHost: a\r\nHost: b\r\n\r\nHTTP/1.1 200 OK\r\n\(json)\(tail)"),
                                  code: nil, requests: 1, okBody: Data("{}".utf8), "\(n11): in a 100 head")
        for (label, lines) in [("one Host line 'a, b'", "Host: a, b\r\n"), ("Host plus an ignored 'Host :' line", "Host: a\r\nHost : b\r\n")] {
            try await Self.expectCase(.rawText("HTTP/1.1 200 OK\r\n\(json)\(lines)\(tail)"), code: nil, requests: 1,
                                      okBody: Data("{}".utf8), label)                    // soup-headers.c:77-91, :142-143
        }
        try await Self.expectCase(.rawText("HTTP/1.1 100 Continue\r\nHost: a\r\n\r\nHTTP/1.1 200 OK\r\n\(json)Host: b\r\n\(tail)"),
                                  code: nil, requests: 1, okBody: Data("{}".utf8), "Host in a 100 head and in the final head")
        // HTTP/1.0 and the headers Connection names.
        // C (N12 rows): the headers Connection names are removed from an HTTP/1.0 response before
        // wx-http reads them (soup-headers.c:399-400; soup-message-headers.c:232-248), the outcome in
        // each label. No public-API fix found among networkProtocolName ("http/1.1" for HTTP/1.0),
        // allHeaderFields and CFHTTPMessageCopyVersion (needs a CFHTTPMessageRef URLSession never
        // exposes) (p4.log, p5-http10.log).
        let n12 = "NEW U13-N12 platform row (soup-headers.c:399-400, soup-message-headers.c:232-248"
        try await Self.expectCase(.rawText("HTTP/1.0 200 OK\r\n\(json)Connection: Content-Length\r\nContent-Length: 2\r\n\r\n{}xyz"),
                                  code: nil, requests: 1, okBody: Data("{}".utf8), "\(n12); C: body \"{}xyz\"): Content-Length")
        try await Self.expectCase(.rawText("HTTP/1.0 200 OK\r\n\(json)Connection: Content-Encoding\r\nContent-Encoding: br\r\nContent-Length: 2\r\n\r\n{}"),
                                  code: .parse, requests: 1, "\(n12); C: body \"{}\"): Content-Encoding br")
        try await Self.expectCase(.rawText("HTTP/1.0 200 OK\r\n\(json)Connection: Content-Length\r\nContent-Length: 4194305\r\n\r\n{}"),
                                  code: .parse, requests: 1, "\(n12); C: body \"{}\"): Content-Length above the cap")
        try await Self.expectCase(.rawText("HTTP/1.0 200 OK\r\n\(json)Connection: Content-Length\r\nContent-Length: 5x\r\n\r\n{}"),
                                  code: .parse, requests: 1, "\(n12); C: body \"{}\"): Content-Length 5x")
        try await Self.expectCase(.rawText("HTTP/1.0 200 OK\r\n\(json)Connection: Transfer-Encoding\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"),
                                  code: nil, requests: 1, okBody: Data("{}".utf8), "\(n12); C: the raw chunk framing as body): Transfer-Encoding")
        let member = LoopbackServer.gzip(Data(#"{"a":1}"#.utf8))
        try await Self.expectCase(.raw(Data("HTTP/1.0 200 OK\r\n\(json)Connection: Content-Encoding\r\nContent-Encoding: gzip\r\nContent-Length: \(member.count)\r\n\r\n".utf8) + member),
                                  code: nil, requests: 1, okBody: Data(#"{"a":1}"#.utf8), "\(n12); C: the raw gzip member as body): Content-Encoding gzip")
        let now = SystemClock().wallSeconds
        let validators = try LoopbackServer([.rawText("HTTP/1.0 200 OK\r\n\(json)Connection: Last-Modified, Expires\r\nLast-Modified: \(Self.httpDate(now - 3600))\r\nExpires: \(Self.httpDate(now + 1800))\r\nContent-Length: 2\r\n\r\n{}")])
        defer { validators.stop() }
        let kept = try await Self.fetch(try Self.client(validators, timeoutMs: 2000, backoffMs: 5)).get()
        #expect(kept.lastModified == Self.httpDate(now - 3600) && kept.expiresS > 0,
                "\(n12); C: no Last-Modified, Expires 0): \(String(describing: kept.lastModified)) \(kept.expiresS)")
        try await Self.expectCase(.rawText("HTTP/1.1 200 OK\r\n\(json)Connection: Content-Length\r\nContent-Length: 2\r\n\r\n{}xyz"),
                                  code: nil, requests: 1, okBody: Data("{}".utf8), "HTTP/1.1: C keeps Connection-named headers")
        try await Self.expectCase(.rawText("HTTP/1.0 200 OK\r\n\(json)Connection: \"Content-Length\"\r\nContent-Length: 2\r\n\r\n{}xyz"),
                                  code: nil, requests: 1, okBody: Data("{}".utf8), "HTTP/1.0, a quoted token names no header")  // soup-headers.c:436-460
        try await Self.expectCase(.rawText("HTTP/1.0 429 X\r\n\(json)Connection: Content-Length\r\nContent-Length: 2\r\n\r\n{}"),
                                  code: .rateLimited, requests: 1, "HTTP/1.0 429: the status decides first")  // wx-http.c:1504-1508
        // obs-fold whitespace (Last-Modified "a b" in C for every row).
        // C (N5 rows): the fold collapses to one space, Last-Modified "a b" (soup-headers.c:115-129;
        // record_validators, wx-http.c:1405-1407).
        let n5 = "NEW U13-N5 platform row (soup-headers.c:115-129; C: Last-Modified \"a b\")"
        for (label, fold, expected) in [("tab", "a\r\n\tb", nil), ("four blanks", "a\r\n    b", "a    b"),
                                        ("trailing blanks before the fold", "a   \r\n b", "a    b"),
                                        ("trailing tab before the fold", "a\t\r\n b", nil)] as [(String, String, String?)] {
            let server = try LoopbackServer([.rawText("HTTP/1.1 200 OK\r\n\(json)Last-Modified: \(fold)\r\n\(tail)")])
            defer { server.stop() }
            let response = try await Self.fetch(try Self.client(server, timeoutMs: 2000, backoffMs: 5)).get()
            #expect(response.lastModified == expected, "\(n5): \(label): \(String(describing: response.lastModified))")
        }
        let expires = Self.httpDate(now + 1800)
        let cut = expires.index(expires.endIndex, offsetBy: -12)                         // before "HH:MM:SS GMT"
        for fold in ["\r\n ", "\r\n\t", "\r\n   ", "  \r\n\t "] {
            let line = String(expires[..<cut]).trimmingCharacters(in: .whitespaces) + fold + String(expires[cut...])
            let server = try LoopbackServer([.rawText("HTTP/1.1 200 OK\r\n\(json)Expires: \(line)\r\n\(tail)")])
            defer { server.stop() }
            let response = try await Self.fetch(try Self.client(server, timeoutMs: 2000, backoffMs: 5)).get()
            #expect(abs(response.expiresS - (now + 1800)) <= 2, "Expires folded with \(fold.debugDescription): \(response.expiresS)")  // wx-http.h:205-206
        }
        try await Self.expectCase(.rawText("HTTP/1.1 200 OK\r\n\(json)Content-Length: 1\r\n\t2\r\nConnection: close\r\n\r\n{}"),
                                  code: .parse, requests: 1, "Content-Length folded '1' + '2'")  // C: "1 2", wx-http.c:1304
        // A continuation line after a line libsoup ignores is ignored with it (soup-headers.c:77-91).
        for lines in ["nocolon\r\n Content-Length: 2\r\n", "X Bad: v\r\n Content-Length: 2\r\n", "nocolon\r\n\tContent-Length: 2\r\n"] {
            try await Self.expectCase(.rawText("HTTP/1.1 200 OK\r\n\(json)\(lines)Connection: close\r\n\r\n{}xyz"), code: nil, requests: 1,
                                      okBody: Data("{}xyz".utf8), lines.debugDescription)
        }
    }

    // C: /http/net/gzip-truncated (test-http.c:2566-2633: its "not gzip" row, :2606-2607, with
    // shorter bodies, and its "empty" row, :2608-2609). C inflates the body itself (inflate_chunk,
    // wx-http.c:907-944) and counts its ENCODED bytes (on_read :992): an empty body of unknown
    // length is NETWORK (:1012-1016), and fewer than 20 bytes never hold a gzip member (a 10-byte
    // header, at least 2 bytes of DEFLATE data, an 8-byte trailer), so the decoder refuses them or
    // has not ended when the body ends (:1025-1031): NETWORK after 1 + WX_HTTP_MAX_RETRIES
    // requests. A valid member of empty content (20 bytes) is a success with an empty body.
    // CFNetwork, which inflates when the list's first element is gzip, hands under 10 bytes over
    // as an EMPTY body (from 10 bytes on, non-gzip bytes fail with -1015); the client reads the
    // encoded size from the metrics' wire count, which is exact for Content-Length and
    // close-delimited framing on HTTP/1.1 (U13 probes probe-p7/p4b.log; p5-gz20.pre-rev2.log
    // before this rule, p5-gz20.rev2.log after it; on h2 it adds 9 bytes per DATA frame header,
    // V1-P7-D5, DECISIONS #57 under #30: not testable on loopback, h2 needs TLS with ALPN). NEW U13-N15 platform
    // rows: a chunked body's wire count includes the chunk framing, so there the decoded count
    // stands in and a member of empty content (C: success) or one followed by bytes (C: PARSE
    // after 1 request) is refused as an empty body.
    @Test func shortBodiesLabelledGzip() async throws {
        let json = "Content-Type: application/json\r\n"
        func answer(_ coding: String, _ framing: Framing, _ payload: Data) -> LoopbackServer.Step {
            let framingHeader = switch framing {
            case .contentLength: "Content-Length: \(payload.count)\r\n"
            case .chunked: "Transfer-Encoding: chunked\r\n"
            case .close: ""
            }
            let body = framing == .chunked
                ? Data("\(String(payload.count, radix: 16))\r\n".utf8) + payload + Data("\r\n0\r\n\r\n".utf8) : payload
            return .raw(Data("HTTP/1.1 200 OK\r\n\(json)Content-Encoding: \(coding)\r\n\(framingHeader)Connection: close\r\n\r\n".utf8) + body)
        }
        for framing in [Framing.contentLength, .close] {
            for (payload, coding) in [("{}", "gzip"), ("{}", "GZIP"), ("x", "gzip"), ("123456789", "gzip"), ("1234567890", "gzip"),
                                      ("plain text, not g", "x-gzip")] {
                try await Self.expectCase(answer(coding, framing, Data(payload.utf8)), code: .network, requests: Self.retried,
                                          "\(framing) \(coding) label on \(payload.debugDescription)")  // wx-http.c:1025-1031
            }
            let cut = Self.gzipJSON.prefix(19)
            try await Self.expectCase(answer("gzip", framing, Data(cut)), code: .network, requests: Self.retried,
                                      "\(framing) member cut at 19 bytes")                               // test-http.c:2588-2589
            try await Self.expectCase(answer("gzip", framing, LoopbackServer.gzip(Data())), code: nil, requests: 1, okBody: Data(),
                                      "\(framing) member of empty content")                              // a complete member
        }
        // C (N15 rows): the decoder reaches the end of the empty member: success with an empty body;
        // with bytes after it, PARSE "data after the end of the compressed body" after 1 request
        // (wx-http.c:992, :934-938). No public-API fix found among countOfResponseBodyBytesReceived
        // (includes the chunk framing: 29 or 123 bytes for the 20-byte member, p4b.log) and
        // countOfResponseBodyBytesAfterDecoding.
        let n15 = "NEW U13-N15 platform row (wx-http.c:992, :1025-1031, :934-938"
        try await Self.expectCase(answer("gzip", .chunked, LoopbackServer.gzip(Data())), code: .network, requests: Self.retried,
                                  "\(n15); C: success, empty body): chunked member of empty content")
        try await Self.expectCase(answer("gzip", .chunked, LoopbackServer.gzip(Data()) + Data("xyz".utf8)), code: .network,
                                  requests: Self.retried, "\(n15); C: PARSE x 1): chunked member of empty content + 'xyz'")
        try await Self.expectCase(answer("gzip", .chunked, Data("{}".utf8)), code: .network, requests: Self.retried,
                                  "chunked gzip label on \"{}\"")                                        // wx-http.c:1025-1031
    }

    /// test-http.c KaServer (:3442-3520): answers the script in request
    /// order (the last entry repeats), never closes a connection, and records which connection
    /// carried each request.
    private final class KeepAliveServer: Sendable {
        private struct Records {
            var connectionOfRequest: [Int] = []
            var connections: [NWConnection] = []
        }
        private final class Box: Sendable {
            let mutex = Mutex(Records())
            func withLock<R>(_ body: (inout Records) -> R) -> R { mutex.withLock { body(&$0) } }
        }
        private let listener: NWListener
        private let queue = DispatchQueue(label: "HTTPClientTests.KeepAliveServer")
        private let records = Box()
        private let script: [Data]
        let port: UInt16

        var connectionOfRequest: [Int] { records.withLock { $0.connectionOfRequest } }

        init(_ script: [Data]) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let records = self.records
            let queue = self.queue
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { connection in
                let id = records.withLock { r -> Int in
                    r.connections.append(connection)
                    return r.connections.count - 1
                }
                connection.start(queue: queue)
                Self.receive(connection, id, Data(), script, records)
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            self.listener = listener
            self.script = script
            port = try #require(listener.port?.rawValue)
        }

        private static func receive(_ connection: NWConnection, _ id: Int, _ pending: Data, _ script: [Data],
                                    _ records: Box) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                var buffer = pending + (data ?? Data())
                while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {  // one GET head, no body
                    buffer.removeSubrange(..<end.upperBound)
                    let index = records.withLock { r -> Int in
                        r.connectionOfRequest.append(id)
                        return r.connectionOfRequest.count - 1
                    }
                    connection.send(content: script[min(index, script.count - 1)], completion: .contentProcessed { _ in })
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                receive(connection, id, buffer, script, records)
            }
        }

        func stop() {
            listener.cancel()
            records.withLock { $0.connections.forEach { $0.cancel() } }
        }
    }

    // C: /http/net/connection-not-reused (test-http.c:3522-3609): a rejected response
    // (oversized, unsupported framing, invalid length, error status) leaves its body unread, so
    // the next request must not come on its connection; the server keeps every connection open.
    // (A) The C script (:3531-3542) with one change: each head also carries Content-Type, since
    // CFNetwork holds back a head without one until it has sniffed the body (see (B)). Outcomes
    // and requests are C's (:3570-3582); after every rejected response the next request comes
    // on another connection (:3592-3599), except one DECISIONS #34 item 7 platform row: the response whose
    // Transfer-Encoding lines are refused (:3533) was framed completely by CFNetwork itself
    // (it removed the chunked framing through the last chunk), and CFNetwork reuses that
    // connection for the next request. (B) The first C head verbatim (no Content-Type, a huge
    // Content-Length, the connection kept open): CFNetwork never hands it over, so the attempt
    // deadline ends the transfer and the client judges the head from the task metrics: C's
    // error after 1 request (:3574-3577; "response too large", wx-http.c:1310-1312), at the
    // deadline (NEW documented difference U13-N3, see withheldHeadsAreJudgedAtTheDeadline).
    @Test func connectionNotReusedAfterRejection() async throws {
        let body = #"{"ok":true}"#                                                    // test-http.c:3524
        let chunked = "\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n0\r\n\r\n"     // test-http.c:3525
        let script: [(String, String, Bool)] = [                                      // test-http.c:3531-3542
            ("200 OK\r\nContent-Length: 9223372036854775808\r\n", body, true),
            ("200 OK\r\nContent-Length: 11\r\n", body, false),
            ("200 OK\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n", chunked, true),
            ("200 OK\r\nContent-Length: 11\r\n", body, false),
            ("500 Internal Server Error\r\nContent-Length: -2\r\n", body, true),
            ("500 Internal Server Error\r\nContent-Length: -2\r\n", body, true),
            ("500 Internal Server Error\r\nContent-Length: -2\r\n", body, true),
            ("200 OK\r\nContent-Length: 11\r\n", body, false),
            ("200 OK\r\nContent-Length: 5x\r\n", body, true),
            ("200 OK\r\nContent-Length: 11\r\n", body, false),
            ("200 OK\r\nContent-Length: 7, 3\r\n", body, true),
            ("200 OK\r\nContent-Length: 11\r\n", body, false),
        ]
        let reusedRow = 2  // test-http.c:3533, the DECISIONS #34 item 7 platform row of (A)
        // (A)
        let server = try KeepAliveServer(script.map {
            Data("HTTP/1.1 \($0.0)Content-Type: application/json\r\n\r\n\($0.1)".utf8)
        })
        defer { server.stop() }
        let http = try HTTPClient(baseURL: "http://127.0.0.1:\(server.port)", userAgent: Self.ua, timeoutMs: 3000,
                                  backoffBaseMs: 5)                                   // test-http.c:3566
        var sent = 0
        while sent < script.count {
            let outcome = await Self.fetch(http)
            if script[sent].2 {
                let error = Self.wxError(outcome)
                #expect(error != nil, "row \(sent): \(outcome)")
                sent += error?.code == .http ? 1 + HTTPPolicy.maxRetries : 1          // test-http.c:3577
            } else {
                #expect(Self.body(outcome) == Data(body.utf8), "row \(sent): \(outcome)")
                sent += 1
            }
            #expect(server.connectionOfRequest.count == sent, "row \(sent): requests")
            if server.connectionOfRequest.count != sent { break }
        }
        let connections = server.connectionOfRequest
        #expect(connections.count == script.count)                                  // test-http.c:3592
        if connections.count == script.count {
            for i in 0..<(script.count - 1) where script[i].2 {
                if i == reusedRow {
                    #expect(connections[i + 1] == connections[i], "DECISIONS #34 item 7 platform row (test-http.c:3533, :3598) \(i): \(connections)")
                } else {
                    #expect(connections[i + 1] != connections[i], "row \(i): \(connections)")  // test-http.c:3598
                }
            }
        }
        // (B)
        let verbatim = try KeepAliveServer([Data("HTTP/1.1 \(script[0].0)\r\n\(body)".utf8)])
        defer { verbatim.stop() }
        // Judged at the attempt deadline from the task metrics: a 2 s time-out leaves loopback delivery
        // room under load (DECISIONS #66).
        let http2 = try HTTPClient(baseURL: "http://127.0.0.1:\(verbatim.port)", userAgent: Self.ua, timeoutMs: 2000,
                                   backoffBaseMs: 5)
        let outcome = await Self.fetch(http2)
        #expect(Self.wxError(outcome)?.code == .parse, "test-http.c:3531, :3574-3577: \(outcome)")
        #expect(Self.wxError(outcome)?.message == HTTPPolicy.Message.responseTooLarge, "wx-http.c:1310-1312: \(outcome)")
        #expect(verbatim.connectionOfRequest.count == 1, "test-http.c:3577: \(verbatim.connectionOfRequest)")
    }

    // MARK: TLS

    /// kTestCertPem (test-http.c:4909-4925): the C test's throw-away self-signed EC P-256
    /// certificate for 127.0.0.1 and its PKCS#8 key.
    static let testCertificateBase64 = """
        MIIBkDCCATagAwIBAgIUEJ3+CPYfSGuGgV0zawMs0itrygEwCgYIKoZIzj0EAwIw\
        FDESMBAGA1UEAwwJMTI3LjAuMC4xMCAXDTI2MTAxMjAyMDg0NVoYDzIxMjYwOTE4\
        MDIwODQ1WjAUMRIwEAYDVQQDDAkxMjcuMC4wLjEwWTATBgcqhkjOPQIBBggqhkjO\
        PQMBBwNCAATNCLIcH8kLhl6iNEvnts4Lpr5UK/txzONrTig7raO9HOy6IoFP2iMP\
        ukUMH5AxeuW0pkgO0N9A7dsE9H6Wlu9Ho2QwYjAdBgNVHQ4EFgQULBp9fpv2H/OK\
        fWqmzGD3HyZquV4wHwYDVR0jBBgwFoAULBp9fpv2H/OKfWqmzGD3HyZquV4wDwYD\
        VR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMAoGCCqGSM49BAMCA0gAMEUC\
        IQCzulUzzY8LyG1arq2em71QssNdR7lmMmjbTAMRcSugugIgD4kv9cNH3Wa3ZFZU\
        qXp+gcAkyseh7WKuJY97HydSf0U=
        """
    static let testKeyBase64 = """
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgHms+iuh/Ws2k3K/d\
        cxkH0BTpruMSnhnsgJMNjPDjB6ehRANCAATNCLIcH8kLhl6iNEvnts4Lpr5UK/tx\
        zONrTig7raO9HOy6IoFP2iMPukUMH5AxeuW0pkgO0N9A7dsE9H6Wlu9H
        """

    /// The server identity, built in memory (no keychain): the certificate, and the EC key
    /// in ANSI X9.63 form (04 || X || Y || D) taken from the fixed-layout PKCS#8 DER.
    static func testIdentity() throws -> SecIdentity {
        let certDER = try #require(Data(base64Encoded: testCertificateBase64))
        let keyDER = try #require(Data(base64Encoded: testKeyBase64))
        let certificate = try #require(SecCertificateCreateWithData(nil, certDER as CFData))
        let k = [UInt8](keyDER)
        try #require(k.count == 138 && k[34] == 0x04 && k[35] == 0x20 && Array(k[68..<73]) == [0xA1, 0x44, 0x03, 0x42, 0x00])
        let x963 = Data(k[73..<138] + k[36..<68])
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, &error))
        return try #require(SecIdentityCreate(nil, certificate, key))
    }

    /// A flag set from a Network.framework state handler and read by the test.
    private final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// A TLS listener on 127.0.0.1 with the C test's certificate (C: TlsFake,
    /// test-http.c:4927-4958): counts accepted connections and completed handshakes.
    private final class TLSFake: Sendable {
        private struct Counts {
            var started = 0
            var completed = 0
            var connections: [NWConnection] = []
        }
        private final class Box: Sendable {
            let mutex = Mutex(Counts())
            func withLock<R>(_ body: (inout Counts) -> R) -> R { mutex.withLock { body(&$0) } }
        }
        private let listener: NWListener
        private let counts: Box
        let port: UInt16

        var started: Int { counts.withLock { $0.started } }
        var completed: Int { counts.withLock { $0.completed } }

        init(identity: SecIdentity) throws {
            let queue = DispatchQueue(label: "HTTPClientTests.TLSFake")
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try #require(sec_identity_create(identity)))
            let parameters = NWParameters(tls: tls)
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let counts = Box()
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { connection in
                counts.withLock { $0.started += 1; $0.connections.append(connection) }
                connection.stateUpdateHandler = { state in
                    if case .ready = state { counts.withLock { $0.completed += 1 } }
                }
                connection.start(queue: queue)
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            self.listener = listener
            self.counts = counts
            port = try #require(listener.port?.rawValue)
        }

        func stop() {
            listener.cancel()
            counts.withLock { $0.connections.forEach { $0.cancel() } }
        }
    }

    // C: /http/net/tls-certificate-verified (test-http.c:4980-5032)
    @Test func tlsCertificateIsVerified() async throws {
        let fake = try TLSFake(identity: try Self.testIdentity())
        defer { fake.stop() }
        // Control (test-http.c:4997-5009): a TLS client that disables validation completes the
        // handshake. Observed in long test processes: Network.framework chose a loopback source
        // port that was still in use (connectx EADDRINUSE) and chose the SAME port again for a
        // fresh connection, so a failed or waiting control never recovers by itself. Each try
        // therefore binds its own source port outside the ephemeral range (49152-65535, where
        // every other loopback connection of the process lives) and is replaced on .failed or
        // .waiting: up to 5 tries of the C test's 5 s (test-http.c:5003-5005).
        let controlQueue = DispatchQueue(label: "HTTPClientTests.tls-control")
        let controlPort = try #require(NWEndpoint.Port(rawValue: fake.port))
        var portRNG = SeededRNG(seed: UInt64(fake.port))
        var controls: [NWConnection] = []
        defer { controls.forEach { $0.cancel() } }
        let connected = Flag()
        var completedTry = 0
        for attempt in 1...5 {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, controlQueue)
            let parameters = NWParameters(tls: options)
            let sourcePort = try #require(NWEndpoint.Port(rawValue: UInt16(20_000 + 4_000 * (attempt - 1)) + UInt16.random(in: 0..<4_000, using: &portRNG)))
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: sourcePort)
            let control = NWConnection(host: "127.0.0.1", port: controlPort, using: parameters)
            let dead = Flag()
            control.stateUpdateHandler = { state in
                switch state {
                case .ready: connected.set()
                case .failed, .waiting: dead.set()
                default: break
                }
            }
            controls.append(control)
            control.start(queue: controlQueue)
            _ = await Self.waitUntil(timeout: .seconds(5)) { fake.completed > 0 || dead.isSet }
            if fake.completed > 0 {
                completedTry = attempt
                break
            }
            control.cancel()
        }
        #expect(fake.completed > 0, "no control handshake completed in 5 tries")         // test-http.c:5006
        #expect(await Self.waitUntil(timeout: .seconds(5)) { connected.isSet },
                "control completed on try \(completedTry) but the client side never became ready")  // :5008
        let completedBefore = fake.completed
        let startedBefore = fake.started
        // HTTPClient: https://127.0.0.1 with the untrusted certificate.
        let http = try HTTPClient(baseURL: "https://127.0.0.1:\(fake.port)", userAgent: Self.ua, timeoutMs: 3000, backoffBaseMs: 5)
        let outcome = await Self.fetch(http)
        let error = try #require(Self.wxError(outcome), "\(outcome)")
        #expect(error.code == .network)                                               // test-http.c:5021
        #expect(error.message.contains("certificate"), "\(error.message)")            // test-http.c:5022
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.started > startedBefore)                                         // test-http.c:5024
        #expect(fake.completed == completedBefore)                                    // test-http.c:5025
    }
}

extension Result where Failure == WxError {
    /// The error code of a failure, nil for a success.
    fileprivate var failureCode: WxError.Code? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}
