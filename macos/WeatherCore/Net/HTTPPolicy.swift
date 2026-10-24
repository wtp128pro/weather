// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HTTPPolicy.swift - the pure policy of the hardened, host-pinned HTTP GET
// engine (C: src/net/wx-http.{h,c}). Nothing here touches the network: the
// URLSession transport (U13) asks these types what to send, whether a status
// is a success, whether to retry and how long to back off.
//
// Ported rules (C locators in the comments):
//  - constants                       wx-http.h:274-292, wx-http.c:17-23
//  - header value check              wx-http.c:70-82   (text_is_printable_ascii)
//  - request path check              wx-http.c:85-98   (wx_http_path_is_valid)
//  - Expires                         wx-http.c:101-114 (wx_http_parse_expires, libsoup date parser)
//  - host check                      wx-http.c:135-157 (host_is_acceptable)
//  - base URL normalisation          wx-http.c:180-199 (normalise_base_url over GLib g_uri_parse)
//  - constructor                     wx-http.c:343-362 (wx_http_new_custom)
//  - request validation and target   wx-http.c:2016-2041 (request_uri, SOUP_HTTP_URI_FLAGS)
//  - request headers                 wx-http.c:1574-1583
//  - status mapping                  wx-http.c:659-666 (http_status_error), wx-http.h:36-40
//  - retry decision and back-off     wx-http.c:765-783 (fail_attempt), :1849-1853 (schedule_retry)

import Foundation

/// The constants, messages and pure decisions of the HTTP client (C: wx-http).
public enum HTTPPolicy {
    // MARK: Constants (wx-http.h:274-292, wx-http.c:17-23)

    /// Per-attempt deadline covering headers and body, ms (WX_HTTP_TIMEOUT_MS).
    public static let timeoutMs = 10_000
    /// Whole-operation deadline including queue wait and back-off, ms (WX_HTTP_TOTAL_DEADLINE_MS).
    public static let totalDeadlineMs = 45_000
    /// First back-off delay, ms; it doubles per retry (WX_HTTP_BACKOFF_BASE_MS).
    public static let backoffBaseMs = 1_000
    /// Retries after the first attempt, so at most 3 requests (WX_HTTP_MAX_RETRIES).
    public static let maxRetries = 2
    /// Body cap AFTER content decoding, bytes (WX_HTTP_MAX_BODY_BYTES).
    public static let maxBodyBytes = 4 * 1024 * 1024
    /// Outstanding operations per client (WX_HTTP_MAX_INFLIGHT).
    public static let maxInflight = 16
    /// Read size of the body loop, bytes (WX_HTTP_READ_CHUNK).
    public static let readChunk = 16_384
    /// Longest request path-and-query, bytes (WX_HTTP_PATH_MAX).
    public static let pathMax = 2048
    /// Longest User-Agent / Accept value, bytes (WX_HTTP_HEADER_VALUE_MAX).
    public static let headerValueMax = 200
    /// Longest If-Modified-Since / Last-Modified / Expires value, bytes (WX_HTTP_VALIDATOR_MAX).
    public static let validatorMax = 64
    /// Upper bound of the three timing arguments of the constructor, ms (WX_HTTP_TIME_ARG_MAX_MS).
    public static let timeArgMaxMs = 600_000
    /// Longest accepted host name, bytes (HOST_MAX_BYTES).
    public static let hostMaxBytes = 253
    /// An Expires more than this far ahead of now is implausible, seconds (EXPIRES_MAX_AHEAD_S).
    public static let expiresMaxAheadS: Int64 = 86_400

    /// The project User-Agent used by all four production clients
    /// (providers/openmeteo/wx-openmeteo.c:17, nws/wx-nws.h:70, metno/wx-metno.h:146).
    public static let userAgent = "weather-app/0.1 (github.com/wtp128pro/weather)"
    /// The only content coding offered (wx-http.c:1581).
    public static let acceptEncoding = "gzip"
    /// Hosts that may be reached over plain http (wx-http.c:192-193).
    public static let loopbackHosts: [String] = ["127.0.0.1", "::1", "localhost"]
    /// The four production hosts (non-goal: no other host is contacted). Informational only:
    /// like C's WxHttp, this policy accepts any https base URL that passes host_is_acceptable;
    /// the providers pin these hosts through their fixed base-URL constants.
    public static let productionHosts: [String] = [
        "api.open-meteo.com", "geocoding-api.open-meteo.com", "api.weather.gov", "api.met.no",
    ]
    /// Lower-cased header names a request may carry on the wire (net/test-http.c:2005-2006);
    /// "if-modified-since" is added only when a validator is sent.
    public static let allowedRequestHeaderNames: Set<String> = [
        "host", "user-agent", "accept", "accept-encoding", "connection",
    ]
    /// Texts that must never appear in the head of a request sent without a validator, exactly
    /// the C test's list (net/test-http.c:2022-2023). With a validator, If-Modified-Since is the
    /// one permitted addition (wx-http.c:1582-1583).
    public static let forbiddenRequestHeadTexts: [String] = [
        "Cookie", "Authorization", "Referer", "Origin", "Mozilla", "If-Modified-Since", "Proxy-Authorization", "X-",
    ]

    /// What the transport must configure (wx-http.h:8-13, wx-http.c:364-366, :1576): GET only,
    /// redirects never followed (a 3xx is a final HTTP error), no cookie jar, no credentials or
    /// authentication handler, no URL cache, default TLS verification.
    public enum TransportRules {
        public static let method = "GET"
        public static let followsRedirects = false
        public static let sendsCookies = false
        public static let sendsCredentials = false
        public static let usesURLCache = false
    }

    // MARK: Messages (fixed; they never echo input or body text)

    /// Error messages of the C module, verbatim.
    public enum Message {
        public static let invalidUserAgent = "invalid User-Agent"              // wx-http.c:355
        public static let unacceptableBaseURL = "unacceptable base URL"        // wx-http.c:360
        public static let invalidRequestPath = "invalid request path"          // wx-http.c:2024
        public static let invalidAccept = "invalid Accept value"               // wx-http.c:2028
        public static let invalidIfModifiedSince = "invalid If-Modified-Since value" // wx-http.c:2033
        public static let malformedRequestPath = "malformed request path"      // wx-http.c:2039
        public static let requestTimedOut = "request timed out"                // wx-http.c:704
        public static let deadlineExceeded = "operation deadline exceeded"     // wx-http.c:702
        public static let responseTooLarge = "response too large"              // net-providers.md:56
        public static let operationCancelled = "operation was cancelled"       // wx-http.c:694
        /// The Swift port's replacement for the C criticals on out-of-range timing arguments.
        public static let invalidTiming = "invalid timing argument"
        /// "too many outstanding requests (limit 16)" (wx-http.c:2065-2066).
        public static var tooManyOutstanding: String {
            "too many outstanding requests (limit \(HTTPPolicy.maxInflight))"
        }
        /// "network error: %s" with the transport's own message (wx-http.c:706).
        public static func network(_ transportMessage: String) -> String {
            "network error: \(transportMessage)"
        }
    }

