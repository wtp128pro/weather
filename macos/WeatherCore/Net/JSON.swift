// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// JSON.swift - safe JSON access for untrusted response bodies. Port of
// src/net/wx-json.{h,c}.
//
// The C module runs a strict RFC 8259 gate over the body and then hands the
// text to json-glib. Here the gate is ported line for line (scan_document and
// its helpers, wx-json.c:21-459) and a small tree builder takes json-glib's
// place. The builder never sees text the gate refused. It keeps the parts of
// json-glib's behaviour that the C code relies on:
//  - an unpaired surrogate escape fails the whole document (wx-json.c:144-146);
//  - a number without '.', 'e' or 'E' is an integer node (Int64), anything
//    else is a double node; an integer literal that does not fit 64 bits
//    saturates to Int64.max / Int64.min (wx-json.h:157-159), and a double
//    literal that overflows becomes an infinity (wx-json.h:156-157);
//  - true/false are boolean nodes, never numbers.
// Foundation's JSONSerialization is deliberately not used: it reads `true` as
// 1, loses the integer/double distinction, tolerates a byte-order mark and
// keeps the last of repeated member names.
//
// Member names are compared as UTF-8 byte strings, like g_str_equal; Swift's
// String == (canonical equivalence) would merge names that C keeps apart.

/// Strict JSON parsing and range-checked access for untrusted response
/// bodies (port of src/net/wx-json.{h,c}).
public enum WxJSON {
    /// Deepest accepted nesting; the root container is level 1
    /// (WX_JSON_PARSE_MAX_DEPTH, wx-json.h:26).
    public static let maxDepth = 32
    /// Most members one object may have (WX_JSON_PARSE_MAX_MEMBERS, wx-json.h:34).
    public static let maxMembers = 1024
    /// Largest `maxChars` accepted by `errorReason` (WX_JSON_REASON_CHARS_MAX, wx-json.h:36).
    public static let reasonCharsMax = 1024

    /// The kind of root container `parse` requires (WxJsonRoot).
    public enum Root: Sendable {
        /// The JSON text must be one object.
        case object
        /// The JSON text must be one array.
        case array
    }

    /// One node of a parsed tree (json-glib JsonNode).
    public enum Node: Sendable, Equatable {
        case object(Object)
        case array([Node])
        case string(String)
        /// An integer literal (G_TYPE_INT64), saturated to Int64.max / Int64.min.
        case integer(Int64)
        /// A literal with a fraction or exponent (G_TYPE_DOUBLE); may be infinite.
        case double(Double)
        case bool(Bool)
        case null

        /// The object, or nil for any other kind.
        public var object: Object? {
            if case .object(let o) = self { return o }
            return nil
        }

        /// The array elements, or nil for any other kind.
        public var array: [Node]? {
            if case .array(let a) = self { return a }
            return nil
        }

        /// The string (possibly ""), or nil for any other kind; numbers and
        /// booleans are not converted. Unbounded and may hold control
        /// characters: sanitise before use.
        public var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        /// wx_json_node_number (wx-json.c:544-565): the value of an integer or
        /// double node when it is finite; nil for strings such as "12",
        /// booleans, null, containers, an infinite double and the saturated
        /// integers Int64.max / Int64.min.
        public var number: Double? {
            switch self {
            case .integer(let v):
                if v == Int64.max || v == Int64.min {
                    return nil
                }
                return Double(v)
            case .double(let d):
                return d.isFinite ? d : nil
            default:
                return nil
            }
        }

        /// wx_json_number_in_range (wx-json.c:578-586): `number` when it lies
        /// in [lo, hi] (both inclusive, WxLimits.valueInRange); nil otherwise
        /// (a NaN bound makes every value fail). Out-of-range values are
        /// dropped, never clamped.
        public func numberInRange(_ lo: Double, _ hi: Double) -> Double? {
            guard let v = number, WxLimits.valueInRange(v, lo, hi) else {
                return nil
            }
            return v
        }
    }

    /// A JSON object (json-glib JsonObject): member names are unique and kept
    /// in document order.
    public struct Object: Sendable, Equatable {
        /// Member names in document order.
        public let names: [String]
        private let members: [[UInt8]: Node]

