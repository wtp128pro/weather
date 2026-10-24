// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SourceStatus.swift - the per-source outcome shown in the "Sources" UI. Port
// of WxSourceState and WxSourceStatus with the strict https attribution-link
// validator (src/core/wx-types.h:668-769, src/core/wx-types.c:648-1022).
//
// Text arguments are read like C strings (up to the first 0x00 byte; nil is
// NULL). name and attribution are DISPLAY text, passed through
// WxText.sanitize(bytes:maxBytes:) with WxLimits.sourceTextMax. The
// attribution URL is either "" or a strictly checked https URL; a URL is
// rejected, never repaired. The C validator ends with g_uri_parse() as
// defence in depth; after the strict grammar has accepted a URL, the only
// further thing g_uri_parse() can refuse is a path, query or fragment whose
// percent escapes decode to invalid UTF-8 or to a NUL byte, which is what
// `glibDecodesCleanly` checks (each component separately, as GLib does).

/// Outcome of one source for one refresh (WxSourceState). `rawValue` is the
/// C ordinal persisted by the forecast cache ("state").
public enum WxSourceState: Int, CaseIterable, Sendable {
    case ok = 0
    case failed = 1
    /// Not covering the place, or disabled.
    case skipped = 2
}

/// Per-source status (WxSourceStatus). Always valid: every initialiser
/// validates and sanitises like wx_source_status_new.
public struct WxSourceStatus: Equatable, Hashable, Sendable {
    /// Provider id, `WxLimits.isValidID`.
    public let providerID: String
    /// Sanitised display name (at most `WxLimits.sourceTextMax` bytes).
    public let name: String
    /// Sanitised attribution text (at most `WxLimits.sourceTextMax` bytes).
    public let attribution: String
    /// "" or a strictly checked https URL of at most `WxLimits.sourceURLMax`
    /// bytes (still escape it before embedding it in markup).
    public let attributionURL: String
    public let state: WxSourceState
    /// The source's error, or nil for C's -1 ("no error").
    public let errorCode: WxError.Code?
    /// Number of members the source contributed (a C guint).
    public let nMembers: UInt32

    /// The C `error_code`: `errorCode?.rawValue`, or -1 when there is none
    /// (the value the forecast cache stores as "error").
    public var errorCodeOrdinal: Int { errorCode?.rawValue ?? -1 }

    /// wx_source_status_new (src/core/wx-types.c:993-1002) with typed state
    /// and error code.
    ///
    /// - Throws: `WxError.Code.invalidArg` with "invalid provider id" or
    ///   "invalid attribution URL"; the message never contains input text.
    public init(
        providerID: String?, name: String?, attribution: String?, attributionURL: String?,
        state: WxSourceState, errorCode: WxError.Code?, nMembers: UInt32
    ) throws(WxError) {
        try self.init(
            providerIDBytes: providerID.map { Array($0.utf8) },
            nameBytes: name.map { Array($0.utf8) },
            attributionBytes: attribution.map { Array($0.utf8) },
            attributionURLBytes: attributionURL.map { Array($0.utf8) },
            stateOrdinal: state.rawValue, errorCodeOrdinal: errorCode?.rawValue ?? -1,
            nMembers: nMembers)
    }