    // MARK: Header values (wx-http.c:70-82)

    /// text_is_printable_ascii: 1...max bytes, every one in 0x20...0x7E. The text ends at the
    /// first 0x00 byte; at most max + 1 bytes are examined.
    public static func isPrintableHeaderValue(bytes: some Collection<UInt8>, max: Int) -> Bool {
        var count = 0
        for b in bytes {
            if b == 0 { break }
            if count == max { return false }
            if b < 0x20 || b > 0x7E { return false }
            count += 1
        }
        return count > 0
    }

    /// String form of `isPrintableHeaderValue(bytes:max:)`; nil is refused.
    public static func isPrintableHeaderValue(_ text: String?, max: Int) -> Bool {
        guard let text else { return false }
        return isPrintableHeaderValue(bytes: text.utf8, max: max)
    }

    // MARK: Request path (wx-http.c:85-98)

    /// wx_http_path_is_valid: 1...pathMax bytes of 0x21...0x7E, starting with exactly one '/'
    /// (not "//"), without '#' and '\'. Ends at the first 0x00; at most pathMax + 1 bytes read.
    public static func isValidPath(bytes: some Collection<UInt8>) -> Bool {
        var count = 0
        var previous: UInt8 = 0
        for b in bytes {
            if b == 0 { break }
            if count == pathMax { return false }
            if count == 0 && b != 0x2F { return false }
            if count == 1 && previous == 0x2F && b == 0x2F { return false }
            if b <= 0x20 || b >= 0x7F || b == 0x23 || b == 0x5C { return false }
            previous = b
            count += 1
        }
        return count > 0
    }

    /// String form of `isValidPath(bytes:)`; nil is refused.
    public static func isValidPath(_ pathAndQuery: String?) -> Bool {
        guard let pathAndQuery else { return false }
        return isValidPath(bytes: pathAndQuery.utf8)
    }

    // MARK: Response metadata (wx-http.c:101-114, wx-http.h:205-213)

    /// wx_http_parse_expires: the HTTP date as UTC unix seconds t with nowS < t <= nowS + 86400,
    /// else 0 (nil, longer than validatorMax bytes, unparsable or outside the window).
    public static func parseExpires(bytes: some Collection<UInt8>, nowS: Int64) -> Int64 {
        var text: [UInt8] = []
        for b in bytes {
            if b == 0 { break }
            if text.count == validatorMax { return 0 }
            text.append(b)
        }
        guard let t = HTTPDate.parse(text) else { return 0 }
        // t > nowS, so the unsigned difference is exact whatever nowS is (wx-http.c:110-111).
        if t <= nowS || UInt64(bitPattern: t) &- UInt64(bitPattern: nowS) > UInt64(expiresMaxAheadS) {
            return 0
        }
        return t
    }

    /// String form of `parseExpires(bytes:nowS:)`; nil gives 0.
    public static func parseExpires(_ value: String?, nowS: Int64) -> Int64 {
        guard let value else { return 0 }
        return parseExpires(bytes: value.utf8, nowS: nowS)
    }

    /// Last-Modified is kept only when it is printable ASCII of 1...validatorMax bytes, so it can
    /// be sent back as If-Modified-Since (wx-http.h:205-208); otherwise nil.
    public static func usableLastModified(bytes: some Collection<UInt8>) -> String? {
        guard isPrintableHeaderValue(bytes: bytes, max: validatorMax) else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Status mapping (wx-http.c:659-666, wx-http.h:36-40)

    /// What a final HTTP status means for the caller.
    public enum StatusVerdict: Equatable, Sendable {
        /// 2xx, or 304 when If-Modified-Since was sent.
        case success
        /// Every other status, mapped by `statusError(_:)`.
        case failure(WxError)
    }

    /// 2xx -> success (204/205 with an empty body); 304 -> success only when an
    /// If-Modified-Since value was sent; anything else -> `statusError(_:)`.
    public static func classify(status: Int, sentIfModifiedSince: Bool) -> StatusVerdict {
        if (200...299).contains(status) || (status == 304 && sentIfModifiedSince) {
            return .success
        }
        return .failure(statusError(status))
    }

    /// http_status_error: 429 -> RATE_LIMITED "HTTP 429: rate limited"; 404 -> NOT_FOUND
    /// "HTTP 404: not found"; anything else -> HTTP "HTTP <status> <libsoup phrase>".
    public static func statusError(_ status: Int) -> WxError {
        switch status {
        case 429: return WxError(.rateLimited, "HTTP \(status): rate limited")
        case 404: return WxError(.notFound, "HTTP \(status): not found")
        default: return WxError(.http, "HTTP \(status) \(statusPhrase(status))")
        }
    }

    /// libsoup's fixed reason phrase (soup_status_get_phrase); server text is never used. The
    /// table equals reason_phrases[] of libsoup 3.6.6 libsoup/soup-status.c:150-210 (49 entries;
    /// 103 "Early Hints" is listed, 421 is not and so reads "Unknown Error"), source
    /// https://gitlab.gnome.org/GNOME/libsoup/-/raw/3.6.6/libsoup/soup-status.c.
    public static func statusPhrase(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 102: "Processing"
        case 103: "Early Hints"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 203: "Non-Authoritative Information"
        case 204: "No Content"
        case 205: "Reset Content"
        case 206: "Partial Content"
        case 207: "Multi-Status"
        case 300: "Multiple Choices"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 305: "Use Proxy"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 402: "Payment Required"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 407: "Proxy Authentication Required"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Request Entity Too Large"
        case 414: "Request-URI Too Long"
        case 415: "Unsupported Media Type"
        case 416: "Requested Range Not Satisfiable"
        case 417: "Expectation Failed"
        case 422: "Unprocessable Entity"
        case 423: "Locked"
        case 424: "Failed Dependency"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 505: "HTTP Version Not Supported"
        case 507: "Insufficient Storage"
        case 510: "Not Extended"
        default: "Unknown Error"
        }
    }

    // MARK: Retries (wx-http.c:765-783, :1849-1853)

    /// Whether a failed attempt may be retried: only NETWORK, a per-attempt TIMEOUT, or HTTP
    /// with a status 500...599, and never once the whole-operation deadline expired. 429, 404,
    /// other 4xx, 3xx, PARSE and INVALID_ARG are final. `httpStatus` is the attempt's status
    /// (0 when none was received).
    public static func isRetryable(_ code: WxError.Code, httpStatus: Int, totalDeadlineExpired: Bool) -> Bool {
        if totalDeadlineExpired { return false }
        switch code {
        case .network, .timeout: return true
        case .http: return (500...599).contains(httpStatus)
        default: return false
        }
    }

    /// fail_attempt: retry iff the failure is retryable and `attempt` (0 for the first request)
    /// is below `maxRetries`.
    public static func shouldRetry(
        _ code: WxError.Code, httpStatus: Int, attempt: Int, totalDeadlineExpired: Bool
    ) -> Bool {
        isRetryable(code, httpStatus: httpStatus, totalDeadlineExpired: totalDeadlineExpired)
            && attempt < maxRetries
    }

