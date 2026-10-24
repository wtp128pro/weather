// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FileIO.swift - crash-safe small-file persistence primitives; a port of
// src/storage/wx-fileio.{h,c} (wx_file_write_atomic, wx_file_read_bounded,
// wx_file_remove_stale_temps).
//
// Every function is synchronous and blocks on disk I/O (including a full
// flush): call them from a background task or from start-up/shutdown code,
// never from the main actor. They hold no locks and touch no global state.
// No function here resolves a user directory: every path comes from the
// caller (the stores inject their sandbox-container paths).
//
// Differences from the C code (all deliberate, see the U05 debrief):
// - the file flush is fcntl(F_FULLFSYNC) (the macOS durable flush; fsync(2)
//   only reaches the drive cache), falling back to fsync(2) when the file
//   system does not support F_FULLFSYNC (ENOTSUP/ENOTTY/EINVAL);
// - violated preconditions (empty path, max byte limit out of range) throw
//   `FileIOError.Kind.invalidArgument` instead of logging a GLib critical;
// - the read size limit uses Swift's size type: maxBytes < Int.max / 4
//   (the C limit is G_MAXSIZE / 4); the C buffer's extra NUL byte is not
//   part of the returned Data.

import Darwin
import Foundation

/// The error of a failed file operation. `kind` is what callers branch on;
/// `message` mirrors the C GError message ("cannot open '<path>': <strerror>").
public struct FileIOError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The cause of the failure.
    public enum Kind: Equatable, Sendable {
        /// A system call failed with this errno (C: the G_FILE_ERROR code
        /// mapped from errno by g_file_error_from_errno).
        case posix(Int32)
        /// The path does not name a regular file (C: G_FILE_ERROR_INVAL,
        /// "'<path>' is not a regular file"); devices and FIFOs are never read.
        case notRegularFile
        /// The file holds more than `limit` bytes (C: G_IO_ERROR_MESSAGE_TOO_LARGE).
        case tooLarge(limit: Int)
        /// A precondition was violated (C: g_return_val_if_fail critical).
        case invalidArgument
    }

    /// The cause of the failure.
    public let kind: Kind
    /// Human-readable description in the C wording.
    public let message: String

    /// Creates an error (public so that store tests and fakes can build one).
    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// True when the file (or a directory on its path) does not exist (ENOENT).
    public var isNotFound: Bool { kind == .posix(ENOENT) }

    public var description: String { message }
}

/// Atomic writes, size-bounded reads and stale temporary file removal.
public enum FileIO {
    /// Infix of the temporary file names: "<path>" + tempInfix + six ASCII
    /// letters/digits (WX_TEMP_INFIX, src/storage/wx-fileio.h:26).
    public static let tempInfix = ".wx-tmp-"

    /// A temporary file is stale when its mtime is MORE than this many seconds
    /// old (STALE_TEMP_AGE_SECONDS, src/storage/wx-fileio.c:210).
    public static let staleTempAgeSeconds = 60

    /// Number of random characters after `tempInfix` (TEMP_SUFFIX_LEN, wx-fileio.c:211).
    static let tempSuffixLength = 6

