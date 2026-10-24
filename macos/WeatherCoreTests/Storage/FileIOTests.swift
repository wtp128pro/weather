// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FileIOTests.swift - ports the /fileio/* file cases of
// src/storage/test-storage.c (registrations :4617-4625) to Swift Testing.
// Every file lives in a per-test TemporaryDirectory; the C test's link-time
// syscall interposition (test-storage.c:40-131) is replaced by the injected
// FileIO.Syscalls seam. Expected values are the C test's literals (path:line).

import Darwin
import Foundation
import Synchronization
import Testing
@testable import WeatherCore

@Suite struct FileIOTests {
    /// The C fixture's private directory (test-storage.c:138-155).
    let tmp: TemporaryDirectory
    var dir: String {
        let p = tmp.url.path(percentEncoded: false)
        return p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    init() throws {
        tmp = try TemporaryDirectory("fileio")
    }

    private func pathIn(_ name: String) -> String {
        dir + "/" + name
    }

    // C: /fileio/roundtrip (test-storage.c:235-270)
    @Test func fileioRoundtrip() throws {
        let path = pathIn("a/b/c/data.bin") // parents are created
        let data = Data([0x68, 0x69, 0x00, 0x78, 0x0A]) // {'h','i','\0','x','\n'} :240
        try FileIO.writeAtomic(path: path, data: data)
        #expect(Probe.mode(path) == 0o600) // :244

        var got = try FileIO.readBounded(path: path, maxBytes: 1024)
        #expect(got.count == 5) // :250 sizeof data
        #expect(got == data) // :251

        // Overwrite with different (shorter) content: the old bytes must not remain.
        try FileIO.writeAtomic(path: path, data: Data("z".utf8))
        got = try FileIO.readBounded(path: path, maxBytes: 1024)
        #expect(got.count == 1) // :260
        #expect(got == Data("z".utf8)) // :261

        #expect(Probe.count(FileIO.dirname(of: path)) == 1, "temp file left behind") // :264

        // Empty content is valid.
        try FileIO.writeAtomic(path: path, data: Data())
        got = try FileIO.readBounded(path: path, maxBytes: 0)
        #expect(got.count == 0) // :269
    }

    // C: /fileio/read-limits (test-storage.c:272-314)
    @Test func fileioReadLimits() throws {
        let path = pathIn("r.txt")
        try Probe.put(path, "0123456789")

        let got = try FileIO.readBounded(path: path, maxBytes: 10) // exactly at the limit
        #expect(got.count == 10) // :281

        #expect(Probe.failure { try FileIO.readBounded(path: path, maxBytes: 9) } == .tooLarge(limit: 9)) // :284-285

        let missing = pathIn("missing.txt")
        #expect(Probe.failure { try FileIO.readBounded(path: missing, maxBytes: 10) } == .posix(ENOENT)) // :291-292

        // A directory and a FIFO are not regular files; the FIFO must not block.
        #expect(Probe.failure { try FileIO.readBounded(path: dir, maxBytes: 10) } == .notRegularFile) // :296-297
        let fifo = pathIn("fifo")
        #expect(mkfifo(fifo, 0o600) == 0) // :300
        #expect(Probe.failure { try FileIO.readBounded(path: fifo, maxBytes: 10) } == .notRegularFile) // :301-302

        // A sparse file far beyond the limit is rejected without reading it.
        let big = pathIn("big")
        try Probe.put(big, "x")
        #expect(truncate(big, off_t(1) << 40) == 0) // :308
        #expect(Probe.failure { try FileIO.readBounded(path: big, maxBytes: 1024) } == .tooLarge(limit: 1024)) // :309-310
    }

    // C: /fileio/write-failures (test-storage.c:316-357)
    @Test func fileioWriteFailures() throws {
        // Target is a non-empty directory: rename() fails after the temp file was
        // fully written; the temp file must be cleaned up and the target untouched.
        let dirTarget = pathIn("target")
        #expect(mkdir(dirTarget, 0o700) == 0)
        try Probe.put(dirTarget + "/keep", "keep")
        #expect(Probe.failure { try FileIO.writeAtomic(path: dirTarget, data: Data("new".utf8)) } == .posix(EISDIR)) // :328-329
        #expect(Probe.count(dir) == 1) // :331
        #expect(Probe.count(dirTarget) == 1) // :332

        // A parent component that is a regular file.
        let file = pathIn("plain")
        try Probe.put(file, "x")
        let below = file + "/sub/x.json"
        #expect(Probe.failure { try FileIO.writeAtomic(path: below, data: Data("new".utf8)) } == .posix(ENOTDIR)) // :338-341

        // Read-only target directory: the previous content survives, no stray temp.
        let roDir = pathIn("ro")
        #expect(mkdir(roDir, 0o700) == 0)
        let roFile = roDir + "/data.json"
        try Probe.put(roFile, "old")
        #expect(chmod(roDir, 0o500) == 0) // make_read_only :211-220
        defer { _ = chmod(roDir, 0o700) }
        try #require(access(roDir, W_OK) != 0, "directory permissions are not enforced for this user")
        #expect(Probe.failure { try FileIO.writeAtomic(path: roFile, data: Data("new".utf8)) } == .posix(EACCES)) // :350-351
        #expect(try Probe.text(roFile) == "old") // :354-355
        #expect(Probe.count(roDir) == 1) // :356
    }

    // C: /fileio/stale-temps (test-storage.c:370-428; the loader part :414-427 belongs to the store units)
    @Test func fileioStaleTemps() throws {
        let path = pathIn("cache.json")
        try Probe.put(path, "{}")
        let oldTmp = pathIn("cache.json.wx-tmp-AbC123")
        let newTmp = pathIn("cache.json.wx-tmp-zzZZ99")
        let other = pathIn("cache.json.bak")
        let other2 = pathIn("cache.json.wx-tmp-ab-123") // not alphanumeric
        let foreign = pathIn("other.json.wx-tmp-AbC123") // another file's temp
        let dirTmp = pathIn("cache.json.wx-tmp-DIR123") // not a regular file
        // User copies a 6-character suffix could collide with: never removed (:383-385).
        let userNames = ["cache.json.backup", "cache.json.2026Q3", "cache.json.old123",
                         "cache.json.before", "cache.json.AbC123", "cache.json.wx-tmp-AbC1234",
                         "cache.json.wx-tmp-AbC12", "cache.json.wx-tmp-", "cache.json.wx-tmpAbC123"]
        for name in userNames {
            try Probe.put(pathIn(name), "u")
            try Probe.age(pathIn(name), seconds: 3600)
        }
        try Probe.put(oldTmp, "x")
        try Probe.put(newTmp, "y")
        try Probe.put(other, "z")
        try Probe.put(other2, "z")
        try Probe.put(foreign, "z")
        #expect(mkdir(dirTmp, 0o700) == 0)
        for p in [oldTmp, other, other2, foreign, dirTmp] {
            try Probe.age(p, seconds: 3600)
        }

        FileIO.removeStaleTemps(path: path)
        #expect(!Probe.exists(oldTmp)) // :404
        #expect(Probe.exists(newTmp), "a write may be running") // :405
        #expect(Probe.exists(other)) // :406
        #expect(Probe.exists(other2)) // :407
        #expect(Probe.exists(foreign)) // :408
        #expect(Probe.isDirectory(dirTmp)) // :409
        #expect(Probe.exists(path)) // :410
        for name in userNames {
            #expect(Probe.exists(pathIn(name)), "\(name) was removed")
        }

        // A missing directory is not an error.
        FileIO.removeStaleTemps(path: pathIn("nodir/x.json")) // :413-414
        #expect(!Probe.exists(pathIn("nodir")))
    }

    // C: /fileio/stale-temps (age threshold: "more than 60 seconds", wx-fileio.h:131,
    // STALE_TEMP_AGE_SECONDS 60 and difftime(now, mtime) > 60, wx-fileio.c:210,280)
    @Test func fileioStaleTempsAgeThreshold() throws {
        #expect(FileIO.staleTempAgeSeconds == 60) // wx-fileio.c:210
        let path = pathIn("places.json")
        let stale = pathIn("places.json.wx-tmp-Old120")
        let young = pathIn("places.json.wx-tmp-New030")
        try Probe.put(stale, "x")
        try Probe.put(young, "y")
        try Probe.age(stale, seconds: 120)
        try Probe.age(young, seconds: 30)
        FileIO.removeStaleTemps(path: path)
        #expect(!Probe.exists(stale), "a temp 120 s old must be removed")
        #expect(Probe.exists(young), "a temp 30 s old must be kept")
    }

    // C: /fileio/stale-temps-symlinks (test-storage.c:635-669)
    @Test func fileioStaleTempsSymlinks() throws {
        let path = pathIn("places.json")
        try Probe.put(path, "{}")
        try Probe.age(path, seconds: 3600)
        let goodLink = pathIn("places.json.wx-tmp-LINK01")
        let deadLink = pathIn("places.json.wx-tmp-LINK02")
        let dirLink = pathIn("places.json.wx-tmp-LINK03")
        #expect(symlink("places.json", goodLink) == 0)
        #expect(symlink("does-not-exist", deadLink) == 0)
        #expect(symlink(".", dirLink) == 0)
        // Age the links themselves (not their targets).
        for link in [goodLink, deadLink, dirLink] {
            try Probe.age(link, seconds: 3600, followLinks: false)
        }

        FileIO.removeStaleTemps(path: path)
        // Only regular files are removed: a symlink is never judged by, or followed to, its target.
        #expect(Probe.isSymlink(goodLink)) // :660-661
        #expect(Probe.isSymlink(deadLink)) // :662-663
        #expect(Probe.isSymlink(dirLink)) // :664-665
        #expect(Probe.isRegular(path)) // :666
    }

    // C: /fileio/preconditions (test-storage.c:4087-4140): the cases Swift's types can express.
    @Test func fileioPreconditions() throws {
        let path = pathIn("x.bin")
        // Empty path (:4092-4097): refused, nothing created.
        #expect(Probe.failure { try FileIO.writeAtomic(path: "", data: Data("x".utf8)) } == .invalidArgument)
        #expect(!Probe.exists(path)) // :4102

        try Probe.put(path, "abc")
        #expect(Probe.failure { try FileIO.readBounded(path: "", maxBytes: 10) } == .invalidArgument) // :4116-4118
        // max_bytes < G_MAXSIZE / 4 (:4122-4124), with Swift's size type Int.
        #expect(Probe.failure { try FileIO.readBounded(path: path, maxBytes: Int.max / 4) } == .invalidArgument)
        #expect(Probe.failure { try FileIO.readBounded(path: path, maxBytes: -1) } == .invalidArgument)
        // A valid call still works (:4131-4133).
        #expect(try FileIO.readBounded(path: path, maxBytes: 10) == Data("abc".utf8))

        // Empty path: nothing happens (:4135-4140).
        FileIO.removeStaleTemps(path: "")
        // max_depth above 32 is refused (wx-fileio.h:191, wx-fileio.c:323).
        #expect(!StrictJSON.check(Data("[]".utf8), maxDepth: 33))
        #expect(StrictJSON.check(Data("[]".utf8), maxDepth: 32))
    }

    // C: /fileio/write-faults (test-storage.c:4474-4538)
    @Test func fileioWriteFaults() throws {
        let path = pathIn("data.bin")
        let payload = "0123456789abcdef" // :4479 (sizeof payload - 1 = 16 bytes)
        let plan = FaultPlan()

        // Interrupted and short writes are retried until everything is written.
        plan.update { $0.writeEINTR = 3; $0.writeOneByte = 5 } // :4483-4484
        try FileIO.writeAtomic(path: path, data: Data(payload.utf8), syscalls: plan.syscalls)
        #expect(plan.state.withLock { $0.writeEINTR == 0 && $0.writeOneByte == 0 }, "faults not consumed")
        plan.reset()
        #expect(try Probe.text(path) == payload) // :4488
        #expect(Probe.count(dir) == 1) // :4489

        // Each failing step reports its error, removes the temporary file and keeps the old content.
        let failures: [(what: String, arm: @Sendable (inout FaultPlan.Faults) -> Void, code: Int32)] = [
            ("write ENOSPC", { $0.writeErrno = ENOSPC }, ENOSPC), // :4498
            ("write EIO", { $0.writeErrno = EIO }, EIO), // :4499
            ("fsync EIO", { $0.fsyncErrno = EIO }, EIO), // :4500
            ("close EIO", { $0.closeErrno = EIO }, EIO), // :4501
        ]
        for failure in failures {
            plan.update(failure.arm)
            let kind = Probe.failure {
                try FileIO.writeAtomic(path: path, data: Data("replacement".utf8), syscalls: plan.syscalls)
            }
            plan.reset()
            #expect(kind == .posix(failure.code), "\(failure.what)") // :4508
            #expect(try Probe.text(path) == payload, "\(failure.what)") // :4510
            #expect(Probe.count(dir) == 1, "\(failure.what): temp file left behind") // :4511
        }
        // A failure of fsync() and a failure of close() together: the first error is reported.
        plan.update { $0.fsyncErrno = EIO; $0.closeErrno = ENOSPC } // :4514-4515
        let both = Probe.failure {
            try FileIO.writeAtomic(path: path, data: Data("replacement".utf8), syscalls: plan.syscalls)
        }
        plan.reset()
        #expect(both == .posix(EIO)) // :4518
        #expect(Probe.count(dir) == 1) // :4520
        #expect(try Probe.text(path) == payload) // :4525 (old content intact)

        // The directory flush is best effort: a directory that cannot be opened for
        // reading (mode 0300) does not turn a successful write into an error.
        let wdir = pathIn("wo")
        #expect(mkdir(wdir, 0o700) == 0)
        let wfile = wdir + "/x.bin"
        #expect(chmod(wdir, 0o300) == 0) // :4532
        let result = Result { () throws(FileIOError) in try FileIO.writeAtomic(path: wfile, data: Data("w".utf8)) }
        #expect(chmod(wdir, 0o700) == 0)
        #expect(throws: Never.self) { try result.get() } // :4535-4536
        #expect(try Probe.text(wfile) == "w") // :4537
    }

    // Executor-added, no C counterpart (extends /fileio/write-faults and
    // /fileio/roundtrip; U05 case-set row CX1): the write sequence of wx-fileio.c:85-120 —
    // a 0600 "<path>.wx-tmp-XXXXXX" temp in the same directory, flushed once
    // (F_FULLFSYNC seam) and closed BEFORE the rename, then the directory flush.
    @Test func fileioWriteSequenceAndTempFile() throws {
        let path = pathIn("seq.json")
        try Probe.put(path, "old")
        let plan = FaultPlan()
        plan.update { $0.recordCalls = true }
        try FileIO.writeAtomic(path: path, data: Data("new".utf8), syscalls: plan.syscalls)
        let log = plan.state.withLock { $0.calls }
        let syncs = log.filter { $0.hasPrefix("sync ") }
        try #require(syncs.count == 2, "calls: \(log)")
        let tempPath = String(syncs[0].dropFirst("sync ".count))
        let tempName = (tempPath as NSString).lastPathComponent
        let realDir = Probe.realPath(dir)
        #expect((tempPath as NSString).deletingLastPathComponent == realDir, "temp not in the target's directory: \(tempPath)")
        let infixAndSuffix = Array(tempName.utf8.dropFirst("seq.json".count))
        #expect(tempName.hasPrefix("seq.json.wx-tmp-") && infixAndSuffix.count == 14, "temp name \(tempName)")
        #expect(tempName.utf8.suffix(6).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7A) },
                "temp suffix of \(tempName) is not 6 ASCII alphanumerics (wx-fileio.h:127-128)")
        #expect(plan.state.withLock { $0.tempModeAtSync } == 0o600, "temp file mode (wx-fileio.h:42)")
        #expect(syncs[1] == "sync " + realDir, "directory flush (wx-fileio.c:119)")
        // Order: writes, flush(temp), close(temp), flush(dir), close(dir).
        let kinds = log.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        #expect(kinds.filter { $0 != "write" } == ["sync", "close", "sync", "close"], "calls: \(log)")
        #expect(try Probe.text(path) == "new")
        #expect(Probe.mode(path) == 0o600)
        #expect(!Probe.exists(tempPath))
    }

