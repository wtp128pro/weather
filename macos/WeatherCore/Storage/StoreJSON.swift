// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StoreJSON.swift - the load pipeline, the JSON node readers and the place
// reader/writer shared by WxPlaces, WxSettings and the forecast cache; a port
// of src/storage/wx-store-json.{h,c}.
//
// The C loaders run wx_json_check_strict (StrictJSON.check) over the raw file
// and then hand the text to json-glib. json-glib is not available here, so a
// small tree builder (StoreJSON.Document) takes its place. It only ever sees
// text the gate accepted, and it keeps the parts of json-glib's behaviour the
// storage code relies on:
//  - the whole text must be valid UTF-8, else the document is refused
//    (json-glib's json_parser_load validates the input first);
//  - a number without '.', 'e' or 'E' is an integer node (Int64); anything
//    else is a double node ("1.0" and "1e0" are not integers,
//    src/storage/wx-store-json.h:98-99). An integer literal that does not fit
//    64 bits saturates to Int64.max / Int64.min (json-glib behaviour as
//    documented in src/net/wx-json.h:156-159); a double literal that overflows
//    becomes an infinity, which the number reader refuses;
//  - true/false are booleans, null is null; nothing else is a literal;
//  - a repeated member name keeps the LAST value (json_object_set_member
//    replaces the member);
//  - member names and string values are compared as UTF-8 bytes (g_str_equal),
//    never with Swift's String == (canonical equivalence);
//  - an unpaired UTF-16 surrogate escape refuses the whole document;
//  - trailing commas, missing separators, trailing values after the root and
//    malformed numbers are parse errors (RFC 8259 grammar).
// Foundation's JSONSerialization/JSONDecoder are deliberately not used: they
// lose the integer/double distinction (version must be the INTEGER 1), read
// `true` as 1 and mis-round some 17-digit doubles.
//
// Module-internal except for WxStoreError: nothing outside WeatherCore needs
// the readers.

import Foundation

/// The error of a store load or save (places, settings, cache). Mirrors the
/// GError domains and codes of the C module.
public enum WxStoreError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The file could not be read or written (C: G_FILE_ERROR codes, including
    /// G_FILE_ERROR_NOENT for a missing file - see `isNotFound` - and
    /// G_IO_ERROR_MESSAGE_TOO_LARGE above the size limit).
    case file(FileIOError)
    /// The text is not strict JSON, nested deeper than 32, or not the
    /// expected shape or version (C: WX_ERROR / WX_ERROR_PARSE). The message
    /// starts with the document name ("places: ...").
    case parse(String)
    /// An asynchronous save of the same object is running
    /// (C: G_IO_ERROR / G_IO_ERROR_PENDING,
    /// "<what>: an asynchronous save is running").
    case pending(String)
    /// The asynchronous save was cancelled before the write started
    /// (C: G_IO_ERROR / G_IO_ERROR_CANCELLED).
    case cancelled

    /// Human-readable description in the C wording.
    public var message: String {
        switch self {
        case .file(let error):
            error.message
        case .parse(let text), .pending(let text):
            text
        case .cancelled:
            "Operation was cancelled"
        }
    }

    /// True for a missing file (normal on first run; C: G_FILE_ERROR_NOENT).
    public var isNotFound: Bool {
        if case .file(let error) = self {
            return error.isNotFound
        }
        return false
    }

    public var description: String { message }

    public var errorDescription: String? { message }
}

/// The shared loader pieces of the storage module (wx-store-json.{h,c}).
enum StoreJSON {
    // MARK: - Tree

    /// One JSON value of a parsed store document (a json-glib JsonNode).
    indirect enum Node: Sendable {
        case null
        case bool(Bool)
        /// An integer token (no '.', 'e' or 'E'), saturated to 64 bits.
        case int(Int64)
        /// A number token with a fraction or an exponent.
        case double(Double)
        /// A string value as UTF-8 bytes (never contains 0x00).
        case string([UInt8])
        case array([Node])
        case object(Object)
    }

    /// A JSON object: members in file order (a JsonObject).
    struct Object: Sendable {
        /// One member; names are UTF-8 bytes.
        struct Member: Sendable {
            let name: [UInt8]
            let value: Node
        }

        /// The members in file order, repeated names included.
        let members: [Member]