    /// schedule_retry: the wait after failed attempt number `attempt` (0-based) is
    /// base << attempt, so 1 s then 2 s with the default base.
    public static func backoffDelayMs(base: Int = backoffBaseMs, attempt: Int) -> Int {
        base << attempt
    }

    // MARK: Base URL (wx-http.c:135-199)

    /// normalise_base_url: "scheme://host[:port]" (lower-case, an IPv6 host in brackets) when the
    /// origin is acceptable, else nil. https is always allowed; http only towards 127.0.0.1, ::1
    /// and localhost. No userinfo, query, fragment, or path other than "" or "/" after GLib's
    /// dot-segment removal; port 1...65535; well-formed host labels.
    public static func normaliseBaseURL(bytes: some Collection<UInt8>) -> String? {
        let text = Array(bytes.prefix { $0 != 0 })
        guard let uri = GURI.parse(text, flags: .none) else { return nil }
        guard let host = uri.host, hostIsAcceptable(host), uri.userinfo == nil, uri.query == nil,
              uri.fragment == nil, uri.path.isEmpty || uri.path == [0x2F], uri.port != 0
        else { return nil }
        let lowerHost = String(decoding: host.map(GURI.asciiLower), as: UTF8.self)
        let loopback = loopbackHosts.contains(lowerHost)
        guard uri.scheme == "https" || (uri.scheme == "http" && loopback) else { return nil }
        let ipv6 = lowerHost.contains(":")
        let portText = uri.port > 0 ? ":\(uri.port)" : ""
        return "\(uri.scheme)://\(ipv6 ? "[" : "")\(lowerHost)\(ipv6 ? "]" : "")\(portText)"
    }

    /// String form of `normaliseBaseURL(bytes:)`.
    public static func normaliseBaseURL(_ baseURL: String) -> String? {
        normaliseBaseURL(bytes: baseURL.utf8)
    }

    /// host_is_acceptable: 1...253 bytes; an IPv6 literal (contains ':') of hex digits, ':' and
    /// '.', or dot-separated labels of 1...63 ASCII letters, digits and '-', none starting or
    /// ending with '-', no trailing dot.
    static func hostIsAcceptable(_ host: [UInt8]) -> Bool {
        if host.isEmpty || host.count > hostMaxBytes { return false }
        if host.contains(0x3A) {
            return host.allSatisfy { GURI.isHex($0) || $0 == 0x2E || $0 == 0x3A }
        }
        var labelLength = 0
        var previous: UInt8 = 0
        for b in host {
            if b == 0x2E {
                if labelLength == 0 || previous == 0x2D { return false }
                labelLength = 0
                previous = b
                continue
            }
            let alnum = GURI.isAlpha(b) || GURI.isDigit(b)
            if !(alnum || b == 0x2D) || (b == 0x2D && labelLength == 0) { return false }
            labelLength += 1
            if labelLength > 63 { return false }
            previous = b
        }
        return labelLength > 0 && host[host.count - 1] != 0x2D
    }

    // MARK: Request target (wx-http.c:2016-2041)