        fileprivate init(names: [String], members: [[UInt8]: Node]) {
            self.names = names
            self.members = members
        }

        /// Number of members.
        public var count: Int { names.count }

        /// The member `name` (looked up by its UTF-8 bytes up to the first
        /// U+0000, like a C string key), or nil when missing.
        public func member(_ name: String) -> Node? {
            members[Array(name.utf8.prefix { $0 != 0 })]
        }

        /// wx_json_member_object: the member when it is an object, else nil.
        public func object(_ name: String) -> Object? { member(name)?.object }

        /// wx_json_member_array: the member when it is an array, else nil.
        public func array(_ name: String) -> [Node]? { member(name)?.array }

        /// wx_json_member_string: the member when it is a string, else nil.
        public func string(_ name: String) -> String? { member(name)?.string }

        /// wx_json_member_number: `Node.number` of the member, nil when missing.
        public func number(_ name: String) -> Double? { member(name)?.number }

        /// wx_json_error_reason (wx-json.c:590-599): for the keyless-API error
        /// shape {"error": true, "reason": "..."} the sanitised reason
        /// (WxText.sanitize to maxChars * 4 bytes, then WxText.truncatedCopy
        /// to maxChars scalars); "" when "reason" is missing, mistyped or
        /// empty after sanitising. nil when "error" is not the boolean true,
        /// and nil when `maxChars` is outside 1...reasonCharsMax (C: critical,
        /// NULL).
        public func errorReason(maxChars: Int) -> String? {
            guard maxChars >= 1 && maxChars <= WxJSON.reasonCharsMax else {
                return nil
            }
            guard case .bool(true) = member("error") else {
                return nil
            }
            let clean = WxText.sanitize(string("reason"), maxBytes: maxChars * 4)
            return WxText.truncatedCopy(clean, maxScalars: maxChars)
        }
    }

    // MARK: - Parsing

    /// wx_json_parse (wx-json.c:466-506): validates and parses an untrusted
    /// body. In this order: empty -> error; more than `maxLength` bytes ->
    /// error (before any byte is examined); invalid UTF-8 (an embedded 0x00
    /// included) -> error; not exactly one RFC 8259 value, nesting deeper
    /// than `maxDepth`, a repeated member name (compared after decoding
    /// escapes), more than `maxMembers` members in one object, or a "\u0000"
    /// escape -> error; an unpaired surrogate escape -> error; a root of the
    /// other kind -> error. Every error is `.parse` with a fixed message that
    /// never echoes the body.
    ///
    /// - Parameter maxLength: largest accepted byte count, 1...Int.max;
    ///   anything else throws `.invalidArg` (C: critical, NULL).
    /// - Returns: the root node, an `.object` or `.array` as `root` requires.
    public static func parse<Bytes: Collection<UInt8>>(
        _ data: Bytes, maxLength: Int, root: Root
    ) throws(WxError) -> Node {
        if maxLength < 1 {
            throw WxError(.invalidArg, "invalid maximum length")
        }
        let len = data.count
        if len == 0 {
            throw WxError(.parse, "empty response")
        }
        if len > maxLength {
            throw WxError(.parse, "response too large")
        }
        let bytes = Array(data)
        let built: Node?? = bytes.withUnsafeBufferPointer { buf -> Node?? in
            if !isValidUTF8(buf) {
                return .none
            }
            if !isStrictText(buf) {
                return .some(.none)
            }
            var builder = Builder(b: buf)
            return .some(builder.document())
        }
        guard let parsed = built else {
            throw WxError(.parse, "response is not valid UTF-8")
        }
        guard let node = parsed else {
            throw WxError(.parse, "malformed JSON")
        }
        switch (root, node) {
        case (.object, .object), (.array, .array):
            return node
        case (.object, _):
            throw WxError(.parse, "response is not a JSON object")
        case (.array, _):
            throw WxError(.parse, "response is not a JSON array")
        }
    }