        /// The value of member `name`, or nil if absent. A repeated name
        /// yields its last value (json_object_set_member replaces).
        func member(_ name: String) -> Node? {
            let key = Array(name.utf8)
            for m in members.reversed() where m.name == key {
                return m.value
            }
            return nil
        }
    }

    // MARK: - Load pipeline

    /// The common start of every loader (wx_store_load_json,
    /// src/storage/wx-store-json.c:11-39): removes stale temporary files next
    /// to `path`, reads at most `maxBytes` bytes, runs the strict gate with
    /// depth 32 BEFORE the parser sees the bytes, and parses the text.
    /// Blocking file I/O.
    ///
    /// Returns the root node; nil when the text holds no value at all (only
    /// whitespace), which `rootObject` reports as "not an object".
    /// Throws `.file` for I/O failures (NOENT, too large, not a regular
    /// file, errno), `.parse` for refused or malformed text.
    static func load(path: String, maxBytes: Int, what: String) throws(WxStoreError) -> Node? {
        FileIO.removeStaleTemps(path: path)
        let data: Data
        do {
            data = try FileIO.readBounded(path: path, maxBytes: maxBytes)
        } catch {
            throw .file(error)
        }
        guard StrictJSON.check(data) else {
            throw .parse(StrictJSON.rejectionMessage(what))
        }
        switch Document.parse(Array(data)) {
        case .success(let root):
            return root
        case .failure(let reason):
            throw .parse("\(what): \(reason.text)")
        }
    }

    /// Checks that `root` is an object whose "version" member is the integer
    /// `version` (wx_store_root_object, src/storage/wx-store-json.c:41-61).
    /// Messages: "<what>: top level is not an object",
    /// "<what>: missing or invalid version", "<what>: unsupported version N".
    static func rootObject(_ root: Node?, what: String, version: Int64) throws(WxStoreError) -> Object {
        guard let obj = nodeObject(root) else {
            throw .parse("\(what): top level is not an object")
        }
        guard let found = nodeI64(obj.member("version")) else {
            throw .parse("\(what): missing or invalid version")
        }
        guard found == version else {
            throw .parse("\(what): unsupported version \(found)")
        }
        return obj
    }

    // MARK: - Node readers (src/storage/wx-store-json.c:63-123)

    /// The integer of an integer node; nil for every other node, including
    /// numbers written with a fraction or exponent (wx_store_node_i64).
    static func nodeI64(_ n: Node?) -> Int64? {
        if case .int(let v)? = n {
            return v
        }
        return nil
    }

    /// A finite number (integer or double node), or NaN for null when
    /// `allowNull`; nil otherwise (wx_store_node_double).
    static func nodeDouble(_ n: Node?, allowNull: Bool) -> Double? {
        switch n {
        case .null?:
            return allowNull ? .nan : nil
        case .int(let v)?:
            return Double(v) // json_node_get_double of an int node: (double) value
        case .double(let v)?:
            return v.isFinite ? v : nil
        default:
            return nil
        }
    }

    /// The value of a boolean node (wx_store_node_bool).
    static func nodeBool(_ n: Node?) -> Bool? {
        if case .bool(let v)? = n {
            return v
        }
        return nil
    }

    /// The UTF-8 bytes of a string node; nil for anything else, null included
    /// (wx_store_node_string).
    static func nodeString(_ n: Node?) -> [UInt8]? {
        if case .string(let v)? = n {
            return v
        }
        return nil
    }

    /// The object of an object node (wx_store_node_object).
    static func nodeObject(_ n: Node?) -> Object? {
        if case .object(let v)? = n {
            return v
        }
        return nil
    }

    /// The elements of an array node (wx_store_node_array).
    static func nodeArray(_ n: Node?) -> [Node]? {
        if case .array(let v)? = n {
            return v
        }
        return nil
    }

    /// The error reported while an asynchronous save runs
    /// (wx_store_pending_error, src/storage/wx-store-json.c:125-130).
    static func pendingError(_ what: String) -> WxStoreError {
        .pending("\(what): an asynchronous save is running")
    }

    // MARK: - Places