    /// The target libsoup sends for an already-validated path-and-query: unreserved %-escapes
    /// decoded, other escapes upper-cased, dot segments removed from the path (GLib g_uri_parse
    /// with SOUP_HTTP_URI_FLAGS). nil when a '%' is not followed by two hex digits, which C
    /// reports as "malformed request path".
    public static func normalisedTarget(validPath bytes: some Collection<UInt8>) -> String? {
        let text = Array(bytes.prefix { $0 != 0 })
        let queryStart = text.firstIndex(of: 0x3F) ?? text.count
        guard var path = GURI.decode(text[..<queryStart], justNormalize: true, illegalNUL: false)
        else { return nil }
        path = GURI.removeDotSegments(path)
        var out = path
        if queryStart < text.count {
            guard let query = GURI.decode(text[(queryStart + 1)...], justNormalize: true, illegalNUL: false)
            else { return nil }
            out.append(0x3F)
            out += query
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Client configuration

/// One request header field, in the order the transport must send it.
public struct HTTPHeaderField: Equatable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// What a single GET must look like on the wire.
public struct HTTPRequestPlan: Equatable, Sendable {
    /// The full URL: the pinned origin (default port dropped, as GLib's scheme normalisation
    /// does) followed by `target`.
    public let url: String
    /// The normalised path-and-query of the request line. It is an origin-form target that
    /// must be sent as the request-line path of the pinned origin (use `url`, or this text as
    /// the percent-encoded path of that origin) and must NEVER be resolved as a relative
    /// reference: after dot-segment removal it may begin with "//" (for example "/.//evil.com"
    /// gives "//evil.com", exactly as GLib does), and `URL(string: target, relativeTo: origin)`
    /// would then leave the origin for host evil.com.
    public let target: String
    /// User-Agent, Accept, Accept-Encoding: gzip and, when given, If-Modified-Since. Host is
    /// derived from the URL by the transport; nothing else may be added.
    public let headers: [HTTPHeaderField]
    /// Whether If-Modified-Since is sent (304 is then a success).
    public let sendsIfModifiedSince: Bool
}

/// A validated client configuration (C: wx_http_new / wx_http_new_custom). A value is always
/// valid: its origin is pinned and every request it plans stays on that origin.
public struct HTTPClientPolicy: Equatable, Sendable {
    /// Normalised origin "scheme://host[:port]" (no trailing "/").
    public let origin: String
    public let userAgent: String
    public let timeoutMs: Int
    public let backoffBaseMs: Int
    public let minGapMs: Int

    /// wx_http_new_custom. The User-Agent is checked first ("invalid User-Agent"), then the base
    /// URL ("unacceptable base URL"); both INVALID_ARG with a fixed message. The timing ranges
    /// (timeout 1...600000, back-off and gap 0...600000) were criticals in C; here they throw
    /// INVALID_ARG "invalid timing argument" before anything else.
    public init(
        baseURL: String, userAgent: String = HTTPPolicy.userAgent,
        timeoutMs: Int = HTTPPolicy.timeoutMs, backoffBaseMs: Int = HTTPPolicy.backoffBaseMs,
        minGapMs: Int = 0
    ) throws(WxError) {
        try self.init(
            baseURLBytes: Array(baseURL.utf8), userAgentBytes: Array(userAgent.utf8),
            timeoutMs: timeoutMs, backoffBaseMs: backoffBaseMs, minGapMs: minGapMs)
    }

    /// Byte form of the initialiser, for inputs that may not be valid UTF-8.
    public init(
        baseURLBytes: [UInt8], userAgentBytes: [UInt8],
        timeoutMs: Int = HTTPPolicy.timeoutMs, backoffBaseMs: Int = HTTPPolicy.backoffBaseMs,
        minGapMs: Int = 0
    ) throws(WxError) {
        let maxMs = HTTPPolicy.timeArgMaxMs
        guard (1...maxMs).contains(timeoutMs), (0...maxMs).contains(backoffBaseMs),
              (0...maxMs).contains(minGapMs)
        else { throw WxError(.invalidArg, HTTPPolicy.Message.invalidTiming) }
        guard HTTPPolicy.isPrintableHeaderValue(bytes: userAgentBytes, max: HTTPPolicy.headerValueMax)
        else { throw WxError(.invalidArg, HTTPPolicy.Message.invalidUserAgent) }
        guard let origin = HTTPPolicy.normaliseBaseURL(bytes: baseURLBytes)
        else { throw WxError(.invalidArg, HTTPPolicy.Message.unacceptableBaseURL) }
        self.origin = origin
        self.userAgent = String(decoding: userAgentBytes.prefix { $0 != 0 }, as: UTF8.self)
        self.timeoutMs = timeoutMs
        self.backoffBaseMs = backoffBaseMs
        self.minGapMs = minGapMs
    }

    /// request_uri: validates the path, Accept and If-Modified-Since (in that order, each
    /// INVALID_ARG with a fixed message), then builds the pinned request.
    public func plan(pathAndQuery: String, accept: String, ifModifiedSince: String? = nil) throws(WxError)
        -> HTTPRequestPlan
    {
        try plan(
            pathAndQueryBytes: Array(pathAndQuery.utf8), acceptBytes: Array(accept.utf8),
            ifModifiedSinceBytes: ifModifiedSince.map { Array($0.utf8) })
    }

    /// Byte form of `plan(pathAndQuery:accept:ifModifiedSince:)`.
    public func plan(pathAndQueryBytes: [UInt8], acceptBytes: [UInt8], ifModifiedSinceBytes: [UInt8]?)
        throws(WxError) -> HTTPRequestPlan
    {
        guard HTTPPolicy.isValidPath(bytes: pathAndQueryBytes)
        else { throw WxError(.invalidArg, HTTPPolicy.Message.invalidRequestPath) }
        guard HTTPPolicy.isPrintableHeaderValue(bytes: acceptBytes, max: HTTPPolicy.headerValueMax)
        else { throw WxError(.invalidArg, HTTPPolicy.Message.invalidAccept) }
        if let ims = ifModifiedSinceBytes,
           !HTTPPolicy.isPrintableHeaderValue(bytes: ims, max: HTTPPolicy.validatorMax) {
            throw WxError(.invalidArg, HTTPPolicy.Message.invalidIfModifiedSince)
        }
        guard let target = HTTPPolicy.normalisedTarget(validPath: pathAndQueryBytes)
        else { throw WxError(.invalidArg, HTTPPolicy.Message.malformedRequestPath) }
        let text = { (b: [UInt8]) in String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }
        var headers = [
            HTTPHeaderField(name: "User-Agent", value: userAgent),
            HTTPHeaderField(name: "Accept", value: text(acceptBytes)),
            HTTPHeaderField(name: "Accept-Encoding", value: HTTPPolicy.acceptEncoding),
        ]
        if let ims = ifModifiedSinceBytes {
            headers.append(HTTPHeaderField(name: "If-Modified-Since", value: text(ims)))
        }
        return HTTPRequestPlan(
            url: schemeNormalisedOrigin + target, target: target, headers: headers,
            sendsIfModifiedSince: ifModifiedSinceBytes != nil)
    }

    /// The origin with the scheme's default port removed (G_URI_FLAGS_SCHEME_NORMALIZE in
    /// SOUP_HTTP_URI_FLAGS): what the transport connects to and sends as Host.
    public var schemeNormalisedOrigin: String {
        if origin.hasPrefix("https://"), origin.hasSuffix(":443") { return String(origin.dropLast(4)) }
        if origin.hasPrefix("http://"), origin.hasSuffix(":80") { return String(origin.dropLast(3)) }
        return origin
    }

    /// The back-off before retry number attempt + 1 with this client's base.
    public func backoffDelayMs(attempt: Int) -> Int {
        HTTPPolicy.backoffDelayMs(base: backoffBaseMs, attempt: attempt)
    }
}

// MARK: - GLib GUri subset (private port of glib/guri.c and glib/ghostutils.c)

extension HTTPPolicy {
/// The parts of GLib's g_uri_parse that decide what normalise_base_url sees. Internal for tests.
enum GURI {
    enum Flags { case none }

    struct Parsed {
        var scheme: String
        var userinfo: [UInt8]?
        var host: [UInt8]?
        var port: Int  // -1 when absent
        var path: [UInt8]
        var query: [UInt8]?
        var fragment: [UInt8]?
    }

    static func isAlpha(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
    static func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }
    static func isHex(_ b: UInt8) -> Bool { isDigit(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b) }
    static func asciiLower(_ b: UInt8) -> UInt8 { (0x41...0x5A).contains(b) ? b + 0x20 : b }
    static func asciiUpper(_ b: UInt8) -> UInt8 { (0x61...0x7A).contains(b) ? b - 0x20 : b }
    private static func hexValue(_ b: UInt8) -> UInt8 {
        isDigit(b) ? b - 0x30 : asciiLower(b) - 0x61 + 10
    }
    private static func isUnreserved(_ b: UInt8) -> Bool {
        isAlpha(b) || isDigit(b) || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
    }

    /// uri_decoder: %XX decoding (or normalising), strict about bad escapes; %00 is refused when
    /// illegalNUL; the decoded text must be UTF-8 unless the component stays encoded.
    static func decode(_ input: ArraySlice<UInt8>, justNormalize: Bool, illegalNUL: Bool) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = input.startIndex
        let end = input.endIndex
        while i < end {
            let b = input[i]
            if b == 0x25 {
                guard i + 2 < end, isHex(input[i + 1]), isHex(input[i + 2]) else { return nil }
                let c = hexValue(input[i + 1]) << 4 | hexValue(input[i + 2])
                if illegalNUL && c == 0 { return nil }
                if justNormalize && !isUnreserved(c) {
                    out += [0x25, asciiUpper(input[i + 1]), asciiUpper(input[i + 2])]
                } else {
                    out.append(c)
                }
                i += 3
            } else {
                out.append(b)
                i += 1
            }
        }
        if !justNormalize && String(validating: out, as: UTF8.self) == nil { return nil }
        return out
    }

    /// remove_dot_segments (RFC 3986 5.2.4).
    static func removeDotSegments(_ path: [UInt8]) -> [UInt8] {
        var input = path[...]
        var output: [UInt8] = []
        func starts(_ p: String) -> Bool { input.starts(with: p.utf8) }
        func removeLastSegment() {
            if let slash = output.lastIndex(of: 0x2F) { output.removeSubrange(slash...) } else { output.removeAll() }
        }
        while !input.isEmpty {
            if starts("../") {
                input = input.dropFirst(3)
            } else if starts("./") {
                input = input.dropFirst(2)
            } else if starts("/./") {
                input = input.dropFirst(2)
            } else if input.elementsEqual("/.".utf8) {
                input = [0x2F][...]
            } else if starts("/../") {
                input = input.dropFirst(3)
                removeLastSegment()
            } else if input.elementsEqual("/..".utf8) {
                input = [0x2F][...]
                removeLastSegment()
            } else if input.elementsEqual(".".utf8) || input.elementsEqual("..".utf8) {
                input = [][...]
            } else {
                var j = input.startIndex
                if input[j] == 0x2F { j += 1 }
                while j < input.endIndex && input[j] != 0x2F { j += 1 }
                output += input[input.startIndex..<j]
                input = input[j...]
            }
        }
        return output
    }

    /// g_uri_parse(text, G_URI_FLAGS_NONE): an absolute URI or nil.
    static func parse(_ text: [UInt8], flags: Flags) -> Parsed? {
        // Scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
        var p = 0
        while p < text.count,
              isAlpha(text[p]) || (p > 0 && (isDigit(text[p]) || text[p] == 0x2E || text[p] == 0x2B || text[p] == 0x2D)) {
            p += 1
        }
        guard p > 0, p < text.count, text[p] == 0x3A else { return nil }
        let scheme = String(decoding: text[0..<p].map(asciiLower), as: UTF8.self)
        p += 1
        var result = Parsed(scheme: scheme, userinfo: nil, host: nil, port: -1, path: [], query: nil, fragment: nil)
        if p + 1 < text.count, text[p] == 0x2F, text[p + 1] == 0x2F {
            p += 2
            var pathStart = p
            while pathStart < text.count, ![0x2F, 0x3F, 0x23].contains(text[pathStart]) { pathStart += 1 }
            var hostStart = p
            if let at = text[p..<pathStart].firstIndex(of: 0x40) {
                guard let userinfo = decode(text[p..<at], justNormalize: false, illegalNUL: true) else { return nil }
                result.userinfo = userinfo
                hostStart = at + 1
            }
            var hostEnd = pathStart
            var colon: Int? = nil
            if hostStart < pathStart, text[hostStart] == 0x5B {
                guard let close = text[hostStart..<pathStart].firstIndex(of: 0x5D) else { return nil }
                hostEnd = close + 1
                if hostEnd < pathStart {
                    guard text[hostEnd] == 0x3A else { return nil }
                    colon = hostEnd
                }
            } else if let c = text[hostStart..<pathStart].firstIndex(of: 0x3A) {
                hostEnd = c
                colon = c
            }
            guard let host = parseHost(text[hostStart..<hostEnd]) else { return nil }
            result.host = host
            if let colon, colon + 1 < pathStart {
                guard let port = parsePort(text[(colon + 1)..<pathStart]) else { return nil }
                result.port = port
            }
            p = pathStart
        }
        var end = p
        while end < text.count, text[end] != 0x23 { end += 1 }
        if end < text.count {
            guard let fragment = decode(text[(end + 1)...], justNormalize: false, illegalNUL: true)
            else { return nil }
            result.fragment = fragment
        }
        var pathEnd = end
        if let q = text[p..<end].firstIndex(of: 0x3F) {
            guard let query = decode(text[(q + 1)..<end], justNormalize: false, illegalNUL: true)
            else { return nil }
            result.query = query
            pathEnd = q
        }
        guard let path = decode(text[p..<pathEnd], justNormalize: false, illegalNUL: true) else { return nil }
        result.path = removeDotSegments(path)
        return result
    }

    private static func parsePort(_ text: ArraySlice<UInt8>) -> Int? {
        guard let first = text.first, isDigit(first) else { return nil }
        var value = 0
        for b in text {
            guard isDigit(b) else { return nil }
            value = value * 10 + Int(b - 0x30)
            if value > 65535 { return nil }
        }
        return value
    }

    /// parse_host: an IPv6 literal in brackets, a dotted IPv4 address, or a %-decoded name
    /// (converted to punycode when non-ASCII). A decoded name may not be an IP address.
    private static func parseHost(_ text: ArraySlice<UInt8>) -> [UInt8]? {
        guard let first = text.first else { return [] }
        if first == 0x5B {
            guard text.count >= 2, text.last == 0x5D else { return nil }
            var address = Array(text.dropFirst().dropLast())
            var zone: [UInt8] = []
            if let pct = address.firstIndex(of: 0x25) {
                guard address[pct...].starts(with: "%25".utf8), pct + 3 < address.count else { return nil }
                zone = [0x25] + address[(pct + 3)...]
                address = Array(address[..<pct])
            }
            guard address.contains(0x3A), isIPAddress(address) else { return nil }
            return address + zone
        }
        if isDigit(first), isIPAddress(Array(text)) { return Array(text) }
        guard let decoded = decode(text, justNormalize: false, illegalNUL: true) else { return nil }
        if isIPAddress(decoded) { return nil }
        if decoded.contains(where: { $0 >= 0x80 }) { return hostnameToASCII(decoded) }
        return decoded
    }

    /// g_hostname_is_ip_address.
    static func isIPAddress(_ s: [UInt8]) -> Bool {
        var p = 0
        func at(_ i: Int) -> UInt8 { i < s.count ? s[i] : 0 }
        if s.contains(0x3A) {
            var segments = 0
            var skipped = false
            var ipv4 = false
            while at(p) != 0 && at(p) != 0x25 && segments < 8 {
                if p != 0 || (at(p) == 0x3A && at(p + 1) == 0x3A) {
                    if at(p) != 0x3A { return false }
                    p += 1
                }
                if at(p) == 0x3A && !skipped {
                    skipped = true
                    segments += 1
                    if at(p + 1) == 0 { p += 1 }
                    continue
                }
                var end = p
                while isHex(at(end)) { end += 1 }
                if end == p || end > p + 4 { return false }
                if at(end) == 0x2E {
                    if (segments == 6 && !skipped) || (segments <= 6 && skipped) { ipv4 = true; break }
                    return false
                }
                segments += 1
                p = end
            }
            if !ipv4 {
                return (at(p) == 0 || (at(p) == 0x25 && at(p + 1) != 0)) && (segments == 8 || skipped)
            }
        }
        for segment in 0..<4 {
            if segment != 0 {
                if at(p) != 0x2E { return false }
                p += 1
            }
            var octet = 0
            var end = p
            if at(p) == 0x30 {
                end = p + 1
            } else {
                while isDigit(at(end)) {
                    octet = 10 * octet + Int(at(end) - 0x30)
                    if octet > 255 { break }
                    end += 1
                }
            }
            if end == p || end > p + 3 || octet > 255 { return false }
            p = end
        }
        return at(p) == 0
    }

    /// g_hostname_to_ascii, ported from GLib 2.90.1 glib/ghostutils.c:464-545 with nameprep
    /// (:302-390), remove_junk (:205-238), idna_is_prohibited (:268-298) and punycode_encode
    /// (:111-203); source https://gitlab.gnome.org/GNOME/glib/-/raw/2.90.1/glib/ghostutils.c
    /// (sha256 6c360d2f6a8366a1a328d93bdf74c317749ce7c3ef36480a3d7edd31731c332f). The Unicode
    /// tables (general category, lower-case mapping, NFKC) are the Swift runtime's, which can
    /// differ from GLib's for characters assigned in a newer Unicode version; g_utf8_strdown runs
    /// as in the C/POSIX locale (no Turkic or Lithuanian rules). Only non-ASCII hosts reach it.
    private static func hostnameToASCII(_ name: [UInt8]) -> [UInt8]? {
        // :494-496: strlen_greater_than (hostname, 4 * MAX (255, HOST_NAME_MAX)) is TRUE once a
        // byte exists at an index above 1020.
        if name.count > 4 * 255 + 1 { return nil }
        guard let text = String(validating: name, as: UTF8.self) else { return nil }
        // nameprep: remove the junk characters of RFC 3454 table B.1.
        var scalars = Array(text.unicodeScalars).filter { !isIDNAJunk($0.value) }
        // Lower-case only when an upper-case letter (Lu) is present.
        if scalars.contains(where: { $0.properties.generalCategory == .uppercaseLetter }) {
            scalars = utf8Strdown(scalars)
        }
        // "If there are no UTF8 characters, we're done": returned unchanged (a trailing dot stays).
        if scalars.allSatisfy({ $0.isASCII }) { return Array(String(String.UnicodeScalarView(scalars)).utf8) }
        scalars = Array(String(String.UnicodeScalarView(scalars)).precomposedStringWithCompatibilityMapping.unicodeScalars)
        if scalars.contains(where: { $0.properties.generalCategory == .uppercaseLetter }) {
            scalars = utf8Strdown(scalars)
        }
        if scalars.contains(where: isIDNAProhibited) { return nil }
        // The label loop of g_hostname_to_ascii: a dot is '.', U+3002, U+FF0E or U+FF61; the dot
        // after the last label is dropped.
        let isDot: (Unicode.Scalar) -> Bool = { [0x2E, 0x3002, 0xFF0E, 0xFF61].contains($0.value) }
        var out: [UInt8] = []
        var label = 0
        repeat {
            var p = label
            var unicode = false
            while p < scalars.count && !isDot(scalars[p]) {
                if !scalars[p].isASCII { unicode = true }
                p += 1
            }
            let oldLength = out.count
            let labelScalars = Array(scalars[label..<p])
            if unicode {
                let labelBytes = Array(String(String.UnicodeScalarView(labelScalars)).utf8)
                if labelBytes.starts(with: "xn--".utf8) { return nil }
                out += Array("xn--".utf8)
                guard let encoded = punycode(labelScalars) else { return nil }
                out += encoded
            } else {
                out += labelScalars.map { UInt8($0.value) }
            }
            if out.count - oldLength > 63 { return nil }
            label = p
            if label < scalars.count { label += 1 }
            if label < scalars.count { out.append(0x2E) }
        } while label < scalars.count
        return out
    }

    /// idna_is_junk (ghostutils.c:206).
    private static func isIDNAJunk(_ c: UInt32) -> Bool {
        [0x00AD, 0x1806, 0x200B, 0x2060, 0xFEFF, 0x034F, 0x180B, 0x180C, 0x180D, 0x200C, 0x200D].contains(c)
            || (0xFE00...0xFE0F).contains(c)
    }

    /// idna_is_prohibited (ghostutils.c:268-298).
    private static func isIDNAProhibited(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .control, .format, .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator,
             .spaceSeparator:
            return true
        case .otherSymbol:
            return c.value == 0xFFFC || c.value == 0xFFFD || (0x2FF0...0x2FFB).contains(c.value)
        case .nonspacingMark:
            return c.value == 0x0340 || c.value == 0x0341
        default:
            return false
        }
    }

    /// g_utf8_strdown outside Turkic and Lithuanian locales (GLib guniprop.c real_tolower):
    /// capital sigma becomes final sigma unless a letter (L*) follows; Lu and Lt letters take
    /// their lower-case mapping (U+0130 becomes "i" + U+0307); everything else is copied.
    private static func utf8Strdown(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for (index, c) in scalars.enumerated() {
            if c.value == 0x03A3 {
                let next = index + 1 < scalars.count ? scalars[index + 1].properties.generalCategory : nil
                let letter: [Unicode.GeneralCategory] = [
                    .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                ]
                out.append(Unicode.Scalar(next.map(letter.contains) == true ? 0x03C3 : 0x03C2)!)
            } else if [.uppercaseLetter, .titlecaseLetter].contains(c.properties.generalCategory) {
                out += c.properties.lowercaseMapping.unicodeScalars
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// punycode_encode (ghostutils.c:111-203), RFC 3492 section 6.3, in GLib's 32-bit unsigned
    /// arithmetic: it wraps like guint and fails where GLib's overflow checks fail.
    private static func punycode(_ input: [Unicode.Scalar]) -> [UInt8]? {
        let base: UInt32 = 36, tMin: UInt32 = 1, tMax: UInt32 = 26, skew: UInt32 = 38, damp: UInt32 = 700
        func digit(_ d: UInt32) -> UInt8 { d < 26 ? UInt8(truncatingIfNeeded: d) &+ 0x61 : UInt8(truncatingIfNeeded: d &- 26) &+ 0x30 }
        func adapt(_ value: UInt32, _ numPoints: UInt32, _ firstTime: Bool) -> UInt32 {
            var delta = firstTime ? value / damp : value / 2
            delta &+= delta / numPoints
            var k: UInt32 = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k &+= base
            }
            return k &+ ((base - tMin + 1) &* delta / (delta &+ skew))
        }
        let cps = input.map(\.value)
        let length = UInt32(cps.count)
        var output: [UInt8] = []
        var basic: UInt32 = 0
        for c in cps where c < 0x80 {
            output.append(asciiLower(UInt8(c)))
            basic += 1
        }
        if basic > 0 { output.append(0x2D) }
        var handled = basic
        var delta: UInt32 = 0, bias: UInt32 = 72, n: UInt32 = 0x80
        while handled < length {
            var m = UInt32.max
            for c in cps where c >= n && c < m { m = c }
            if m &- n > (UInt32.max &- delta) / (handled &+ 1) { return nil }
            delta &+= (m &- n) &* (handled &+ 1)
            n = m
            for c in cps {
                if c < n {
                    delta &+= 1
                    if delta == 0 { return nil }
                } else if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias &+ tMax ? tMax : k &- bias)
                        if q < t { break }
                        output.append(digit(t &+ (q &- t) % (base &- t)))
                        q = (q &- t) / (base &- t)
                        k &+= base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled &+ 1, handled == basic)
                    delta = 0
                    handled &+= 1
                }
            }
            delta &+= 1
            n &+= 1
        }
        return output
    }
}

}