    /// The system-call seam of this file. The production value forwards to the
    /// kernel; tests inject faults (EINTR, short writes, EIO, ENOSPC) the way
    /// test-storage.c interposes write/read/fsync/close/fstat
    /// (src/storage/test-storage.c:40-131). Every call returns the kernel's
    /// result, or -errno on failure (never relies on the global errno).
    struct Syscalls: Sendable {
        /// write(2): bytes written, or -errno.
        var write: @Sendable (_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int
        /// read(2): bytes read (0 at end of file), or -errno.
        var read: @Sendable (_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int
        /// The durable flush of a file or directory descriptor: 0, or -errno.
        var fullSync: @Sendable (_ fd: Int32) -> Int32
        /// close(2) (the descriptor is released even when an error is reported): 0, or -errno.
        var close: @Sendable (_ fd: Int32) -> Int32
        /// fstat(2): 0, or -errno.
        var fstat: @Sendable (_ fd: Int32, _ status: UnsafeMutablePointer<stat>) -> Int32

        /// The kernel.
        static let system = Syscalls(
            write: { fd, buffer, count in
                let n = Darwin.write(fd, buffer, count)
                return n < 0 ? -Int(errno) : n
            },
            read: { fd, buffer, count in
                let n = Darwin.read(fd, buffer, count)
                return n < 0 ? -Int(errno) : n
            },
            fullSync: { fd in
                if fcntl(fd, F_FULLFSYNC) != -1 {
                    return 0
                }
                let e = errno
                // File systems without F_FULLFSYNC (some network and FUSE
                // volumes): fall back to the C code's fsync(2).
                guard e == ENOTSUP || e == ENOTTY || e == EINVAL else {
                    return -e
                }
                return Darwin.fsync(fd) == 0 ? 0 : -errno
            },
            close: { fd in
                Darwin.close(fd) == 0 ? 0 : -errno
            },
            fstat: { fd, status in
                Darwin.fstat(fd, status) == 0 ? 0 : -errno
            }
        )
    }

    // MARK: - Atomic write

    /// Replaces the content of `path` so that readers observe either the
    /// complete old file or the complete new file (wx_file_write_atomic,
    /// src/storage/wx-fileio.c:72-121):
    /// 1. missing parent directories are created with mode 0700 (an existing
    ///    directory keeps its mode);
    /// 2. the bytes go to a fresh "<path>.wx-tmp-XXXXXX" file (mode 0600) in
    ///    the same directory, written with EINTR/short-write retries, flushed
    ///    with F_FULLFSYNC and closed;
    /// 3. the temporary file is renamed over `path` (a symbolic link at `path`
    ///    is replaced, not followed; the result always has mode 0600);
    /// 4. the directory is flushed on a best-effort basis (errors ignored).
    /// On failure the temporary file is removed and `path` is unchanged
    /// (missing parent directories created before the failure stay).
    public static func writeAtomic(path: String, data: Data) throws(FileIOError) {
        try writeAtomic(path: path, data: data, syscalls: .system)
    }

    /// `writeAtomic(path:data:)` with an injected system-call seam (tests).
    static func writeAtomic(path: String, data: Data, syscalls: Syscalls) throws(FileIOError) {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw FileIOError(kind: .invalidArgument, message: "path is empty or contains a NUL byte")
        }
        let dir = dirname(of: path)
        let mkdirError = makeDirectoryWithParents(dir, mode: 0o700)
        if mkdirError != 0 {
            throw errnoError(mkdirError, "cannot create directory", dir)
        }

        var template = Array((path + tempInfix + "XXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { buffer in
            mkostemp(buffer.baseAddress!, O_CLOEXEC) // O_RDWR | O_CREAT | O_EXCL, mode 0600
        }
        if fd < 0 {
            throw errnoError(errno, "cannot create temporary file for", path)
        }
        let tmp = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        var err: Int32 = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var done = 0
            while done < bytes.count {
                let n = syscalls.write(fd, bytes.baseAddress! + done, bytes.count - done)
                if n < 0 {
                    if n == -Int(EINTR) {
                        continue
                    }
                    err = Int32(-n)
                    break
                }
                done += n
            }
        }
        if err == 0 {
            let rc = syscalls.fullSync(fd)
            if rc != 0 {
                err = -rc
            }
        }
        let closeRC = syscalls.close(fd)
        if closeRC != 0 && err == 0 {
            err = -closeRC
        }
        if err != 0 {
            _ = unlink(tmp)
            throw errnoError(err, "cannot write", tmp)
        }

        if rename(tmp, path) != 0 {
            let e = errno
            _ = unlink(tmp)
            throw errnoError(e, "cannot replace", path)
        }
        syncDirectory(dir, syscalls: syscalls)
    }

    // MARK: - Bounded read

    /// Reads the whole regular file at `path` (symbolic links are followed),
    /// refusing a file of more than `maxBytes` bytes (wx_file_read_bounded,
    /// src/storage/wx-fileio.c:123-208). At most maxBytes + 1 bytes are ever
    /// read, so a file that grows while it is being read (or whose size
    /// fstat does not know) is refused too. The open uses O_NONBLOCK so a FIFO
    /// cannot hang it; devices and FIFOs are refused as `.notRegularFile`.
    ///
    /// Errors: `.posix(ENOENT)` when the file does not exist,
    /// `.tooLarge(limit: maxBytes)` above the limit, `.notRegularFile`, any
    /// other `.posix` errno of open/fstat/read, `.invalidArgument` for an
    /// empty path or maxBytes outside 0 ..< Int.max / 4.
    public static func readBounded(path: String, maxBytes: Int) throws(FileIOError) -> Data {
        try readBounded(path: path, maxBytes: maxBytes, syscalls: .system)
    }