    /// Builds a place from the object written by `appendPlace`
    /// (wx_store_place_from_json, src/storage/wx-store-json.c:132-179).
    /// Absent optional members (admin1, country, country_code, timezone) are
    /// ""; a present member of the wrong type, a missing name, lat or lon, a
    /// null or non-finite coordinate, or any WxPlace rule violated rejects the
    /// element (nil).
    static func placeFromJSON(_ node: Node?) -> WxPlace? {
        guard let o = nodeObject(node), let name = nodeString(o.member("name")),
              let admin1 = optionalString(o, "admin1"), let country = optionalString(o, "country"),
              let code = optionalString(o, "country_code"), let tz = optionalString(o, "timezone"),
              let lat = nodeDouble(o.member("lat"), allowNull: false),
              let lon = nodeDouble(o.member("lon"), allowNull: false)
        else {
            return nil
        }
        guard var place = try? WxPlace(
            nameBytes: name, admin1Bytes: admin1, countryBytes: country, countryCodeBytes: code,
            lat: lat, lon: lon, timezoneBytes: tz)
        else {
            return nil
        }
        if let customNode = o.member("custom"), let isCustom = nodeBool(customNode) {
            place.isCustomLocation = isCustom
        }
        if let customNameBytes = nodeString(o.member("custom_name")),
           WxText.isUsableName(bytes: customNameBytes, maxBytes: WxLimits.placeNameMax)
        {
            place.customName = String(decoding: customNameBytes.prefix { $0 != 0 }, as: UTF8.self)
            place.isCustomLocation = true
        }
        if let streetBytes = nodeString(o.member("street_address")),
           WxText.isUsableName(bytes: streetBytes, maxBytes: WxLimits.placeNameMax)
        {
            place.streetAddress = String(decoding: streetBytes.prefix { $0 != 0 }, as: UTF8.self)
            place.isCustomLocation = true
        }
        return place
    }

    /// An optional string member: absent is [] (""), a string is its bytes,
    /// anything else is nil (optional_string, src/storage/wx-store-json.c:150-160).
    private static func optionalString(_ o: Object, _ member: String) -> [UInt8]? {
        guard let n = o.member(member) else {
            return []
        }
        return nodeString(n)
    }

    /// The optional per-place "units" member of a places.json element (macOS
    /// only; the C format has none): "imperial" or "metric". Lenient like the
    /// "units" of WxSettings: absent, not a string, or any other text is nil
    /// (the caller applies its default) and never rejects the place.
    static func placeUnits(_ node: Node?) -> WxUnits? {
        guard let o = nodeObject(node), let units = nodeString(o.member("units")) else {
            return nil
        }
        if units == Array("metric".utf8) {
            return .metric
        }
        if units == Array("imperial".utf8) {
            return .imperial
        }
        return nil
    }

    /// Appends {"name": .., "admin1": .., "country": .., "country_code": ..,
    /// "lat": .., "lon": .., "timezone": ..} with the hand serialisers
    /// (wx_store_append_place, src/storage/wx-store-json.c:181-200), so the
    /// text passes the gate and the coordinates read back bit-identical.
    /// A non-nil `units` ends the object with "units": "imperial"/"metric"
    /// (places.json only; see `placeUnits`).
    static func appendPlace(_ place: WxPlace, units: WxUnits? = nil, to out: inout String) {
        out += "{\"name\": "
        StrictJSON.appendString(place.name, to: &out)
        out += ", \"admin1\": "
        StrictJSON.appendString(place.admin1, to: &out)
        out += ", \"country\": "
        StrictJSON.appendString(place.country, to: &out)
        out += ", \"country_code\": "
        StrictJSON.appendString(place.countryCode, to: &out)
        out += ", \"lat\": "
        StrictJSON.appendDouble(place.lat, to: &out)
        out += ", \"lon\": "
        StrictJSON.appendDouble(place.lon, to: &out)
        out += ", \"timezone\": "
        StrictJSON.appendString(place.timezone, to: &out)
        if place.isCustomLocation {
            out += ", \"custom\": true"
        }
        if !place.customName.isEmpty {
            out += ", \"custom_name\": "
            StrictJSON.appendString(place.customName, to: &out)
        }
        if !place.streetAddress.isEmpty {
            out += ", \"street_address\": "
            StrictJSON.appendString(place.streetAddress, to: &out)
        }
        if let units {
            out += ", \"units\": "
            StrictJSON.appendString(units == .metric ? "metric" : "imperial", to: &out)
        }
        out += "}"
    }

    // MARK: - Saves