    // C: /fileio/read-faults (test-storage.c:4541-4601; /proc does not exist on macOS:
    // the "size unknown to fstat" file is simulated through the seam's fstat)
    @Test func fileioReadFaults() throws {
        let path = pathIn("r.txt")
        try Probe.put(path, "0123456789") // :4545
        let plan = FaultPlan()

        // Interrupted reads are retried.
        plan.update { $0.readEINTR = 3 } // :4551
        let got = try FileIO.readBounded(path: path, maxBytes: 100, syscalls: plan.syscalls)
        plan.reset()
        #expect(String(decoding: got, as: UTF8.self) == "0123456789") // :4555
        #expect(got.count == 10) // :4556

        // A failing read() or fstat() is reported and nothing is returned.
        plan.update { $0.readErrno = EIO } // :4560
        #expect(Probe.failure { try FileIO.readBounded(path: path, maxBytes: 100, syscalls: plan.syscalls) } == .posix(EIO)) // :4561-4563
        plan.reset()
        plan.update { $0.fstatErrno = EIO } // :4567
        #expect(Probe.failure { try FileIO.readBounded(path: path, maxBytes: 100, syscalls: plan.syscalls) } == .posix(EIO)) // :4568-4570
        plan.reset()

        // A file whose size is unknown to fstat() (st_size 0) is read by growing the
        // buffer, and the limit holds however much it delivers (:4574-4593).
        plan.update { $0.fstatZeroSize = true; $0.recordCalls = true }
        let all = try FileIO.readBounded(path: path, maxBytes: 1 << 20, syscalls: plan.syscalls)
        #expect(all.count > 1) // :4581
        let full = all.count
        #expect(try FileIO.readBounded(path: path, maxBytes: full, syscalls: plan.syscalls).count == full) // :4585-4586 exactly at the limit
        #expect(Probe.failure { try FileIO.readBounded(path: path, maxBytes: full - 1, syscalls: plan.syscalls) } == .tooLarge(limit: full - 1)) // :4588-4589 one byte over
        plan.update { $0.calls = [] }
        #expect(Probe.failure { try FileIO.readBounded(path: path, maxBytes: 0, syscalls: plan.syscalls) } == .tooLarge(limit: 0)) // :4592-4593 the empty limit
        // Never more than max_bytes + 1 bytes are requested (wx-fileio.h:91-93).
        let requested = plan.state.withLock { $0.calls }.filter { $0.hasPrefix("read ") }.compactMap { Int($0.dropFirst(5)) }
        #expect(requested.reduce(0, +) <= 1, "read requests with max_bytes 0: \(requested)")
        plan.reset()
    }