    /// `readBounded(path:maxBytes:)` with an injected system-call seam (tests).
    static func readBounded(path: String, maxBytes: Int, syscalls: Syscalls) throws(FileIOError) -> Data {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw FileIOError(kind: .invalidArgument, message: "path is empty or contains a NUL byte")
        }
        guard maxBytes >= 0, maxBytes < Int.max / 4 else {
            throw FileIOError(kind: .invalidArgument, message: "max_bytes \(maxBytes) is out of range")
        }

        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            throw errnoError(errno, "cannot open", path)
        }

        var st = stat()
        let statRC = syscalls.fstat(fd, &st)
        if statRC != 0 {
            _ = syscalls.close(fd)
            throw errnoError(-statRC, "cannot stat", path)
        }
        if (st.st_mode & S_IFMT) != S_IFREG {
            _ = syscalls.close(fd)
            throw FileIOError(kind: .notRegularFile, message: "'\(path)' is not a regular file")
        }
        if st.st_size < 0 || UInt64(st.st_size) > UInt64(maxBytes) {
            _ = syscalls.close(fd)
            throw tooLargeError(path, maxBytes)
        }

        // Same buffer arithmetic as the C code (wx-fileio.c:162-189), so the
        // read sizes requested from the kernel are identical: `alloc` counts
        // the C terminating NUL, which is never filled here.
        let limit = maxBytes + 1
        var alloc = min(Int(st.st_size) + 1, limit) + 1
        var buffer = [UInt8](repeating: 0, count: alloc)
        var used = 0
        var err: Int32 = 0
        while true {
            if used == alloc - 1 {
                if used >= limit {
                    break
                }
                alloc = min(alloc * 2, limit + 1)
                buffer.append(contentsOf: repeatElement(0, count: alloc - buffer.count))
            }
            let n = buffer.withUnsafeMutableBytes { raw in
                syscalls.read(fd, raw.baseAddress! + used, alloc - 1 - used)
            }
            if n < 0 {
                if n == -Int(EINTR) {
                    continue
                }
                err = Int32(-n)
                break
            }
            if n == 0 {
                break
            }
            used += n
        }
        _ = syscalls.close(fd)