// MARK: - libsoup HTTP date parser (soup_date_time_new_from_http_string)

extension HTTPPolicy {

/// A line-by-line port of libsoup 3.6.6 libsoup/soup-date-utils.c:123-342 (parse_day,
/// parse_month, parse_year, parse_time, parse_timezone, parse_textual_date and
/// soup_date_time_new_from_http_string), source
/// https://gitlab.gnome.org/GNOME/libsoup/-/raw/3.6.6/libsoup/soup-date-utils.c
/// (sha256 5a19e18ff9f1604b8d9967f0e427cb9dc32fb66ce6a7d4ad8e1764e5309337cc), with the quirks kept:
///  - a value that starts with a digit and holds none of the upper-case letters "JFMASOND" is
///    refused (:336-339), so "06 nov 1994 08:49:37" is refused and "06 nov 1994 08:49:37 GMT" is not;
///  - day 1...31, year 1...9998, hour 0...23, minute and second 0...59 (:135, :175, :199);
///  - every number is read with C strtoul (leading blanks and a sign accepted, overflow to
///    ULONG_MAX, stored in a C int);
///  - a numeric zone above 9999, or with a colon part above 99, is no zone (UTC) (:215-220);
///  - EST/EDT/CST/... use -60 * (5 * strcspn("ECMP", rest of the text)) minutes (+60 for 'D')
///    (:238), so EST is +0, CST -5 h, MST -10 h, PST -15 h, and "PST EXTRA" counts as EST;
///  - a zone GLib's g_time_zone_new_offset cannot represent becomes UTC (see `glibOffsetSeconds`).
/// Inputs end at the first 0x00 byte, like a C string. Internal for tests.
enum HTTPDate {
    /// soup-date-utils.c:65-68.
    private static let months: [[UInt8]] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ].map { Array($0.utf8) }