    /// `parse(_:maxLength:root: .object)` returning the root object.
    public static func parseObject<Bytes: Collection<UInt8>>(
        _ data: Bytes, maxLength: Int
    ) throws(WxError) -> Object {
        guard let object = try parse(data, maxLength: maxLength, root: .object).object else {
            throw WxError(.parse, "response is not a JSON object")
        }
        return object
    }

    /// `parse(_:maxLength:root: .array)` returning the root array's elements.
    public static func parseArray<Bytes: Collection<UInt8>>(
        _ data: Bytes, maxLength: Int
    ) throws(WxError) -> [Node] {
        guard let array = try parse(data, maxLength: maxLength, root: .array).array else {
            throw WxError(.parse, "response is not a JSON array")
        }
        return array
    }

    // MARK: - UTF-8 validation (g_utf8_validate with an explicit length)

    /// True iff `b` is valid UTF-8 without a 0x00 byte: no stray or missing
    /// continuation byte, no overlong form, no surrogate (U+D800...U+DFFF),
    /// nothing above U+10FFFF. Noncharacters are valid (modern GLib).
    static func isValidUTF8(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c == 0 {
                return false
            }
            if c < 0x80 {
                i += 1
                continue
            }
            var need: Int
            var v: UInt32
            var min: UInt32
            if c & 0xE0 == 0xC0 {
                need = 1; v = UInt32(c & 0x1F); min = 0x80
            } else if c & 0xF0 == 0xE0 {
                need = 2; v = UInt32(c & 0x0F); min = 0x800
            } else if c & 0xF8 == 0xF0 {
                need = 3; v = UInt32(c & 0x07); min = 0x10000
            } else {
                return false
            }
            if n - i - 1 < need {
                return false
            }
            var k = 1
            while k <= need {
                let cc = b[i + k]
                if cc & 0xC0 != 0x80 {
                    return false
                }
                v = (v << 6) | UInt32(cc & 0x3F)
                k += 1
            }
            if v < min || v > 0x10FFFF || (v & 0xFFFF_F800) == 0xD800 {
                return false
            }
            i += need + 1
        }
        return true
    }

    // MARK: - Strict RFC 8259 gate (wx-json.c:17-459)

    /// json_text_is_strict (wx-json.c:448-459): true iff `text` (valid UTF-8)
    /// is exactly one RFC 8259 value nested at most `maxDepth` levels, without
    /// a repeated member name, with at most `maxMembers` members per object
    /// and without a "\u0000" escape. One linear pass; iterative.
    static func isStrictText(_ text: UnsafeBufferPointer<UInt8>) -> Bool {
        var c = Cursor(b: text, p: 0, end: text.count)
        var names = [Set<[UInt8]>?](repeating: nil, count: maxDepth)
        var scratch: [UInt8] = []
        return Gate.scanDocument(&c, &scratch, &names)
    }

    /// Read position inside the text being checked (wx-json.c:21-25).
    fileprivate struct Cursor {
        let b: UnsafeBufferPointer<UInt8>
        var p: Int
        let end: Int
    }

    /// The gate's scanners, one function per C function.
    private enum Gate {
        static func isWS(_ ch: UInt8) -> Bool {
            ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
        }

        static func isDigit(_ ch: UInt8) -> Bool { ch >= 0x30 && ch <= 0x39 }

        /// g_ascii_xdigit_value, or -1.
        static func hexValue(_ ch: UInt8) -> Int {
            switch ch {
            case 0x30...0x39: return Int(ch - 0x30)
            case 0x61...0x66: return Int(ch - 0x61) + 10
            case 0x41...0x46: return Int(ch - 0x41) + 10
            default: return -1
            }
        }

        /// skip_ws (wx-json.c:40-45).
        static func skipWS(_ c: inout Cursor) {
            while c.p < c.end && isWS(c.b[c.p]) {
                c.p += 1
            }
        }

        /// scan_hex4 (wx-json.c:63-74): four hex digits at `p` (4 readable bytes).
        static func scanHex4(_ b: UnsafeBufferPointer<UInt8>, _ p: Int) -> UInt32? {
            var v: UInt32 = 0
            for i in 0..<4 {
                let d = hexValue(b[p + i])
                if d < 0 {
                    return nil
                }
                v = v * 16 + UInt32(d)
            }
            return v
        }

        /// g_string_append_unichar.
        static func appendScalar(_ v: UInt32, _ out: inout [UInt8]) {
            if v < 0x80 {
                out.append(UInt8(v))
            } else if v < 0x800 {
                out.append(UInt8(0xC0 | (v >> 6)))
                out.append(UInt8(0x80 | (v & 0x3F)))
            } else if v < 0x10000 {
                out.append(UInt8(0xE0 | (v >> 12)))
                out.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (v & 0x3F)))
            } else {
                out.append(UInt8(0xF0 | (v >> 18)))
                out.append(UInt8(0x80 | ((v >> 12) & 0x3F)))
                out.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (v & 0x3F)))
            }
        }

        /// scan_string (wx-json.c:98-167): cursor at the opening quote; when
        /// `decode` is true the decoded text is appended to `out` (an unpaired
        /// surrogate decodes to U+FFFD, so the name comparison stays total).
        static func scanString(_ c: inout Cursor, _ decode: Bool, _ out: inout [UInt8]) -> Bool {
            c.p += 1
            while c.p < c.end {
                let ch = c.b[c.p]
                c.p += 1
                if ch == 0x22 {
                    return true
                }
                if ch < 0x20 {
                    return false
                }
                if ch != 0x5C {
                    if decode {
                        out.append(ch)
                    }
                    continue
                }
                if c.p >= c.end {
                    return false
                }
                let esc = c.b[c.p]
                c.p += 1
                let plain: UInt8
                switch esc {
                case 0x22, 0x5C, 0x2F: plain = esc
                case 0x62: plain = 0x08  // b
                case 0x66: plain = 0x0C  // f
                case 0x6E: plain = 0x0A  // n
                case 0x72: plain = 0x0D  // r
                case 0x74: plain = 0x09  // t
                case 0x75:  // u
                    guard c.end - c.p >= 4, var v = scanHex4(c.b, c.p), v != 0 else {
                        return false
                    }
                    c.p += 4
                    if v >= 0xD800 && v <= 0xDFFF {
                        if v <= 0xDBFF && c.end - c.p >= 6 && c.b[c.p] == 0x5C && c.b[c.p + 1] == 0x75,
                            let low = scanHex4(c.b, c.p + 2), low >= 0xDC00 && low <= 0xDFFF
                        {
                            c.p += 6
                            v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            v = 0xFFFD
                        }
                    }
                    if decode {
                        appendScalar(v, &out)
                    }
                    continue
                default:
                    return false
                }
                if decode {
                    out.append(plain)
                }
            }
            return false
        }

        /// scan_digits (wx-json.c:184-191).
        static func scanDigits(_ c: inout Cursor) -> Bool {
            let start = c.p
            while c.p < c.end && isDigit(c.b[c.p]) {
                c.p += 1
            }
            return c.p > start
        }

        /// scan_number (wx-json.c:210-232): -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
        static func scanNumber(_ c: inout Cursor) -> Bool {
            if c.b[c.p] == 0x2D {
                c.p += 1
            }
            if c.p < c.end && c.b[c.p] == 0x30 {
                c.p += 1
            } else if !scanDigits(&c) {
                return false
            }
            if c.p < c.end && c.b[c.p] == 0x2E {
                c.p += 1
                if !scanDigits(&c) {
                    return false
                }
            }
            if c.p < c.end && (c.b[c.p] == 0x65 || c.b[c.p] == 0x45) {
                c.p += 1
                if c.p < c.end && (c.b[c.p] == 0x2B || c.b[c.p] == 0x2D) {
                    c.p += 1
                }
                if !scanDigits(&c) {
                    return false
                }
            }
            return true
        }

        /// scan_literal (wx-json.c:250-258).
        static func scanLiteral(_ c: inout Cursor, _ word: StaticString) -> Bool {
            let n = word.utf8CodeUnitCount
            if c.end - c.p < n {
                return false
            }
            let w = word.utf8Start
            for i in 0..<n where c.b[c.p + i] != w[i] {
                return false
            }
            c.p += n
            return true
        }

        /// member_name_add (wx-json.c:283-292).
        static func memberNameAdd(_ names: inout Set<[UInt8]>?, _ name: [UInt8]) -> Bool {
            if names == nil {
                names = Set()
            }
            if names!.count >= WxJSON.maxMembers || names!.contains(name) {
                return false
            }
            names!.insert(name)
            return true
        }

        /// scan_key (wx-json.c:313-327): `ws "name" ws :`, recording the name.
        static func scanKey(_ c: inout Cursor, _ scratch: inout [UInt8], _ names: inout Set<[UInt8]>?) -> Bool {
            skipWS(&c)
            if c.p >= c.end || c.b[c.p] != 0x22 {
                return false
            }
            scratch.removeAll(keepingCapacity: true)
            if !scanString(&c, true, &scratch) || !memberNameAdd(&names, scratch) {
                return false
            }
            skipWS(&c)
            if c.p >= c.end || c.b[c.p] != 0x3A {
                return false
            }
            c.p += 1
            return true
        }

        /// scan_document (wx-json.c:351-429).
        static func scanDocument(_ c: inout Cursor, _ scratch: inout [UInt8], _ names: inout [Set<[UInt8]>?]) -> Bool {
            var isObject: UInt32 = 0  // bit (level - 1) set: that open container is an object
            var depth = 0
            var unused: [UInt8] = []

            while true {
                // A value starts here.
                skipWS(&c)
                if c.p >= c.end {
                    return false
                }
                var complete = true  // false: a container was opened and has content
                switch c.b[c.p] {
                case 0x7B, 0x5B:  // { [
                    let object = c.b[c.p] == 0x7B
                    if depth == WxJSON.maxDepth {
                        return false
                    }
                    depth += 1
                    let bit = UInt32(1) << UInt32(depth - 1)
                    isObject = object ? (isObject | bit) : (isObject & ~bit)
                    c.p += 1
                    skipWS(&c)
                    if c.p < c.end && c.b[c.p] == (object ? 0x7D : 0x5D) {
                        c.p += 1
                        depth -= 1
                    } else {
                        complete = false
                        if object && !scanKey(&c, &scratch, &names[depth - 1]) {
                            return false
                        }
                    }
                case 0x22:
                    if !scanString(&c, false, &unused) {
                        return false
                    }
                case 0x74:
                    if !scanLiteral(&c, "true") {
                        return false
                    }
                case 0x66:
                    if !scanLiteral(&c, "false") {
                        return false
                    }
                case 0x6E:
                    if !scanLiteral(&c, "null") {
                        return false
                    }
                default:
                    if !(c.b[c.p] == 0x2D || isDigit(c.b[c.p])) || !scanNumber(&c) {
                        return false
                    }
                }
                if !complete {
                    continue
                }

                // A value is complete: close containers and read the next separator.
                while true {
                    skipWS(&c)
                    if depth == 0 {
                        return c.p == c.end
                    }
                    if c.p >= c.end {
                        return false
                    }
                    let object = (isObject >> UInt32(depth - 1)) & 1 == 1
                    if c.b[c.p] == 0x2C {
                        c.p += 1
                        if object && !scanKey(&c, &scratch, &names[depth - 1]) {
                            return false
                        }
                        break  // the next member value starts
                    }
                    if c.b[c.p] != (object ? 0x7D : 0x5D) {
                        return false
                    }
                    c.p += 1
                    names[depth - 1] = nil  // the object is closed
                    depth -= 1
                }
            }
        }
    }

    // MARK: - Tree builder (the json-glib step)

    /// Builds the tree of a text the gate accepted. Recursion is bounded by
    /// `maxDepth`. Returns nil only for an unpaired surrogate escape, which
    /// json-glib refuses (wx-json.c:144-146).
    private struct Builder {
        let b: UnsafeBufferPointer<UInt8>
        var p = 0

        init(b: UnsafeBufferPointer<UInt8>) {
            self.b = b
        }

        mutating func skipWS() {
            while p < b.count && Gate.isWS(b[p]) {
                p += 1
            }
        }

        mutating func document() -> Node? {
            skipWS()
            return value()
        }

        mutating func value() -> Node? {
            switch b[p] {
            case 0x7B:
                p += 1
                skipWS()
                var names: [String] = []
                var members: [[UInt8]: Node] = [:]
                if b[p] == 0x7D {
                    p += 1
                    return .object(Object(names: names, members: members))
                }
                while true {
                    skipWS()
                    guard let key = stringBytes() else { return nil }
                    skipWS()
                    p += 1  // ':'
                    skipWS()
                    guard let v = value() else { return nil }
                    names.append(String(decoding: key, as: UTF8.self))
                    members[key] = v
                    skipWS()
                    let sep = b[p]
                    p += 1
                    if sep == 0x7D {
                        return .object(Object(names: names, members: members))
                    }
                }
            case 0x5B:
                p += 1
                skipWS()
                var elements: [Node] = []
                if b[p] == 0x5D {
                    p += 1
                    return .array(elements)
                }
                while true {
                    skipWS()
                    guard let v = value() else { return nil }
                    elements.append(v)
                    skipWS()
                    let sep = b[p]
                    p += 1
                    if sep == 0x5D {
                        return .array(elements)
                    }
                }
            case 0x22:
                guard let s = stringBytes() else { return nil }
                return .string(String(decoding: s, as: UTF8.self))
            case 0x74:
                p += 4
                return .bool(true)
            case 0x66:
                p += 5
                return .bool(false)
            case 0x6E:
                p += 4
                return .null
            default:
                return number()
            }
        }

        /// The decoded bytes of the string at `p` (an opening quote); nil for
        /// an escape that is a surrogate not part of a high-low pair.
        mutating func stringBytes() -> [UInt8]? {
            p += 1
            var out: [UInt8] = []
            while true {
                let ch = b[p]
                p += 1
                if ch == 0x22 {
                    return out
                }
                if ch != 0x5C {
                    out.append(ch)
                    continue
                }
                let esc = b[p]
                p += 1
                switch esc {
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    var v = Gate.scanHex4(b, p)!
                    p += 4
                    if v >= 0xD800 && v <= 0xDFFF {
                        guard v <= 0xDBFF, b.count - p >= 6, b[p] == 0x5C, b[p + 1] == 0x75,
                            let low = Gate.scanHex4(b, p + 2), low >= 0xDC00 && low <= 0xDFFF
                        else {
                            return nil
                        }
                        p += 6
                        v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                    }
                    Gate.appendScalar(v, &out)
                default: out.append(esc)  // " \ /
                }
            }
        }

        /// A number node: integer when the lexeme has no '.', 'e' or 'E'
        /// (saturated to Int64.max / Int64.min), double otherwise.
        mutating func number() -> Node? {
            let start = p
            var isDouble = false
            while p < b.count {
                let ch = b[p]
                if ch == 0x2E || ch == 0x65 || ch == 0x45 {
                    isDouble = true
                } else if !(Gate.isDigit(ch) || ch == 0x2D || ch == 0x2B) {
                    break
                }
                p += 1
            }
            if isDouble {
                let text = String(decoding: UnsafeBufferPointer(rebasing: b[start..<p]), as: UTF8.self)
                guard let d = Double(text) else { return nil }
                return .double(d)
            }
            var i = start
            let negative = b[i] == 0x2D
            if negative {
                i += 1
            }
            var magnitude: UInt64 = 0
            var overflow = false
            while i < p {
                let (m, o1) = magnitude.multipliedReportingOverflow(by: 10)
                let (s, o2) = m.addingReportingOverflow(UInt64(b[i] - 0x30))
                if o1 || o2 {
                    overflow = true
                    break
                }
                magnitude = s
                i += 1
            }
            if negative {
                if overflow || magnitude > UInt64(Int64.max) + 1 {
                    return .integer(Int64.min)
                }
                return .integer(magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude))
            }
            if overflow || magnitude > UInt64(Int64.max) {
                return .integer(Int64.max)
            }
            return .integer(Int64(magnitude))
        }
    }
}