    /// wx_source_status_new over raw bytes and the C integer ordinals (what
    /// the forecast cache stores). Checks, in the C order
    /// (status_init, src/core/wx-types.c:941-970): the provider id ("invalid
    /// provider id"), the state 0...2 ("invalid source state"), the error
    /// code -1 or 0...7 ("invalid source error code"), the attribution URL
    /// ("invalid attribution URL"); every failure is `.invalidArg`.
    public init(
        providerIDBytes: [UInt8]?, nameBytes: [UInt8]?, attributionBytes: [UInt8]?,
        attributionURLBytes: [UInt8]?, stateOrdinal: Int, errorCodeOrdinal: Int, nMembers: UInt32
    ) throws(WxError) {
        guard let providerIDBytes, WxLimits.isValidID(bytes: providerIDBytes) else {
            throw WxError(.invalidArg, "invalid provider id")
        }
        guard let state = WxSourceState(rawValue: stateOrdinal) else {
            throw WxError(.invalidArg, "invalid source state")
        }
        let errorCode: WxError.Code?
        if errorCodeOrdinal == -1 {
            errorCode = nil
        } else if let code = WxError.Code(rawValue: errorCodeOrdinal) {
            errorCode = code
        } else {
            throw WxError(.invalidArg, "invalid source error code")
        }
        guard Self.isValidAttributionURL(bytes: attributionURLBytes) else {
            throw WxError(.invalidArg, "invalid attribution URL")
        }
        self.providerID = Self.cString(providerIDBytes)
        self.name = WxText.sanitize(bytes: nameBytes ?? [], maxBytes: WxLimits.sourceTextMax)
        self.attribution = WxText.sanitize(
            bytes: attributionBytes ?? [], maxBytes: WxLimits.sourceTextMax)
        self.attributionURL = attributionURLBytes.map(Self.cString) ?? ""
        self.state = state
        self.errorCode = errorCode
        self.nMembers = nMembers
    }

    /// wx_source_status_copy (src/core/wx-types.c:1006-1012): a copy that is
    /// re-validated and re-sanitised like a new status.
    public func copy() throws(WxError) -> WxSourceStatus {
        try WxSourceStatus(
            providerIDBytes: Array(providerID.utf8), nameBytes: Array(name.utf8),
            attributionBytes: Array(attribution.utf8),
            attributionURLBytes: Array(attributionURL.utf8), stateOrdinal: state.rawValue,
            errorCodeOrdinal: errorCodeOrdinal, nMembers: nMembers)
    }

    // MARK: - Attribution URL (attribution_url_ok, src/core/wx-types.c:870-916)

    /// Whether `bytes` is an acceptable attribution link: nil, "" (the text
    /// before the first 0x00 is empty) or a strict "https://" URL of at most
    /// `WxLimits.sourceURLMax` bytes. At most sourceURLMax + 1 bytes are
    /// looked at to find the end of the text.
    static func isValidAttributionURL(bytes: [UInt8]?) -> Bool {
        guard let url = bytes else {
            return true
        }
        let scanLimit = Swift.min(url.count, WxLimits.sourceURLMax + 1)
        let nul: Int
        if let zero = url[..<scanLimit].firstIndex(of: 0) {
            nul = zero
        } else if url.count <= WxLimits.sourceURLMax {
            nul = url.count  // the implicit terminator of a Swift buffer
        } else {
            return false
        }
        if nul == 0 {
            return true
        }
        let prefix: [UInt8] = Array("https://".utf8)
        if nul <= prefix.count || !url[0..<prefix.count].elementsEqual(prefix) {
            return false
        }
        // byte(i) mirrors reading the C string: the terminator past `nul`.
        func byte(_ i: Int) -> UInt8 { i < nul ? url[i] : 0 }

        let auth = prefix.count
        var authEnd = auth
        while authEnd < nul, url[authEnd] != 0x2F, url[authEnd] != 0x3F, url[authEnd] != 0x23 {
            authEnd += 1  // strcspn(auth, "/?#")
        }
        var portText: Int? = nil
        if byte(auth) == 0x5B {  // '['
            guard let bracketEnd = url[auth..<authEnd].firstIndex(of: 0x5D),
                Self.ipv6LiteralOK(Array(url[(auth + 1)..<bracketEnd]))
            else {
                return false
            }
            if bracketEnd + 1 < authEnd {
                if url[bracketEnd + 1] != 0x3A {
                    return false
                }
                portText = bracketEnd + 2
            }
        } else {
            let colon = url[auth..<authEnd].firstIndex(of: 0x3A)
            if !Self.dnsHostOK(url[auth..<(colon ?? authEnd)]) {
                return false
            }
            if let colon {
                portText = colon + 1
            }
        }
        // g_uri_get_port() parses the same digits, so its port always equals
        // the one checked here (-1 when there is none).
        if let portText, Self.portValue(url[portText..<authEnd]) == nil {
            return false
        }
        let tail = url[authEnd..<nul]
        return Self.urlTailOK(tail) && Self.glibDecodesCleanly(tail)
    }