    // C: /fileio/modes-and-links (test-storage.c:4271-4312)
    @Test func fileioModesAndLinks() throws {
        // An existing directory keeps its mode; directories created on the way are 0700.
        let shared = pathIn("shared")
        #expect(mkdir(shared, 0o755) == 0)
        #expect(chmod(shared, 0o755) == 0)
        let path = shared + "/a/b/file.json"
        try FileIO.writeAtomic(path: path, data: Data("one".utf8))
        #expect(Probe.mode(shared) == 0o755) // :4284
        #expect(Probe.mode(shared + "/a") == 0o700) // :4285
        #expect(Probe.mode(shared + "/a/b") == 0o700) // :4286
        #expect(Probe.mode(path) == 0o600) // :4287
        // The mode of an existing file is not preserved: the result is private.
        #expect(chmod(path, 0o644) == 0)
        try FileIO.writeAtomic(path: path, data: Data("two".utf8))
        #expect(Probe.mode(path) == 0o600) // :4291
        #expect(try Probe.text(path) == "two") // :4292
        #expect(Probe.mode(shared + "/a/b") == 0o700) // :4293

        // A symbolic link at the destination is replaced, its target is not written.
        let real = pathIn("real.txt")
        let link = pathIn("link.txt")
        try Probe.put(real, "real")
        #expect(symlink("real.txt", link) == 0)
        try FileIO.writeAtomic(path: link, data: Data("replaced".utf8))
        #expect(Probe.isRegular(link)) // :4302-4303
        #expect(try Probe.text(link) == "replaced") // :4304
        #expect(try Probe.text(real) == "real") // :4305

        // Reading follows a symbolic link (documented).
        let link2 = pathIn("link2.txt")
        #expect(symlink("real.txt", link2) == 0)
        #expect(try FileIO.readBounded(path: link2, maxBytes: 100) == Data("real".utf8)) // :4311-4312
    }

