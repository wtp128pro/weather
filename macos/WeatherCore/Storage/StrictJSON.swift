// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StrictJSON.swift - the strict JSON gate that every loader runs before a
// parser sees a file, and the two hand serialisers every writer uses; a port
// of wx_json_check_strict, wx_json_append_string and wx_json_append_double
// (src/storage/wx-fileio.{h,c}).

import Darwin
import Foundation

/// Strict JSON gate and JSON writers of the storage module.
public enum StrictJSON {
    /// Deepest array/object nesting that the loaders accept
    /// (WX_JSON_MAX_DEPTH, src/storage/wx-fileio.h:23). Also the largest
    /// `maxDepth` that `check` accepts.
    public static let maxDepth = 32

    /// The message loaders report when `check` refuses a document:
    /// "<what>: not strict JSON or nested deeper than 32"
    /// (src/storage/wx-store-json.c:27).
    public static func rejectionMessage(_ what: String) -> String {
        "\(what): not strict JSON or nested deeper than \(maxDepth)"
    }

    // MARK: - Gate

    /// Linear, non-recursive, constant-memory gate (wx_json_check_strict,
    /// src/storage/wx-fileio.c:317-396). Accepts only the strict token
    /// alphabet and fails closed on everything else:
    /// - outside strings only space, \t, \n, \r, `{ } [ ] , :`, digits,
    ///   `- + . e E` and the letters of true/false/null;
    /// - inside strings a backslash must be followed by one of `" \ / b f n r t`
    ///   or `u` plus four hex digits that are not all zero (the escape of
    ///   U+0000 is refused); raw bytes below 0x20 are refused; bytes >= 0x80
    ///   pass; the string must be terminated;
    /// - every closer must match the innermost open container and every
    ///   container must be closed at the end;
    /// - opening a container deeper than `maxDepth` is refused.
    /// Number and value grammar are not checked ("[1 2]" passes).
    /// A `maxDepth` outside 0...32 returns false (C: critical, FALSE).
    public static func check(_ bytes: some ContiguousBytes, maxDepth: Int = StrictJSON.maxDepth) -> Bool {
        bytes.withUnsafeBytes { check(raw: $0, maxDepth: maxDepth) }
    }

    /// The gate over raw bytes; never reads outside `text`.
    static func check(raw text: UnsafeRawBufferPointer, maxDepth: Int) -> Bool {
        guard maxDepth >= 0, maxDepth <= 32 else {
            return false
        }
        let len = text.count
        var kinds: UInt32 = 0 // bit i: the container at depth i is an object
        var depth = 0
        var i = 0
        while i < len {
            let c = text[i]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D, // space \t \n \r
                 UInt8(ascii: ","), UInt8(ascii: ":"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                 UInt8(ascii: "t"), UInt8(ascii: "r"), UInt8(ascii: "u"), UInt8(ascii: "f"),
                 UInt8(ascii: "a"), UInt8(ascii: "l"), UInt8(ascii: "s"), UInt8(ascii: "n"):
                break
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                if depth >= maxDepth {
                    return false
                }
                if c == UInt8(ascii: "{") {
                    kinds |= UInt32(1) << UInt32(depth)
                } else {
                    kinds &= ~(UInt32(1) << UInt32(depth))
                }
                depth += 1
            case UInt8(ascii: "]"):
                if !popContainer(kinds: kinds, depth: &depth, want: 0) {
                    return false
                }
            case UInt8(ascii: "}"):
                if !popContainer(kinds: kinds, depth: &depth, want: 1) {
                    return false
                }
            case UInt8(ascii: "\""):
                i += 1
                while true {
                    if i >= len {
                        return false // unterminated string
                    }
                    let s = text[i]
                    if s == UInt8(ascii: "\"") {
                        break
                    }
                    if s < 0x20 {
                        return false
                    }
                    if s != UInt8(ascii: "\\") {
                        i += 1
                        continue
                    }
                    i += 1
                    if i >= len {
                        return false
                    }
                    switch text[i] {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                         UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        break
                    case UInt8(ascii: "u"):
                        if len - i < 5 {
                            return false
                        }
                        // U+0000 is refused: a parser could cut the string at it.
                        var allZero = true
                        for k in 1 ... 4 {
                            if !isHexDigit(text[i + k]) {
                                return false
                            }
                            allZero = allZero && text[i + k] == UInt8(ascii: "0")
                        }
                        if allZero {
                            return false
                        }
                        i += 4
                    default:
                        return false
                    }
                    i += 1
                }
            default:
                return false // ' / # NUL, other controls, non-ASCII, letters outside true/false/null
            }
            i += 1
        }
        return depth == 0
    }