    /// ipv4_ok (src/core/wx-types.c:671-692): exactly four octets of 1...3
    /// digits, value 0...255, no leading zero, no empty octet.
    private static func ipv4OK(_ s: ArraySlice<UInt8>) -> Bool {
        let end = s.endIndex
        var p = s.startIndex
        var octets = 0
        while true {
            let start = p
            var v = 0
            while p < end, isDigit(s[p]), p - start < 3 {
                v = v * 10 + Int(s[p] - 0x30)
                p += 1
            }
            let digits = p - start
            if digits == 0 || v > 255 || (digits > 1 && s[start] == 0x30) {
                return false
            }
            octets += 1
            if p == end {
                return octets == 4
            }
            if s[p] != 0x2E || octets == 4 {
                return false
            }
            p += 1
        }
    }

    /// dns_host_ok (src/core/wx-types.c:713-739): 1...253 bytes, labels of
    /// 1...63 bytes of [A-Za-z0-9-] not starting or ending with '-'; an
    /// all-digit last label requires a strict dotted-decimal IPv4 address.
    private static func dnsHostOK(_ host: ArraySlice<UInt8>) -> Bool {
        let len = host.count
        if len == 0 || len > 253 {
            return false
        }
        let h = Array(host)
        var labelStart = 0
        for i in 0...len {
            if i < len && h[i] != 0x2E {
                if !isAlnum(h[i]) && h[i] != 0x2D {
                    return false
                }
                continue
            }
            let labelLen = i - labelStart
            if labelLen == 0 || labelLen > 63 || h[labelStart] == 0x2D || h[i - 1] == 0x2D {
                return false
            }
            labelStart = i + 1
        }
        var last = len
        while last > 0 && h[last - 1] != 0x2E {
            last -= 1
        }
        for i in last..<len where !isDigit(h[i]) {
            return true  // the last label has a non-digit: an ordinary name
        }
        return ipv4OK(h[...])
    }

    /// ipv6_literal_ok (src/core/wx-types.c:758-774): 2...45 bytes of hex
    /// digits, ':' and '.', at least one ':', and g_hostname_is_ip_address().
    private static func ipv6LiteralOK(_ s: [UInt8]) -> Bool {
        if s.count < 2 || s.count > 45 {
            return false
        }
        var colon = false
        for c in s {
            if c == 0x3A {
                colon = true
            } else if !isXDigit(c) && c != 0x2E {
                return false
            }
        }
        return colon && glibIsIPAddress(s)
    }

    /// GLib's g_hostname_is_ip_address() (glib/ghostutils.c), for text
    /// without NUL bytes: eight 1...4-hex-digit segments, one "::" run
    /// allowed, an optional trailing dotted-quad (no leading zeros), or a
    /// plain dotted-quad when there is no ':'.
    private static func glibIsIPAddress(_ s: [UInt8]) -> Bool {
        func at(_ i: Int) -> UInt8 { i < s.count ? s[i] : 0 }
        var p = 0
        if s.contains(0x3A) {
            var nsegments = 0
            var skipped = false
            var toIPv4 = false
            while at(p) != 0 && at(p) != 0x25 && nsegments < 8 {
                if p != 0 || (at(0) == 0x3A && at(1) == 0x3A) {
                    if at(p) != 0x3A {
                        return false
                    }
                    p += 1
                }
                if at(p) == 0x3A && !skipped {
                    skipped = true
                    nsegments += 1
                    if at(p + 1) == 0 {
                        p += 1
                    }
                    continue
                }
                var end = p
                while isXDigit(at(end)) {
                    end += 1
                }
                if end == p || end > p + 4 {
                    return false
                }
                if at(end) == 0x2E {
                    if (nsegments == 6 && !skipped) || (nsegments <= 6 && skipped) {
                        toIPv4 = true
                        break
                    }
                    return false
                }
                nsegments += 1
                p = end
            }
            if !toIPv4 {
                return (at(p) == 0 || (at(p) == 0x25 && at(p + 1) != 0))
                    && (nsegments == 8 || skipped)
            }
        }
        for n in 0..<4 {
            if n != 0 {
                if at(p) != 0x2E {
                    return false
                }
                p += 1
            }
            var octet = 0
            var end: Int
            if at(p) == 0x30 {
                end = p + 1
            } else {
                end = p
                while isDigit(at(end)) {
                    octet = 10 * octet + Int(at(end) - 0x30)
                    if octet > 255 {
                        break
                    }
                    end += 1
                }
            }
            if end == p || end > p + 3 || octet > 255 {
                return false
            }
            p = end
        }
        return at(p) == 0
    }