    // Executor-added, no C counterpart (U05 case-set row CX2, PATHS criterion;
    // extends /fileio/roundtrip): every path comes from the caller — the
    // write lands exactly at the given path and nowhere else, and the
    // directory part is the GLib dirname of that path.
    @Test func fileioPathsComeFromCaller() throws {
        let path = pathIn("p/q.json")
        try FileIO.writeAtomic(path: path, data: Data("{}".utf8))
        #expect(Probe.count(dir) == 1, "entries under the caller's directory: \(Probe.names(dir))")
        #expect(Probe.names(pathIn("p")) == ["q.json"])
        #expect(try FileIO.readBounded(path: path, maxBytes: 2) == Data("{}".utf8))
        // g_path_get_dirname / g_path_get_basename semantics.
        #expect(FileIO.dirname(of: "a/b/c.json") == "a/b")
        #expect(FileIO.dirname(of: "c.json") == ".")
        #expect(FileIO.dirname(of: "/c.json") == "/")
        #expect(FileIO.dirname(of: "a//c.json") == "a")
        #expect(FileIO.basename(of: "a/b/c.json") == "c.json")
        #expect(FileIO.basename(of: "a/b/") == "b")
    }
}

// MARK: - Helpers

/// File-system probes used by the assertions (the C test's put_text,
/// count_files, file_mode, set_mtime_ago; test-storage.c:183-233, :360-366).
private enum Probe {
    static func put(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func text(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    /// realpath(3) (F_GETPATH reports /private/var/..., not /var/...).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func names(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    static func count(_ dir: String) -> Int {
        names(dir).count
    }

    static func lstatMode(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode : nil
    }

    static func mode(_ path: String) -> mode_t {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_mode & 0o7777 : 0xFFFF
    }

    static func exists(_ path: String) -> Bool { lstatMode(path) != nil }
    static func isDirectory(_ path: String) -> Bool { lstatMode(path).map { $0 & S_IFMT == S_IFDIR } ?? false }
    static func isRegular(_ path: String) -> Bool { lstatMode(path).map { $0 & S_IFMT == S_IFREG } ?? false }
    static func isSymlink(_ path: String) -> Bool { lstatMode(path).map { $0 & S_IFMT == S_IFLNK } ?? false }

    /// Sets atime and mtime `seconds` into the past (of the link itself when
    /// `followLinks` is false: utimensat AT_SYMLINK_NOFOLLOW, :648-656).
    static func age(_ path: String, seconds: Int, followLinks: Bool = true) throws {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        now.tv_sec -= seconds
        var times = [now, now]
        let rc = utimensat(AT_FDCWD, path, &times, followLinks ? 0 : AT_SYMLINK_NOFOLLOW)
        try #require(rc == 0, "utimensat(\(path)) failed: errno \(errno)")
    }

    /// The kind of the FileIOError `body` throws (nil when it does not throw).
    static func failure<R>(_ body: () throws -> R) -> FileIOError.Kind? {
        do {
            _ = try body()
            return nil
        } catch let error as FileIOError {
            return error.kind
        } catch {
            Issue.record("unexpected error type: \(error)")
            return nil
        }
    }
}

/// The C test's thread-local fault plan (test-storage.c:49-58) as an injected
/// FileIO.Syscalls value; unarmed calls forward to the kernel.
private final class FaultPlan: Sendable {
    struct Faults {
        var writeEINTR = 0 // the next n write() calls fail with EINTR
        var writeOneByte = 0 // the next n write() calls write at most one byte
        var writeErrno: Int32 = 0 // every write() fails with this errno when non-zero
        var fsyncErrno: Int32 = 0 // every flush fails with this errno when non-zero
        var closeErrno: Int32 = 0 // the next close() closes the fd, then reports this
        var readEINTR = 0 // the next n read() calls fail with EINTR
        var readErrno: Int32 = 0 // every read() fails with this errno when non-zero
        var fstatErrno: Int32 = 0 // every fstat() fails with this errno when non-zero
        var fstatZeroSize = false // fstat() reports st_size 0 (a /proc-like file)
        var recordCalls = false
        var calls: [String] = []
        var tempModeAtSync: mode_t = 0
    }