        if err != 0 {
            throw errnoError(err, "cannot read", path)
        }
        if used > maxBytes {
            throw tooLargeError(path, maxBytes)
        }
        return Data(buffer[0 ..< used])
    }

    // MARK: - Stale temporary files

    /// Deletes the regular files named exactly "<path>.wx-tmp-" + six ASCII
    /// letters/digits next to `path` whose mtime is more than 60 seconds ago
    /// (wx_file_remove_stale_temps, src/storage/wx-fileio.c:255-284). Younger
    /// ones are kept (a write may be running, even in another process); other
    /// names, symbolic links and directories are never touched. Candidates are
    /// examined with fstatat(AT_SYMLINK_NOFOLLOW) and removed with unlinkat()
    /// relative to the opened directory. Best effort: errors are ignored and a
    /// missing directory is not an error. An empty path does nothing.
    public static func removeStaleTemps(path: String) {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            return
        }
        let dir = dirname(of: path)
        let base = Array(basename(of: path).utf8)
        guard let d = opendir(dir) else {
            return
        }
        defer { closedir(d) } // also closes dfd
        let dfd = dirfd(d)
        let now = time(nil)
        while let ent = readdir(d) {
            let nameLength = Int(ent.pointee.d_namlen)
            let matches = withUnsafeBytes(of: &ent.pointee.d_name) { raw in
                isTempName(UnsafeRawBufferPointer(rebasing: raw[0 ..< min(nameLength, raw.count)]), base: base)
            }
            if !matches {
                continue
            }
            withUnsafePointer(to: &ent.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { name in
                    var st = stat()
                    if fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                       (st.st_mode & S_IFMT) == S_IFREG,
                       difftime(now, st.st_mtimespec.tv_sec) > Double(staleTempAgeSeconds) {
                        _ = unlinkat(dfd, name, 0)
                    }
                }
            }
        }
    }

    /// True iff `name` is exactly `base` + ".wx-tmp-" + six ASCII
    /// letters/digits (is_temp_name, src/storage/wx-fileio.c:237-253).
    static func isTempName(_ name: UnsafeRawBufferPointer, base: [UInt8]) -> Bool {
        let infix = Array(tempInfix.utf8)
        let nameLength = name.count
        guard nameLength <= Int(NAME_MAX), nameLength >= base.count,
              nameLength - base.count == infix.count + tempSuffixLength else {
            return false
        }
        for (i, byte) in base.enumerated() where name[i] != byte {
            return false
        }
        for (i, byte) in infix.enumerated() where name[base.count + i] != byte {
            return false
        }
        for i in 0 ..< tempSuffixLength {
            let c = name[base.count + infix.count + i]
            let isAlnum = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            if !isAlnum {
                return false
            }
        }
        return true
    }

    // MARK: - Path helpers (GLib semantics)

    /// g_path_get_dirname: "." without a separator; trailing separators of the
    /// directory part are dropped; the root stays "/".
    static func dirname(of path: String) -> String {
        let bytes = Array(path.utf8)
        guard var base = bytes.lastIndex(of: UInt8(ascii: "/")) else {
            return "."
        }
        while base > 0 && bytes[base] == UInt8(ascii: "/") {
            base -= 1
        }
        return String(decoding: bytes[0 ... base], as: UTF8.self)
    }

    /// g_path_get_basename: the last component, ignoring trailing separators;
    /// "/" for a path made only of separators, "." for an empty path.
    static func basename(of path: String) -> String {
        let bytes = Array(path.utf8)
        if bytes.isEmpty {
            return "."
        }
        var end = bytes.count - 1
        while end >= 0 && bytes[end] == UInt8(ascii: "/") {
            end -= 1
        }
        if end < 0 {
            return "/"
        }
        var start = end
        while start > 0 && bytes[start - 1] != UInt8(ascii: "/") {
            start -= 1
        }
        return String(decoding: bytes[start ... end], as: UTF8.self)
    }

    /// g_mkdir_with_parents: creates every missing component with `mode`
    /// (the umask applies), leaves existing directories alone and fails with
    /// ENOTDIR when a component exists but is not a directory (stat follows
    /// symbolic links). Returns 0 or the errno.
    static func makeDirectoryWithParents(_ path: String, mode: mode_t) -> Int32 {
        var bytes = Array(path.utf8)
        if bytes.isEmpty {
            return EINVAL
        }
        bytes.append(0)
        let slash = UInt8(ascii: "/")
        var p = 0
        while p < bytes.count - 1 && bytes[p] == slash { // skip the root
            p += 1
        }
        while true {
            while bytes[p] != 0 && bytes[p] != slash {
                p += 1
            }
            let atEnd = bytes[p] == 0
            bytes[p] = 0
            let rc: Int32 = bytes.withUnsafeBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) { component in
                    let name = component.baseAddress!
                    var st = stat()
                    if access(name, F_OK) != 0 {
                        if mkdir(name, mode) == -1 && errno != EEXIST {
                            return errno
                        }
                    } else if stat(name, &st) != 0 || (st.st_mode & S_IFMT) != S_IFDIR {
                        return ENOTDIR
                    }
                    return 0
                }
            }
            if rc != 0 {
                return rc
            }
            if atEnd {
                return 0
            }
            bytes[p] = slash
            p += 1
            while bytes[p] == slash {
                p += 1
            }
            if bytes[p] == 0 {
                return 0
            }
        }
    }

    // MARK: - Private helpers

    /// Best effort: flushes the directory so that the rename is durable
    /// (sync_directory, src/storage/wx-fileio.c:61-69); failures are ignored.
    private static func syncDirectory(_ dir: String, syscalls: Syscalls) {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 {
            return
        }
        _ = syscalls.fullSync(fd)
        _ = syscalls.close(fd)
    }

    /// "<what> '<path>': <strerror>" (set_errno_error, wx-fileio.c:39-44).
    private static func errnoError(_ err: Int32, _ what: String, _ path: String) -> FileIOError {
        FileIOError(kind: .posix(err), message: "\(what) '\(path)': \(String(cString: strerror(err)))")
    }

    private static func tooLargeError(_ path: String, _ maxBytes: Int) -> FileIOError {
        FileIOError(kind: .tooLarge(limit: maxBytes), message: "'\(path)' is larger than the \(maxBytes) byte limit")
    }
}