    /// The broken-down date of parse_textual_date and the zone parse_timezone produced.
    private struct Fields {
        var day: Int32 = 0, month: Int32 = 0, year: Int32 = 0
        var hour: Int32 = 0, minute: Int32 = 0, second: Int32 = 0
    }

    /// The GTimeZone parse_timezone creates: UTC, or a fixed offset in minutes.
    private enum Zone {
        case utc
        case offset(minutes: Int32)
    }

    /// soup_date_time_new_from_http_string followed by g_date_time_to_unix: UTC unix seconds, or
    /// nil when libsoup returns NULL.
    static func parse(_ text: [UInt8]) -> Int64? {
        var s = Cursor(text)
        // :325-326
        while gAsciiIsSpace(s.peek) { s.i += 1 }
        // :336-339 (G_UNLIKELY (g_ascii_isdigit (*date_string) && !strpbrk (date_string, "JFMASOND")))
        if gAsciiIsDigit(s.peek) && !s.strpbrk("JFMASOND") { return nil }
        return parseTextualDate(&s)
    }

    /// parse_textual_date (:252-305).
    private static func parseTextualDate(_ s: inout Cursor) -> Int64? {
        var f = Fields()
        var zone: Zone? = nil
        // "If it starts with a word, it must be a weekday, which we skip"
        if gAsciiIsAlpha(s.peek) {
            while gAsciiIsAlpha(s.peek) { s.i += 1 }
            if s.peek == 0x2C { s.i += 1 }
            while gAsciiIsSpace(s.peek) { s.i += 1 }
        }
        if gAsciiIsAlpha(s.peek) {
            // asctime-date: (Sun) Nov  6 08:49:37 1994
            guard parseMonth(&f.month, &s), parseDay(&f.day, &s),
                  parseTime(&f.hour, &f.minute, &f.second, &s), parseYear(&f.year, &s),
                  gDateValidDMY(f.day, f.month, f.year)
            else { return nil }
            // "There shouldn't be a timezone, but check anyway"
            zone = parseTimezone(&s)
        } else {
            // (Sun,) 06 Nov 1994 08:49:37 GMT
            guard parseDay(&f.day, &s), parseMonth(&f.month, &s), parseYear(&f.year, &s),
                  parseTime(&f.hour, &f.minute, &f.second, &s), gDateValidDMY(f.day, f.month, f.year)
            else { return nil }
            // "This time there *should* be a timezone, but we survive if there isn't."
            zone = parseTimezone(&s)
        }
        // :298-299: no zone means UTC.
        let tz = zone ?? .utc
        return gDateTimeNewToUnix(tz, f)
    }

