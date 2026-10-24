// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Text.swift - bounded, sanitising helpers for text that comes from outside
// the process (provider responses, files, user input) before it is stored or
// displayed. Port of src/core/wx-text.{h,c}; outputs are byte-identical to
// the C functions on the same input bytes.
//
// "Forbidden" characters, in every function below (src/core/wx-text.h:8-11):
// Unicode control characters (category Cc: C0, DEL, C1), the line/paragraph
// separators U+2028/U+2029 (the only members of Zl/Zp), and the bidirectional
// formatting characters U+061C, U+200E, U+200F, U+202A...U+202E and
// U+2066...U+2069.
//
// Input model (fidelity with NUL-terminated C strings): every function reads
// its input as UTF-8 bytes, left to right, and stops at the first 0x00 byte
// or at the end of the collection, whichever comes first. A `String` is read
// through its UTF-8 view, so an embedded U+0000 ends it exactly as the NUL
// ends the C string. A `nil` input behaves like a NULL pointer.

/// Bounded, sanitising text helpers (port of src/core/wx-text.c).
public enum WxText {
    // MARK: - Public API

    /// Display-safe copy of `bytes` (wx_sanitize_text, src/core/wx-text.c:99-123):
    /// forbidden characters are removed, every invalid UTF-8 lead byte is
    /// replaced by U+FFFD (three bytes) and the following bytes are examined
    /// afresh (GLib-style, NOT maximal-subpart replacement), and the result is
    /// cut on a character boundary so that it never exceeds `maxBytes` UTF-8
    /// bytes. Reading stops once the output holds `maxBytes` bytes (checked
    /// before the next byte is looked at), at the first 0x00 byte or at the end
    /// of `bytes`, and after the first character that does not fit; no byte
    /// more than 3 positions beyond the lead byte being examined is read.
    ///
    /// - Returns: valid UTF-8 without forbidden characters, at most `maxBytes`
    ///   bytes long; "" when `maxBytes` <= 0.
    public static func sanitize<Bytes: Collection<UInt8>>(bytes: Bytes, maxBytes: Int) -> String {
        if maxBytes <= 0 {
            return ""
        }
        var out: [UInt8] = []
        out.reserveCapacity(Swift.min(maxBytes, 256))
        var p = bytes.startIndex
        let end = bytes.endIndex
        // Output full: whatever follows cannot change the result, so stop
        // before even looking at the next byte (wx-text.c:109-111).
        while out.count < maxBytes && p != end && bytes[p] != 0 {
            let decoded = decodeChar(bytes, at: p)  // invalid: U+FFFD, one byte
            p = bytes.index(p, offsetBy: decoded.length)
            if isForbidden(decoded.scalar) {
                continue
            }
            let encoded = utf8Bytes(of: decoded.scalar)
            if out.count + encoded.count > maxBytes {
                break
            }
            out.append(contentsOf: encoded)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `sanitize(bytes:maxBytes:)` of the UTF-8 bytes of `text`; "" for nil.
    public static func sanitize(_ text: String?, maxBytes: Int) -> String {
        guard let text else {
            return ""
        }
        return sanitize(bytes: text.utf8, maxBytes: maxBytes)
    }

    /// Whether `bytes` may be used as a name (place, admin region, country)
    /// without modification (wx_text_is_usable_name, src/core/wx-text.c:126-147).
    /// At most the first `maxBytes` + 1 bytes are read (the bounded search for
    /// the terminator comes first; input with more than `maxBytes` bytes before
    /// its terminator is rejected before any byte is interpreted).
    ///
    /// - Returns: true iff the text is 1...`maxBytes` bytes long, valid UTF-8,
    ///   free of forbidden characters and contains at least one character that
    ///   is not whitespace (GLib g_unichar_isspace).
    public static func isUsableName<Bytes: Collection<UInt8>>(bytes: Bytes, maxBytes: Int) -> Bool {
        if maxBytes <= 0 {
            return false
        }
        // memchr(s, '\0', max < G_MAXSIZE ? max + 1 : max): never overflows.
        let window = Array(bytes.prefix(maxBytes < Int.max ? maxBytes + 1 : maxBytes))
        let length: Int
        if let nul = window.firstIndex(of: 0) {
            length = nul
        } else if window.count <= maxBytes {
            length = window.count  // the collection ended: its end is the terminator
        } else {
            return false  // no terminator within maxBytes + 1 bytes
        }
        if length == 0 {
            return false
        }
        // g_utf8_validate first, then the character loop (wx-text.c:134-146).
        var scalars: [Unicode.Scalar] = []
        var p = 0
        while p < length {
            let decoded = decodeChar(window[0..<length], at: p)
            if !decoded.valid {
                return false
            }
            scalars.append(decoded.scalar)
            p += decoded.length
        }
        var visible = false
        for c in scalars {
            if isForbidden(c) {
                return false
            }
            if !isSpace(c) {
                visible = true
            }
        }
        return visible
    }

    /// `isUsableName(bytes:maxBytes:)` of the UTF-8 bytes of `name`; false for nil.
    public static func isUsableName(_ name: String?, maxBytes: Int) -> Bool {
        guard let name else {
            return false
        }
        return isUsableName(bytes: name.utf8, maxBytes: maxBytes)
    }

    /// Copy of at most `maxScalars` Unicode scalars (code points, not
    /// `Character`s) of `bytes`, without ellipsis (wx_truncated_copy,
    /// src/core/wx-text.c:150-165). The copy ends before the first invalid
    /// UTF-8 sequence (stray continuation, truncated or overlong form,
    /// surrogate, value above U+10FFFF); forbidden characters are NOT removed.
    /// Once `maxScalars` scalars are copied nothing more is read.
    ///
    /// - Returns: a valid-UTF-8 byte prefix of the input; "" for
    ///   `maxScalars` <= 0 and for input that starts with an invalid sequence.
    public static func truncatedCopy<Bytes: Collection<UInt8>>(bytes: Bytes, maxScalars: Int) -> String {
        var p = bytes.startIndex
        let end = bytes.endIndex
        var n = 0
        var out: [UInt8] = []
        while n < maxScalars && p != end && bytes[p] != 0 {
            let decoded = decodeChar(bytes, at: p)
            if !decoded.valid {
                break
            }
            let next = bytes.index(p, offsetBy: decoded.length)
            out.append(contentsOf: bytes[p..<next])
            p = next
            n += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `truncatedCopy(bytes:maxScalars:)` of the UTF-8 bytes of `text`; "" for nil.
    public static func truncatedCopy(_ text: String?, maxScalars: Int) -> String {
        guard let text else {
            return ""
        }
        return truncatedCopy(bytes: text.utf8, maxScalars: maxScalars)
    }

    // MARK: - Classification (wx-text.c:26-38; GLib gunicode semantics)

    /// True for the forbidden characters: general category Cc (U+0000...U+001F,
    /// U+007F...U+009F; the Cc set is closed by Unicode's stability policy), Zl
    /// (U+2028), Zp (U+2029), and the bidi formatting characters of
    /// wx-text.c:36-37.
    static func isForbidden(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if v <= 0x1F || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029 {
            return true
        }
        return v == 0x061C || v == 0x200E || v == 0x200F || (v >= 0x202A && v <= 0x202E)
            || (v >= 0x2066 && v <= 0x2069)
    }

    /// GLib g_unichar_isspace: '\t', '\n', '\r', '\f' (not '\v'), and the
    /// characters of category Zs, Zl or Zp.
    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09, 0x0A, 0x0D, 0x0C:
            return true
        case 0x2028, 0x2029:  // Zl, Zp
            return true
        // Zs (unchanged since Unicode 6.3, when U+180E moved to Cf).
        case 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    // MARK: - Decoding (decode_char, wx-text.c:76-96)

    /// One decoded character: `valid` false means U+FFFD with length 1.
    private struct Decoded {
        let scalar: Unicode.Scalar
        let length: Int
        let valid: Bool
    }

    private static let replacement = Unicode.Scalar(0xFFFD)!

    /// Decodes the character whose lead byte is at `p` (a non-zero byte).
    /// A lead byte < 0x80 is decided alone; 0x80...0xC1 and 0xF5...0xFF are
    /// decided alone as invalid; a lead 0xC2...0xDF / 0xE0...0xEF / 0xF0...0xF4
    /// is followed by at most 1 / 2 / 3 continuation bytes, and examination
    /// stops at the first byte that is not a continuation byte (or the end /
    /// a 0x00 byte, which is never a continuation byte). Any invalid,
    /// overlong, surrogate, out-of-range or truncated sequence yields U+FFFD
    /// and consumes exactly ONE byte (the lead byte).
    private static func decodeChar<Bytes: Collection<UInt8>>(_ bytes: Bytes, at p: Bytes.Index) -> Decoded {
        let lead = bytes[p]
        if lead < 0x80 {
            return Decoded(scalar: Unicode.Scalar(lead), length: 1, valid: true)
        }
        let invalid = Decoded(scalar: replacement, length: 1, valid: false)
        if lead < 0xC2 || lead > 0xF4 {
            return invalid
        }
        let want = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4)
        // g_utf8_get_char_validated(p, want): value bits and minimum per length.
        var value = UInt32(lead) & (want == 2 ? 0x1F : (want == 3 ? 0x0F : 0x07))
        let minimum: UInt32 = want == 2 ? 0x80 : (want == 3 ? 0x800 : 0x1_0000)
        var q = p
        for _ in 1..<want {
            q = bytes.index(after: q)
            if q == bytes.endIndex {
                return invalid  // partial sequence at the end of the input
            }
            let b = bytes[q]
            if b & 0xC0 != 0x80 {
                return invalid  // not a continuation byte (0x00 included): stop here
            }
            value = (value << 6) | UInt32(b & 0x3F)
        }
        // Overlong, surrogate or above U+10FFFF (GLib UNICODE_VALID).
        if value < minimum || value > 0x10_FFFF || (value & 0xFFFF_F800) == 0xD800 {
            return invalid
        }
        guard let scalar = Unicode.Scalar(value) else {
            return invalid
        }
        return Decoded(scalar: scalar, length: want, valid: true)
    }

    /// The UTF-8 encoding of `c` (g_unichar_to_utf8).
    private static func utf8Bytes(of c: Unicode.Scalar) -> [UInt8] {
        Array(UTF8.encode(c)!)
    }
}