    let state = Mutex(Faults())

    func update(_ body: (inout Faults) -> Void) {
        state.withLock { body(&$0) }
    }

    func reset() {
        state.withLock { $0 = Faults() }
    }

    private static func pathOf(_ fd: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return "?" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    var syscalls: FileIO.Syscalls {
        let system = FileIO.Syscalls.system
        return FileIO.Syscalls(
            write: { [plan = self] fd, buffer, count in
                var n = count
                let injected: Int? = plan.state.withLock { f in
                    if f.recordCalls { f.calls.append("write \(count)") }
                    if f.writeEINTR > 0 { f.writeEINTR -= 1; return -Int(EINTR) }
                    if f.writeErrno != 0 { return -Int(f.writeErrno) }
                    if f.writeOneByte > 0 && count > 1 { f.writeOneByte -= 1; n = 1 }
                    return nil
                }
                return injected ?? system.write(fd, buffer, n)
            },
            read: { [plan = self] fd, buffer, count in
                let injected: Int? = plan.state.withLock { f in
                    if f.recordCalls { f.calls.append("read \(count)") }
                    if f.readEINTR > 0 { f.readEINTR -= 1; return -Int(EINTR) }
                    if f.readErrno != 0 { return -Int(f.readErrno) }
                    return nil
                }
                return injected ?? system.read(fd, buffer, count)
            },
            fullSync: { [plan = self] fd in
                let path = FaultPlan.pathOf(fd)
                var st = stat()
                let mode = Darwin.fstat(fd, &st) == 0 ? st.st_mode & 0o7777 : 0
                let injected: Int32? = plan.state.withLock { f in
                    if f.recordCalls {
                        if f.calls.firstIndex(where: { $0.hasPrefix("sync ") }) == nil { f.tempModeAtSync = mode }
                        f.calls.append("sync \(path)")
                    }
                    return f.fsyncErrno != 0 ? -f.fsyncErrno : nil
                }
                return injected ?? system.fullSync(fd)
            },
            close: { [plan = self] fd in
                let rc = system.close(fd)
                return plan.state.withLock { f in
                    if f.recordCalls { f.calls.append("close") }
                    if rc == 0 && f.closeErrno != 0 {
                        let e = f.closeErrno
                        f.closeErrno = 0
                        return -e
                    }
                    return rc
                }
            },
            fstat: { [plan = self] fd, status in
                if let e: Int32 = plan.state.withLock({ $0.fstatErrno != 0 ? $0.fstatErrno : nil }) {
                    return -e
                }
                let rc = system.fstat(fd, status)
                if rc == 0 && plan.state.withLock({ $0.fstatZeroSize }) {
                    status.pointee.st_size = 0
                }
                return rc
            }
        )
    }
}