    /// pop_container (src/storage/wx-fileio.c:308-315): false if no container
    /// is open or the innermost one is not of kind `want` (1 = object,
    /// 0 = array); `depth` is decremented whenever it was non-zero.
    private static func popContainer(kinds: UInt32, depth: inout Int, want: UInt32) -> Bool {
        if depth == 0 {
            return false
        }
        depth -= 1
        return ((kinds >> UInt32(depth)) & 1) == want
    }

    /// g_ascii_isxdigit.
    private static func isHexDigit(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    // MARK: - Writers

    /// Appends `s` as a JSON string literal with its quotes
    /// (wx_json_append_string, src/storage/wx-fileio.c:398-417): `"` and `\`
    /// get a backslash, every byte below 0x20 becomes "\u00xx" (lower-case
    /// hex), everything else (0x7f and UTF-8 bytes included) is copied
    /// unchanged. Like the C function, which walks a NUL-terminated string,
    /// the text ends at its first U+0000 (the gate refuses "\u0000", so the
    /// output always passes `check`).
    public static func appendString(_ s: String, to out: inout String) {
        var bytes: [UInt8] = [UInt8(ascii: "\"")]
        bytes.reserveCapacity(s.utf8.count + 2)
        let hex = Array("0123456789abcdef".utf8)
        for c in s.utf8 {
            if c == 0 {
                break
            }
            if c == UInt8(ascii: "\"") || c == UInt8(ascii: "\\") {
                bytes.append(UInt8(ascii: "\\"))
                bytes.append(c)
            } else if c < 0x20 {
                bytes.append(contentsOf: Array("\\u00".utf8))
                bytes.append(hex[Int(c >> 4)])
                bytes.append(hex[Int(c & 0x0F)])
            } else {
                bytes.append(c)
            }
        }
        bytes.append(UInt8(ascii: "\""))
        out += String(decoding: bytes, as: UTF8.self)
    }

    /// Appends `v` as a JSON number that reads back bit-identical
    /// (wx_json_append_double, src/storage/wx-fileio.c:419-441): the shortest
    /// of "%.15g", "%.16g" and "%.17g" (C locale, '.' decimal point) that
    /// round-trips through strtod; NaN and +-infinity become "null"; negative
    /// zero becomes "-0.0". The text always passes `check`.
    public static func appendDouble(_ v: Double, to out: inout String) {
        if !v.isFinite {
            out += "null"
            return
        }
        if v == 0.0 && v.sign == .minus {
            out += "-0.0"
            return
        }
        var text = format(v, precision: 15)
        if parse(text) != v {
            text = format(v, precision: 16)
            if parse(text) != v {
                text = format(v, precision: 17)
            }
        }
        out += text
    }

    /// "%.<precision>g" with a '.' decimal point whatever the process locale
    /// (g_ascii_formatd): Foundation's String(format:) without a locale
    /// formats non-localized.
    private static func format(_ v: Double, precision: Int) -> String {
        String(format: "%.\(precision)g", v)
    }

    /// Locale-independent, correctly rounded decimal-to-double conversion
    /// (g_ascii_strtod); nil when the text is not a complete number.
    private static func parse(_ text: String) -> Double? {
        Double(text)
    }
}