    /// port_ok (src/core/wx-types.c:791-806): 1...5 digits, no leading zero,
    /// 1...65535. Returns the value, or nil.
    private static func portValue(_ s: ArraySlice<UInt8>) -> Int? {
        if s.isEmpty || s.count > 5 || s.first == 0x30 {
            return nil
        }
        var v = 0
        for c in s {
            if !isDigit(c) {
                return nil
            }
            v = v * 10 + Int(c - 0x30)
        }
        return v > 65535 ? nil : v
    }

    /// url_tail_ok (src/core/wx-types.c:826-846): unreserved characters,
    /// sub-delimiters, ':', '@', '/', '?', well-formed percent escapes and at
    /// most one '#'.
    private static func urlTailOK(_ tail: ArraySlice<UInt8>) -> Bool {
        let allowed = Array("-._~!$&'()*+,;=:@/?".utf8)
        var inFragment = false
        var p = tail.startIndex
        let end = tail.endIndex
        while p < end {
            let c = tail[p]
            if c == 0x25 {
                if end - p < 3 || !isXDigit(tail[p + 1]) || !isXDigit(tail[p + 2]) {
                    return false
                }
                p += 2
            } else if c == 0x23 {
                if inFragment {
                    return false
                }
                inFragment = true
            } else if !isAlnum(c) && !allowed.contains(c) {
                return false
            }
            p += 1
        }
        return true
    }

    /// The g_uri_parse(G_URI_FLAGS_NONE) part of the C check that the strict
    /// grammar leaves open: the path, the query (after the first '?' before
    /// any '#') and the fragment (after the first '#') are each percent-
    /// decoded and must be valid UTF-8 without a NUL byte. `tail` has passed
    /// `urlTailOK`, so every '%' starts a well-formed escape.
    private static func glibDecodesCleanly(_ tail: ArraySlice<UInt8>) -> Bool {
        let hash = tail.firstIndex(of: 0x23) ?? tail.endIndex
        let question = tail[..<hash].firstIndex(of: 0x3F) ?? hash
        let components = [
            tail[tail.startIndex..<question],
            question < hash ? tail[(question + 1)..<hash] : tail[hash..<hash],
            hash < tail.endIndex ? tail[(hash + 1)...] : tail[hash..<hash],
        ]
        for component in components {
            var decoded: [UInt8] = []
            var p = component.startIndex
            while p < component.endIndex {
                if component[p] == 0x25 {
                    decoded.append(hexValue(component[p + 1]) << 4 | hexValue(component[p + 2]))
                    p += 3
                } else {
                    decoded.append(component[p])
                    p += 1
                }
            }
            if decoded.contains(0) {
                return false
            }
            // Valid UTF-8 (no overlongs, surrogates or values above U+10FFFF)
            // is exactly the input that decodes without a replacement.
            if !Array(String(decoding: decoded, as: UTF8.self).utf8).elementsEqual(decoded) {
                return false
            }
        }
        return true
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isAlnum(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isXDigit(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    private static func hexValue(_ c: UInt8) -> UInt8 {
        isDigit(c) ? c - 0x30 : (c | 0x20) - 0x61 + 10
    }

    /// The C string held by `bytes`: everything before the first 0x00.
    private static func cString(_ bytes: [UInt8]) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