    /// One save: the serialised snapshot, the target path and the generation
    /// the snapshot was taken at (the C SaveJob of wx-places.c:527-532 /
    /// wx-settings.c:475-480, serialised up front).
    struct SaveJob: Sendable {
        /// The file to replace.
        let path: String
        /// The complete document.
        let data: Data
        /// The object's generation counter when the snapshot was taken.
        let generation: UInt64
        /// The object's last load could not read `path`: move it aside
        /// (`FileIO.moveAside`) before writing, so the write cannot destroy it.
        var keepsExistingFile = false

        /// Writes the snapshot atomically on a background queue (never on the
        /// caller's thread). A cancellation of the calling task that arrived
        /// before the write started returns `.cancelled` and writes nothing;
        /// a cancellation after that does not turn a successful write into an
        /// error (save_worker, src/storage/wx-places.c:581-595).
        func perform() async -> Result<Void, WxStoreError> {
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            let path = path
            let data = data
            let keepsExistingFile = keepsExistingFile
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do throws(FileIOError) {
                        if keepsExistingFile {
                            try FileIO.moveAside(path: path)
                        }
                        try FileIO.writeAtomic(path: path, data: data)
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(.file(error)))
                    }
                }
            }
        }
    }

    // MARK: - Parser

    /// The json-glib stand-in: builds a tree from text the strict gate
    /// accepted (so nesting is at most 32 levels and the recursion is bounded).
    struct Document {
        /// Why a text was refused (the C message comes from json-glib; only
        /// the WX_ERROR_PARSE code is part of the contract).
        struct Failure: Error {
            let text: String
        }

        private let b: [UInt8]
        private var i = 0

        private init(_ bytes: [UInt8]) {
            b = bytes
        }

        /// Parses `bytes`: the root value, nil for a text holding only
        /// whitespace, or a failure.
        static func parse(_ bytes: [UInt8]) -> Result<Node?, Failure> {
            guard String(validating: bytes, as: UTF8.self) != nil else {
                return .failure(Failure(text: "JSON data must be UTF-8 encoded"))
            }
            var d = Document(bytes)
            d.skipWS()
            if d.i == d.b.count {
                return .success(nil)
            }
            guard let root = d.value(depth: 0) else {
                return .failure(Failure(text: "Parse error at byte \(d.i)"))
            }
            d.skipWS()
            guard d.i == d.b.count else {
                return .failure(Failure(text: "Parse error: unexpected data after the top-level value"))
            }
            return .success(root)
        }

        private func peek() -> UInt8? {
            i < b.count ? b[i] : nil
        }

        private mutating func skipWS() {
            while let c = peek(), c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
            }
        }

        private mutating func value(depth: Int) -> Node? {
            guard let c = peek() else {
                return nil
            }
            switch c {
            case UInt8(ascii: "{"):
                return object(depth: depth + 1)
            case UInt8(ascii: "["):
                return array(depth: depth + 1)
            case UInt8(ascii: "\""):
                return string().map { .string($0) }
            case UInt8(ascii: "t"):
                return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"):
                return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "n"):
                return literal("null") ? .null : nil
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
                return number()
            default:
                return nil
            }
        }

        private mutating func literal(_ word: StaticString) -> Bool {
            let n = word.utf8CodeUnitCount
            guard i + n <= b.count else {
                return false
            }
            let w = UnsafeBufferPointer(start: word.utf8Start, count: n)
            for k in 0 ..< n where b[i + k] != w[k] {
                return false
            }
            i += n
            // A literal followed by more identifier letters ("truex") is not a literal.
            if let c = peek(), (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || isDigit(c) {
                return false
            }
            return true
        }

        private mutating func object(depth: Int) -> Node? {
            guard depth <= StrictJSON.maxDepth else {
                return nil
            }
            i += 1 // '{'
            var members: [Object.Member] = []
            skipWS()
            if peek() == UInt8(ascii: "}") {
                i += 1
                return .object(Object(members: members))
            }
            while true {
                skipWS()
                guard peek() == UInt8(ascii: "\""), let name = string() else {
                    return nil // also a trailing comma before '}'
                }
                skipWS()
                guard peek() == UInt8(ascii: ":") else {
                    return nil
                }
                i += 1
                skipWS()
                guard let v = value(depth: depth) else {
                    return nil
                }
                members.append(Object.Member(name: name, value: v))
                skipWS()
                switch peek() {
                case UInt8(ascii: ",")?:
                    i += 1
                case UInt8(ascii: "}")?:
                    i += 1
                    return .object(Object(members: members))
                default:
                    return nil
                }
            }
        }

        private mutating func array(depth: Int) -> Node? {
            guard depth <= StrictJSON.maxDepth else {
                return nil
            }
            i += 1 // '['
            var elements: [Node] = []
            skipWS()
            if peek() == UInt8(ascii: "]") {
                i += 1
                return .array(elements)
            }
            while true {
                skipWS()
                guard let v = value(depth: depth) else {
                    return nil // also a trailing comma before ']'
                }
                elements.append(v)
                skipWS()
                switch peek() {
                case UInt8(ascii: ",")?:
                    i += 1
                case UInt8(ascii: "]")?:
                    i += 1
                    return .array(elements)
                default:
                    return nil
                }
            }
        }

        private func isDigit(_ c: UInt8) -> Bool {
            c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
        }

        private func hexValue(_ c: UInt8) -> UInt32? {
            switch c {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f"):
                UInt32(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A") ... UInt8(ascii: "F"):
                UInt32(c - UInt8(ascii: "A") + 10)
            default:
                nil
            }
        }

        private mutating func hex4() -> UInt32? {
            guard i + 4 <= b.count else {
                return nil
            }
            var v: UInt32 = 0
            for k in 0 ..< 4 {
                guard let h = hexValue(b[i + k]) else {
                    return nil
                }
                v = v << 4 | h
            }
            i += 4
            return v
        }

        /// A string token at `i` (opening quote), decoded to UTF-8 bytes.
        private mutating func string() -> [UInt8]? {
            i += 1 // '"'
            var out: [UInt8] = []
            while let c = peek() {
                i += 1
                switch c {
                case UInt8(ascii: "\""):
                    return out
                case UInt8(ascii: "\\"):
                    guard let e = peek() else {
                        return nil
                    }
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                        out.append(e)
                    case UInt8(ascii: "b"):
                        out.append(0x08)
                    case UInt8(ascii: "f"):
                        out.append(0x0C)
                    case UInt8(ascii: "n"):
                        out.append(0x0A)
                    case UInt8(ascii: "r"):
                        out.append(0x0D)
                    case UInt8(ascii: "t"):
                        out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var scalar = hex4() else {
                            return nil
                        }
                        if scalar >= 0xD800 && scalar <= 0xDBFF {
                            // A high surrogate must be followed by an escaped low surrogate.
                            guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else {
                                return nil
                            }
                            i += 2
                            guard let low = hex4(), low >= 0xDC00 && low <= 0xDFFF else {
                                return nil
                            }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else if scalar >= 0xDC00 && scalar <= 0xDFFF {
                            return nil
                        }
                        // The gate refuses \u0000, so no NUL byte is ever produced.
                        guard scalar != 0, let u = Unicode.Scalar(scalar) else {
                            return nil
                        }
                        out.append(contentsOf: Array(String(Character(u)).utf8))
                    default:
                        return nil
                    }
                default:
                    if c < 0x20 {
                        return nil
                    }
                    out.append(c)
                }
            }
            return nil // unterminated
        }

        /// A number token (RFC 8259 grammar): an integer node without '.',
        /// 'e' or 'E', a double node otherwise.
        private mutating func number() -> Node? {
            let start = i
            if peek() == UInt8(ascii: "-") {
                i += 1
            }
            guard let first = peek(), isDigit(first) else {
                return nil
            }
            i += 1
            if first != UInt8(ascii: "0") {
                while let c = peek(), isDigit(c) {
                    i += 1
                }
            }
            var isInteger = true
            if peek() == UInt8(ascii: ".") {
                isInteger = false
                i += 1
                guard let c = peek(), isDigit(c) else {
                    return nil
                }
                while let c = peek(), isDigit(c) {
                    i += 1
                }
            }
            if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                isInteger = false
                i += 1
                if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") {
                    i += 1
                }
                guard let c = peek(), isDigit(c) else {
                    return nil
                }
                while let c = peek(), isDigit(c) {
                    i += 1
                }
            }
            // "01", "1.5.2", "1-2" and the like: the token must end here.
            if let c = peek(), isDigit(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "-")
                || c == UInt8(ascii: "+") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                return nil
            }
            let token = String(decoding: b[start ..< i], as: UTF8.self)
            if isInteger {
                if let v = Int64(token) {
                    return .int(v)
                }
                return .int(token.hasPrefix("-") ? Int64.min : Int64.max)
            }
            guard let v = Double(token) else {
                return nil
            }
            return .double(v)
        }
    }
}