    /// parse_day (:123-136).
    private static func parseDay(_ day: inout Int32, _ s: inout Cursor) -> Bool {
        let (value, end) = s.strtoul(from: s.i)
        day = cInt(value)
        if end == s.i { return false }
        var e = end
        while s.at(e) == 0x20 || s.at(e) == 0x2D { e += 1 }
        s.i = e
        return day >= 1 && day <= 31
    }

    /// parse_month (:138-153), g_ascii_strncasecmp over 3 bytes.
    private static func parseMonth(_ month: inout Int32, _ s: inout Cursor) -> Bool {
        for (index, name) in months.enumerated() {
            let matches = (0..<3).allSatisfy { k in
                gAsciiToLower(s.at(s.i + k)) == gAsciiToLower(name[k])
            }
            if matches {
                month = Int32(index + 1)
                s.i += 3
                while s.peek == 0x20 || s.peek == 0x2D { s.i += 1 }
                return true
            }
        }
        return false
    }

    /// parse_year (:155-176): two digits are 19xx/20xx around 70, three are 1900 + n; the width
    /// is what strtoul consumed, leading blanks and sign included.
    private static func parseYear(_ year: inout Int32, _ s: inout Cursor) -> Bool {
        let start = s.i
        let (value, end) = s.strtoul(from: start)
        year = cInt(value)
        if end == start { return false }
        if end == start + 2 {
            if year < 70 { year &+= 2000 } else { year &+= 1900 }
        } else if end == start + 3 {
            year &+= 1900
        }
        var e = end
        while s.at(e) == 0x20 || s.at(e) == 0x2D { e += 1 }
        s.i = e
        return year > 0 && year < 9999
    }

    /// parse_time (:178-200).
    private static func parseTime(
        _ hour: inout Int32, _ minute: inout Int32, _ second: inout Int32, _ s: inout Cursor
    ) -> Bool {
        let (h, e1) = s.strtoul(from: s.i)
        hour = cInt(h)
        if e1 == s.i || s.at(e1) != 0x3A { return false }
        var p = e1 + 1
        let (m, e2) = s.strtoul(from: p)
        minute = cInt(m)
        if e2 == p || s.at(e2) != 0x3A { return false }
        p = e2 + 1
        let (sec, e3) = s.strtoul(from: p)
        second = cInt(sec)
        if e3 == p { return false }
        p = e3
        while s.at(p) == 0x20 { p += 1 }
        s.i = p
        return hour >= 0 && hour < 24 && minute >= 0 && minute < 60 && second >= 0 && second < 60
    }

    /// parse_timezone (:202-250); nil is its FALSE (no zone).
    private static func parseTimezone(_ s: inout Cursor) -> Zone? {
        let offsetMinutes: Int32
        let utc: Bool
        let c = s.peek
        if c == 0 {
            utc = false
            offsetMinutes = 0
        } else if c == 0x2B || c == 0x2D {
            let sign: Int64 = c == 0x2B ? 1 : -1
            // val = strtoul (*date_string + 1, (char **)date_string, 10)
            let (first, end) = s.strtoul(from: s.i + 1)
            var val = first
            s.i = end
            if val > 9999 { return nil }
            if s.peek == 0x3A {
                let (val2, end2) = s.strtoul(from: s.i + 1)
                s.i = end2
                if val > 99 || val2 > 99 { return nil }
                val = 60 &* val &+ val2
            } else {
                val = 60 &* (val / 100) &+ (val % 100)
            }
            // gint32 = int * gulong: computed in unsigned long, then truncated.
            offsetMinutes = cInt(UInt64(bitPattern: sign) &* val)
            utc = sign == -1 && val == 0
        } else if c == 0x5A {
            offsetMinutes = 0
            utc = true
            s.i += 1
        } else if s.restEquals("GMT") || s.restEquals("UTC") {
            offsetMinutes = 0
            utc = true
            s.i += 3
        } else if Array("ECMP".utf8).contains(c), s.at(s.i + 1) == 0x44 || s.at(s.i + 1) == 0x53,
                  s.at(s.i + 2) == 0x54 {
            // offset_minutes = -60 * (5 * strcspn ("ECMP", *date_string)), in size_t arithmetic.
            var minutes = cInt((0 &- 60 as UInt64) &* (5 &* UInt64(s.strcspnECMP())))
            if s.at(s.i + 1) == 0x44 { minutes &+= 60 }
            offsetMinutes = minutes
            utc = false
        } else {
            return nil
        }
        return utc ? .utc : .offset(minutes: offsetMinutes)
    }

    /// g_date_valid_dmy (GLib gdate.c) with its guint8 day / guint16 year parameters.
    private static func gDateValidDMY(_ day: Int32, _ month: Int32, _ year: Int32) -> Bool {
        let d = Int(UInt8(truncatingIfNeeded: day))
        let m = Int(month)
        let y = Int(UInt16(truncatingIfNeeded: year))
        guard m > 0, m < 13, d > 0, y > 0 else { return false }
        return d <= daysInMonth(m, leap: isLeapYear(y))
    }

    private static func isLeapYear(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    private static func daysInMonth(_ m: Int, leap: Bool) -> Int {
        [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    }

    /// g_time_zone_new_offset (offset_minutes * 60) as the offset in seconds it really applies:
    /// GLib builds the identifier "+hh:mm:ss" and falls back to UTC when it cannot parse it,
    /// which happens when the hours exceed 24. Measured on Homebrew GLib 2.90.1 over every
    /// minute offset -6100...6100: exactly -1499...1499 minutes are kept, all others give 0.
    static func glibOffsetSeconds(minutes: Int32) -> Int64 {
        let seconds = Int64(minutes) * 60
        return abs(seconds) / 3600 <= 24 ? seconds : 0
    }

    /// g_date_time_new (tz, year, month, day, hour, minute, second) then g_date_time_to_unix.
    /// The field guards of g_date_time_new cannot fail after parse_textual_date's checks.
    private static func gDateTimeNewToUnix(_ tz: Zone, _ f: Fields) -> Int64? {
        let year = Int(f.year), month = Int(f.month), day = Int(f.day)
        guard year >= 1, year <= 9999, month >= 1, month <= 12, day >= 1,
              day <= daysInMonth(month, leap: isLeapYear(year)), f.hour >= 0, f.hour <= 23,
              f.minute >= 0, f.minute <= 59, f.second >= 0, f.second < 60
        else { return nil }
        let offset: Int64
        switch tz {
        case .utc: offset = 0
        case .offset(let minutes): offset = glibOffsetSeconds(minutes: minutes)
        }
        let local = daysFromCivil(year, month, day) * 86_400
            + Int64(f.hour) * 3600 + Int64(f.minute) * 60 + Int64(f.second)
        return local - offset
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (GLib ymd_to_days relative to
    /// the Unix epoch).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Int64(era * 146_097 + doe - 719_468)
    }

    /// A C int receiving an unsigned long (the implementation-defined conversion clang and gcc
    /// perform: keep the low 32 bits).
    private static func cInt(_ value: UInt64) -> Int32 { Int32(truncatingIfNeeded: value) }

    /// g_ascii_isspace: TAB, LF, FF, CR and SPACE (not VT; measured on GLib 2.90.1).
    private static func gAsciiIsSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D
    }
    private static func gAsciiIsAlpha(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
    private static func gAsciiIsDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }
    private static func gAsciiToLower(_ b: UInt8) -> UInt8 { (0x41...0x5A).contains(b) ? b + 0x20 : b }

    /// A C string read position: bytes past the first 0x00 (or past the end) read as 0x00.
    private struct Cursor {
        let t: [UInt8]
        var i = 0
        init(_ text: [UInt8]) { t = Array(text.prefix { $0 != 0 }) }
        var peek: UInt8 { at(i) }
        func at(_ k: Int) -> UInt8 { k < t.count ? t[k] : 0 }

        /// C isspace in the "C" locale, as strtoul uses it: TAB, LF, VT, FF, CR, SPACE.
        private func cIsSpace(_ b: UInt8) -> Bool { b == 0x20 || (0x09...0x0D).contains(b) }

        /// strtoul (text + start, &end, 10): leading blanks, an optional sign, decimal digits;
        /// overflow gives ULONG_MAX, a '-' negates in unsigned arithmetic; with no digits the
        /// value is 0 and end == start.
        func strtoul(from start: Int) -> (value: UInt64, end: Int) {
            var k = start
            while cIsSpace(at(k)) { k += 1 }
            var negative = false
            if at(k) == 0x2B || at(k) == 0x2D {
                negative = at(k) == 0x2D
                k += 1
            }
            guard (0x30...0x39).contains(at(k)) else { return (0, start) }
            var value: UInt64 = 0
            var overflow = false
            while (0x30...0x39).contains(at(k)) {
                let (m, o1) = value.multipliedReportingOverflow(by: 10)
                let (a, o2) = m.addingReportingOverflow(UInt64(at(k) - 0x30))
                if o1 || o2 { overflow = true }
                value = a
                k += 1
            }
            if overflow { return (UInt64.max, k) }
            return (negative ? 0 &- value : value, k)
        }

        /// strpbrk (text + i, set) != NULL.
        func strpbrk(_ set: String) -> Bool {
            let chars = Array(set.utf8)
            return t[min(i, t.count)...].contains { chars.contains($0) }
        }

        /// strcmp (text + i, literal) == 0.
        func restEquals(_ literal: String) -> Bool { t[min(i, t.count)...].elementsEqual(literal.utf8) }

        /// strcspn ("ECMP", text + i): how many leading letters of "ECMP" do not occur in the rest.
        func strcspnECMP() -> Int {
            let rest = t[min(i, t.count)...]
            var n = 0
            for c in "ECMP".utf8 {
                if rest.contains(c) { break }
                n += 1
            }
            return n
        }
    }
}
}
