// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StoreJSONTests.swift - the shared loader pieces of the storage module
// (port of the /store-json/helpers case of src/storage/test-storage.c) and the
// generic store tests that test-storage.c runs for places, settings and cache
// (the StoreOps table, test-storage.c:1095-1108, 1325-1333). PlacesTests and
// SettingsTests call the generic bodies with their own StoreOps; the cache
// unit can add a third conformer.
//
// JSON inputs are written with Swift escapes that produce the same bytes as
// the C literals (\" \\ \t \n mean the same in both languages); a JSON escape
// such as backslash-u0000 stays TEXT ("\\u0000" in the source).

import Darwin
import Foundation
import Testing
@testable import WeatherCore

@Suite struct StoreJSONTests {
    // MARK: - Generic store harness

    /// One store class under test (StoreOps, test-storage.c:1095-1108).
    protocol StoreOps {
        associatedtype Store: AnyObject
        /// The document name ("places", "settings").
        static var name: String { get }
        static var maxFileBytes: Int { get }
        /// doc_prefix (test-storage.c:1325-1333): the smallest valid document
        /// up to, not including, its closing brace.
        static var docPrefix: String { get }
        static func create(_ path: String) throws -> Store
        /// One distinct, always accepted edit per step (places_mutate /
        /// settings_mutate, test-storage.c:1116-1121 and 1147-1152).
        static func mutate(_ s: Store, _ step: Int) throws
        static func isDirty(_ s: Store) -> Bool
        static func save(_ s: Store) throws(WxStoreError)
        static func load(_ s: Store) throws(WxStoreError)
        /// A string that is equal for equal contents (order included).
        static func fingerprint(_ s: Store) -> String
        static func setOnChanged(_ s: Store, _ body: @escaping () -> Void)
        static func beginSave(_ s: Store) throws(WxStoreError) -> StoreJSON.SaveJob
        static func finishSave(_ s: Store, _ job: StoreJSON.SaveJob, _ outcome: Result<Void, WxStoreError>) throws(WxStoreError)
        static func saveAsync(_ s: Store) async throws(WxStoreError)
    }

    // MARK: - File helpers (test-storage.c:181-232, 359-366)

    /// Runs `body` and returns the error it threw, or nil.
    static func caught(_ body: () throws(WxStoreError) -> Void) -> WxStoreError? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }

    static func isParse(_ e: WxStoreError?) -> Bool {
        if case .parse? = e {
            return true
        }
        return false
    }

    static func isPending(_ e: WxStoreError?) -> Bool {
        if case .pending? = e {
            return true
        }
        return false
    }

    static func fileKind(_ e: WxStoreError?) -> FileIOError.Kind? {
        if case .file(let f)? = e {
            return f.kind
        }
        return nil
    }

    static func putFile(_ path: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    static func putText(_ path: String, _ text: String) throws {
        try putFile(path, Array(text.utf8))
    }

    static func readAll(_ path: String) throws -> String {
        let data = try #require(FileManager.default.contents(atPath: path), "cannot read \(path)")
        return String(decoding: data, as: UTF8.self)
    }

    static func countFiles(_ dir: String) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: dir).count
    }

    static func fileMode(_ path: String) -> mode_t {
        var st = stat()
        guard stat(path, &st) == 0 else {
            return 0
        }
        return st.st_mode & 0o7777
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// chmod 0500; false when that cannot block writes (make_read_only, test-storage.c:209-219).
    static func makeReadOnly(_ dir: String) -> Bool {
        _ = chmod(dir, 0o500)
        if access(dir, W_OK) == 0 {
            _ = chmod(dir, 0o700)
            return false
        }
        return true
    }

    static func setMtimeAgo(_ path: String, _ seconds: Int) {
        var tv = [timeval](repeating: timeval(), count: 2)
        gettimeofday(&tv[0], nil)
        tv[0].tv_sec -= seconds
        tv[1] = tv[0]
        _ = utimes(path, &tv)
    }

    /// `depth` openers then `depth` closers (nested, test-storage.c:431-439).
    static func nested(_ depth: Int, _ open: Character, _ close: Character) -> String {
        String(repeating: open, count: depth) + String(repeating: close, count: depth)
    }

    // MARK: - Shared C inputs

    /// The documents every store refuses with a parse error
    /// (test_store_load_errors, test-storage.c:1384-1415), as the bytes the C
    /// compiler produced.
    static let badDocuments: [[UInt8]] = [
        Array("".utf8),
        Array(" ".utf8),
        Array("not json at all".utf8),
        Array("[]".utf8),
        Array("null".utf8),
        Array("123".utf8),
        Array("\"text\"".utf8),
        Array("{}".utf8),
        Array("{\"version\":0}".utf8),
        Array("{\"version\":2}".utf8),
        Array("{\"version\":-1}".utf8),
        Array("{\"version\":\"1\"}".utf8),
        Array("{\"version\":1.0}".utf8),
        Array("{\"version\":1.5}".utf8),
        Array("{\"version\":true}".utf8),
        Array("{\"version\":null}".utf8),
        Array("{\"version\":[1]}".utf8),
        Array("{\"version\":9223372036854775808}".utf8),
        Array("{\"version\":1".utf8), // truncated
        Array("{\"version\":1,}".utf8), // trailing comma
        Array("{\"version\":1}{".utf8), // trailing bytes
        Array("{\"version\":1} x".utf8),
        Array("{'version':1}".utf8), // single quotes
        Array("/* c */ {\"version\":1}".utf8), // comments
        Array("// c\n{\"version\":1}".utf8),
        [0xEF, 0xBB, 0xBF] + Array("{\"version\":1}".utf8), // a byte-order mark
        [0xFF, 0xFE] + Array("{\"version\":1}".utf8),
        Array("{\"version\":1,\"x\":\"a\tb\"}".utf8), // raw control byte in a string
        Array("{\"version\":1,\"x\":\"\\x\"}".utf8), // bad escape
        Array("{\"version\":1,\"version\":1,\"x\":tru}".utf8),
    ]

    /// Payloads that hid later brackets from a naive depth scan
    /// (bypass_prefixes, test-storage.c:736-738).
    static let bypassPrefixes: [String] = [
        "['\"',", "/*\"*/", "// \"\n", "/* ' */ ['\"',", "'\"'", "# \"\n", "\"\\", "\"\\u12\"",
    ]

    // MARK: - Generic store tests

    // C: /store/roundtrip (test_store_roundtrip_and_files, test-storage.c:1335-1378)
    static func roundtripAndFiles<O: StoreOps>(_ ops: O.Type) throws {
        let tmp = try TemporaryDirectory("store-roundtrip")
        let path = tmp.appending("cfg/weather/data.json").path
        let o = try O.create(path)
        #expect(!O.isDirty(o))
        for i in 0 ..< 3 {
            try O.mutate(o, i)
        }
        #expect(O.isDirty(o))
        #expect(caught { () throws(WxStoreError) in try O.save(o) } == nil)
        #expect(!O.isDirty(o))
        #expect(fileMode(path) == 0o600)
        let dir = (path as NSString).deletingLastPathComponent
        #expect(try countFiles(dir) == 1, "no temp file left")

        // The file passes the strict gate (writers never produce what loaders reject).
        let text = try readAll(path)
        #expect(StrictJSON.check(Array(text.utf8)))
        #expect(text.utf8.count < O.maxFileBytes)

        let o2 = try O.create(path)
        #expect(caught { () throws(WxStoreError) in try O.load(o2) } == nil)
        #expect(!O.isDirty(o2))
        let fp1 = O.fingerprint(o)
        #expect(fp1 == O.fingerprint(o2))
        #expect(fp1 != "")

        // Saving the loaded object writes the same bytes.
        #expect(caught { () throws(WxStoreError) in try O.save(o2) } == nil)
        #expect(try readAll(path) == text)
        #expect(try countFiles(dir) == 1)
    }

    // C: /store/load-errors (test_store_load_errors, test-storage.c:1380-1478)
    static func loadErrors<O: StoreOps>(_ ops: O.Type) throws {
        let tmp = try TemporaryDirectory("store-load-errors")
        let path = tmp.appending("data.json").path
        let fresh = O.fingerprint(try O.create("/nonexistent/never-used.json"))
        let o = try O.create(path)
        var changed = 0
        O.setOnChanged(o) { changed += 1 }

        // No file: NOENT, nothing else.
        let missing = caught { () throws(WxStoreError) in try O.load(o) }
        #expect(missing?.isNotFound == true, "\(String(describing: missing))")
        #expect(!O.isDirty(o))

        for (i, doc) in badDocuments.enumerated() {
            try O.mutate(o, 0) // the load must replace this
            try putFile(path, doc)
            let e = caught { () throws(WxStoreError) in try O.load(o) }
            #expect(isParse(e), "document \(i): \(String(describing: e))")
            #expect(O.fingerprint(o) == fresh, "document \(i): emptied / defaults")
            #expect(!O.isDirty(o), "document \(i)")
        }

        // Too large: exactly at the limit is read (and then rejected as JSON), one more is refused.
        try putFile(path, [UInt8](repeating: 0x20, count: O.maxFileBytes + 1))
        let big = caught { () throws(WxStoreError) in try O.load(o) }
        #expect(fileKind(big) == .tooLarge(limit: O.maxFileBytes), "\(String(describing: big))")
        try putFile(path, [UInt8](repeating: 0x20, count: O.maxFileBytes))
        #expect(isParse(caught { () throws(WxStoreError) in try O.load(o) }), "only blanks: read in full, not JSON")

        // A directory, a FIFO.
        #expect(unlink(path) == 0)
        #expect(mkdir(path, 0o700) == 0)
        #expect(fileKind(caught { () throws(WxStoreError) in try O.load(o) }) == .notRegularFile)
        #expect(rmdir(path) == 0)
        #expect(mkfifo(path, 0o600) == 0)
        #expect(fileKind(caught { () throws(WxStoreError) in try O.load(o) }) == .notRegularFile)
        #expect(unlink(path) == 0)

        // Emptying a non-empty object (places) or resetting (settings) announced it.
        #expect(changed > 0)
    }

    // C: /store/hostile-nesting (test_store_hostile_nesting, test-storage.c:1480-1525)
    static func hostileNesting<O: StoreOps>(_ ops: O.Type) throws {
        let tmp = try TemporaryDirectory("store-hostile")
        let path = tmp.appending("data.json").path
        let fresh = O.fingerprint(try O.create("/nonexistent/never-used.json"))
        let o = try O.create(path)

        // The whole permitted file size of '[': a parse error, not a stack overflow.
        try putFile(path, [UInt8](repeating: UInt8(ascii: "["), count: O.maxFileBytes))
        #expect(isParse(caught { () throws(WxStoreError) in try O.load(o) }))

        // Prefixes that hid later brackets from a naive depth scan.
        for prefix in bypassPrefixes {
            let p = Array(prefix.utf8)
            try putFile(path, p + [UInt8](repeating: UInt8(ascii: "["), count: O.maxFileBytes - 64 - p.count))
            #expect(isParse(caught { () throws(WxStoreError) in try O.load(o) }), "\(prefix)")
        }

        // Deep nesting inside an otherwise valid document, at and beyond the limit.
        for depth in 31 ... 34 {
            try putText(path, O.docPrefix + ", \"x\":" + nested(depth, "[", "]") + "}")
            let e = caught { () throws(WxStoreError) in try O.load(o) }
            // depth + 1 for the document object itself: 31 inner levels pass, 32 do not.
            if depth <= 31 {
                #expect(e == nil, "depth \(depth): \(String(describing: e))")
            } else {
                #expect(isParse(e), "depth \(depth)")
            }
        }
        #expect(O.fingerprint(o) == fresh)
    }

    // C: /store/save-failure (test_store_save_failure, test-storage.c:1527-1573)
    static func saveFailure<O: StoreOps>(_ ops: O.Type) throws {
        let tmp = try TemporaryDirectory("store-save-failure")
        // The target is a directory: the error is reported, the object stays dirty.
        let dirTarget = tmp.appending("target").path
        #expect(mkdir(dirTarget, 0o700) == 0)
        var o = try O.create(dirTarget)
        try O.mutate(o, 0)
        let e = caught { () throws(WxStoreError) in try O.save(o) }
        #expect(fileKind(e) == .posix(EISDIR), "\(String(describing: e))")
        #expect(O.isDirty(o))
        #expect(caught { () throws(WxStoreError) in try O.save(o) } != nil)
        #expect(try countFiles(tmp.url.path) == 1)
        #expect(rmdir(dirTarget) == 0)

        // Read-only directory: the previous file survives.
        let roDir = tmp.appending("ro").path
        #expect(mkdir(roDir, 0o700) == 0)
        let path = roDir + "/data.json"
        o = try O.create(path)
        try O.mutate(o, 0)
        #expect(caught { () throws(WxStoreError) in try O.save(o) } == nil)
        let before = try readAll(path)
        try O.mutate(o, 1)
        if makeReadOnly(roDir) {
            let ro = caught { () throws(WxStoreError) in try O.save(o) }
            #expect(fileKind(ro) == .posix(EACCES), "\(String(describing: ro))")
            #expect(O.isDirty(o))
            _ = chmod(roDir, 0o700)
            #expect(try readAll(path) == before)
            #expect(try countFiles(roDir) == 1)
        }
        #expect(caught { () throws(WxStoreError) in try O.save(o) } == nil)
        #expect(!O.isDirty(o))
    }

    // C: /store/save-async (test_store_save_async, test-storage.c:1575-1641)
    static func saveAsyncSnapshot<O: StoreOps>(_ ops: O.Type) async throws {
        let tmp = try TemporaryDirectory("store-save-async")
        let path = tmp.appending("cfg/data.json").path
        let o = try O.create(path)
        for i in 0 ..< 3 {
            try O.mutate(o, i)
        }
        let fpSnapshot = O.fingerprint(o)

        let job = try O.beginSave(o)
        // While one runs a second save, a sync save and a load are refused; nothing is synchronous.
        #expect(isPending(caught { () throws(WxStoreError) in _ = try O.beginSave(o) }))
        #expect(!exists(path), "nothing is written before the job runs")
        #expect(isPending(caught { () throws(WxStoreError) in try O.save(o) }))
        #expect(O.isDirty(o))
        #expect(isPending(caught { () throws(WxStoreError) in try O.load(o) }))
        #expect(O.isDirty(o), "a refused load changes nothing")
        #expect(O.fingerprint(o) == fpSnapshot)
        var second: WxStoreError?
        do {
            try await O.saveAsync(o)
        } catch {
            second = error
        }
        #expect(isPending(second))
        // Editing after the snapshot is allowed and keeps the object dirty.
        try O.mutate(o, 3)

        let outcome = await job.perform()
        #expect(caught { () throws(WxStoreError) in try O.finishSave(o, job, outcome) } == nil)
        #expect(O.isDirty(o), "the edit after the snapshot")

        // The file holds the snapshot (3 steps), not the later edit.
        let o2 = try O.create(path)
        #expect(caught { () throws(WxStoreError) in try O.load(o2) } == nil)
        #expect(O.fingerprint(o2) == fpSnapshot)

        // A new save after completion is accepted and clears the dirty flag.
        var third: WxStoreError?
        do {
            try await O.saveAsync(o)
        } catch {
            third = error
        }
        #expect(third == nil)
        #expect(!O.isDirty(o))
        #expect(try countFiles(tmp.url.path) == 1)
        #expect(try countFiles(tmp.appending("cfg").path) == 1)
        #expect(fileMode(path) == 0o600)
    }

    // C: /store/save-async-failure-and-cancel (test-storage.c:1643-1704)
    static func saveAsyncFailureAndCancel<O: StoreOps>(_ ops: O.Type) async throws {
        let tmp = try TemporaryDirectory("store-save-cancel")
        let dir = tmp.appending("ro").path
        #expect(mkdir(dir, 0o700) == 0)
        let path = dir + "/data.json"
        let o = try O.create(path)
        try O.mutate(o, 0)

        // Cancelled before it starts: nothing is written, the object stays dirty.
        let job = try O.beginSave(o)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await job.perform()
        }.value
        #expect(caught { () throws(WxStoreError) in try O.finishSave(o, job, cancelled) } == .cancelled)
        #expect(O.isDirty(o))
        #expect(try countFiles(dir) == 0)

        // Not cancelled, directory not writable: the error is reported, the old file survives.
        #expect(caught { () throws(WxStoreError) in try O.save(o) } == nil)
        try O.mutate(o, 1)
        if makeReadOnly(dir) {
            var failure: WxStoreError?
            do {
                try await O.saveAsync(o)
            } catch {
                failure = error
            }
            #expect(fileKind(failure) == .posix(EACCES), "\(String(describing: failure))")
            #expect(O.isDirty(o))
            _ = chmod(dir, 0o700)
            #expect(try countFiles(dir) == 1)
        }

        // After a failure a new save is accepted (the in-flight flag was reset).
        var again: WxStoreError?
        do {
            try await O.saveAsync(o)
        } catch {
            again = error
        }
        #expect(again == nil)
        #expect(!O.isDirty(o))

        // A cancellation after completion changes nothing.
        try O.mutate(o, 2)
        let job2 = try O.beginSave(o)
        let late = Task { await job2.perform() }
        let outcome = await late.value
        late.cancel() // after completion: nothing happens
        #expect(caught { () throws(WxStoreError) in try O.finishSave(o, job2, outcome) } == nil)
        #expect(!O.isDirty(o))
    }

    // C: /store/save-async-many (test_store_save_async_many, test-storage.c:1750-1770)
    static func saveAsyncMany<O: StoreOps>(_ ops: O.Type) async throws {
        let tmp = try TemporaryDirectory("store-save-many")
        let path = tmp.appending("data.json").path
        let o = try O.create(path)
        for i in 0 ..< 30 {
            if i < 12 {
                try O.mutate(o, i) // 12 distinct steps are valid for every class (cap: 16 ids)
            }
            var failure: WxStoreError?
            do {
                try await O.saveAsync(o)
            } catch {
                failure = error
            }
            #expect(failure == nil, "save \(i)") // the later saves write an unchanged object
        }
    }

    // C: /store/stale-temps (test_store_stale_temps_removed_by_load, test-storage.c:1772-1792)
    static func staleTemps<O: StoreOps>(_ ops: O.Type) throws {
        let tmp = try TemporaryDirectory("store-stale")
        let path = tmp.appending("data.json").path
        let oldTmp = tmp.appending("data.json.wx-tmp-QqQq00").path
        let young = tmp.appending("data.json.wx-tmp-YYYY11").path
        try putText(oldTmp, "x")
        try putText(young, "y")
        setMtimeAgo(oldTmp, 3600)
        let o = try O.create(path)
        #expect(caught { () throws(WxStoreError) in try O.load(o) } != nil) // no file
        #expect(!exists(oldTmp))
        #expect(exists(young))
    }

    /// expect_rejected (test-storage.c:3830-3846): the load fails with a parse
    /// error and leaves a fresh object.
    static func expectRejected<O: StoreOps>(_ ops: O.Type, _ path: String, _ text: String, _ label: String) throws {
        let fresh = O.fingerprint(try O.create("/nonexistent/never-used.json"))
        try putText(path, text)
        let o = try O.create(path)
        try O.mutate(o, 0) // the load must replace this
        let e = caught { () throws(WxStoreError) in try O.load(o) }
        #expect(isParse(e), "\(label): \(String(describing: e))")
        #expect(O.fingerprint(o) == fresh, "\(label)")
        #expect(!O.isDirty(o), "\(label)")
    }

    /// mutate_bytes (test-storage.c:3976-4021) with SeededRNG instead of GRand.
    private static func mutateBytes(_ r: inout SeededRNG, _ b: inout [UInt8]) {
        let structural: [UInt8] = [
            UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"),
            UInt8(ascii: "}"), UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "-"), UInt8(ascii: "0"),
            UInt8(ascii: "9"), UInt8(ascii: "e"), UInt8(ascii: "."), UInt8(ascii: "n"), UInt8(ascii: "t"),
            0x00, 0x01, 0x1F, 0x7F, 0xFF, 0xC3, 0x80,
        ]
        let rounds = 1 + Int.random(in: 0 ..< 4, using: &r)
        var k = 0
        while k < rounds && !b.isEmpty {
            k += 1
            let pos = Int.random(in: 0 ..< b.count, using: &r)
            switch Int.random(in: 0 ..< 8, using: &r) {
            case 0: // random byte
                b[pos] = UInt8.random(in: 0 ... 255, using: &r)
            case 1: // structural byte
                b[pos] = structural[Int.random(in: 0 ..< structural.count, using: &r)]
            case 2: // delete a range
                let want = Int.random(in: 1 ..< 40, using: &r)
                b.removeSubrange(pos ..< pos + min(want, b.count - pos))
            case 3: // duplicate a range: bytes [pos, pos + len) now appear twice
                let want = Int.random(in: 1 ..< 60, using: &r)
                let len = min(want, b.count - pos)
                b.insert(contentsOf: b[pos ..< pos + len], at: pos)
            case 4: // truncate
                b.removeSubrange(pos...)
            case 5: // insert structural bytes
                b.insert(structural[Int.random(in: 0 ..< structural.count, using: &r)], at: pos)
            case 6: // digit change
                b[pos] = UInt8(ascii: "0") + UInt8(Int.random(in: 0 ..< 10, using: &r))
            default: // flip one bit
                b[pos] ^= UInt8(1) << UInt8(Int.random(in: 0 ..< 8, using: &r))
            }
        }
    }

    // C: /store/fuzz (test_store_fuzz, test-storage.c:4025-4080)
    static func fuzz<O: StoreOps>(_ ops: O.Type, seed: UInt64) throws {
        let tmp = try TemporaryDirectory("store-fuzz")
        let seedPath = tmp.appending("seed.json").path
        let s = try O.create(seedPath)
        for i in 0 ..< 4 {
            try O.mutate(s, i)
        }
        #expect(caught { () throws(WxStoreError) in try O.save(s) } == nil)
        let seedText = Array(try readAll(seedPath).utf8)
        let fresh = O.fingerprint(try O.create("/nonexistent/never-used.json"))
        let path = tmp.appending("fuzz.json").path
        var r = SeededRNG(seed: seed)
        var okLoads = 0
        let iterations = fuzzIterations(4000)
        for iter in 0 ..< iterations {
            var b = seedText
            mutateBytes(&r, &b)
            try putFile(path, b)
            let l = try O.create(path)
            let e = caught { () throws(WxStoreError) in try O.load(l) }
            if let e {
                #expect(isParse(e), "iteration \(iter): \(e)")
                #expect(O.fingerprint(l) == fresh, "iteration \(iter)")
            } else {
                okLoads += 1
                let fp = O.fingerprint(l)
                // What loaded can be saved and loads back identically.
                #expect(caught { () throws(WxStoreError) in try O.save(l) } == nil, "iteration \(iter)")
                let l2 = try O.create(path)
                #expect(caught { () throws(WxStoreError) in try O.load(l2) } == nil, "iteration \(iter)")
                #expect(O.fingerprint(l2) == fp, "iteration \(iter)")
            }
        }
        // test-storage.c:4078 asserts more than 100 of 4000 loads succeed.
        #expect(okLoads * 4000 > 100 * iterations, "\(okLoads) of \(iterations) loads succeeded")
    }

    // MARK: - /store-json/helpers

    // C: /store-json/helpers (test_store_json_helpers, test-storage.c:4150-4260); the
    // precondition (critical) half is GLIB-INTERNAL.
    @Test func storeJSONHelpers() throws {
        // Node readers tolerate a missing node and wrong types.
        #expect(StoreJSON.nodeI64(nil) == nil)
        #expect(StoreJSON.nodeDouble(nil, allowNull: true) == nil)
        #expect(StoreJSON.nodeBool(nil) == nil)
        #expect(StoreJSON.nodeString(nil) == nil)
        #expect(StoreJSON.nodeObject(nil) == nil)
        #expect(StoreJSON.nodeArray(nil) == nil)

        let parsed = StoreJSON.Document.parse(Array("[1, 2.5, \"s\", true, null, {}, [], -0.0, 1e2]".utf8))
        guard case .success(let root?) = parsed, let a = StoreJSON.nodeArray(root), a.count == 9 else {
            Issue.record("the helper document did not parse: \(parsed)")
            return
        }
        let (nInt, nDbl, nStr, nBool, nNull, nObj, nArr, nNegz, nExp) = (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8])
        #expect(StoreJSON.nodeI64(nInt) == 1)
        #expect(StoreJSON.nodeI64(nDbl) == nil)
        #expect(StoreJSON.nodeI64(nExp) == nil, "1e2 is not an integer token")
        #expect(StoreJSON.nodeI64(nStr) == nil)
        #expect(StoreJSON.nodeI64(nNull) == nil)
        #expect(StoreJSON.nodeDouble(nInt, allowNull: false) == 1.0)
        #expect(StoreJSON.nodeDouble(nDbl, allowNull: false) == 2.5)
        let negz = try #require(StoreJSON.nodeDouble(nNegz, allowNull: false))
        #expect(negz == 0 && negz.sign == .minus)
        #expect(StoreJSON.nodeDouble(nStr, allowNull: true) == nil)
        #expect(StoreJSON.nodeDouble(nBool, allowNull: true) == nil)
        #expect(StoreJSON.nodeDouble(nNull, allowNull: false) == nil)
        expectNaN(try #require(StoreJSON.nodeDouble(nNull, allowNull: true)))
        #expect(StoreJSON.nodeDouble(nObj, allowNull: true) == nil)
        #expect(StoreJSON.nodeBool(nBool) == true)
        #expect(StoreJSON.nodeBool(nInt) == nil)
        #expect(StoreJSON.nodeString(nStr) == Array("s".utf8))
        #expect(StoreJSON.nodeString(nInt) == nil)
        #expect(StoreJSON.nodeString(nNull) == nil)
        #expect(StoreJSON.nodeObject(nObj) != nil)
        #expect(StoreJSON.nodeObject(nArr) == nil)
        #expect(StoreJSON.nodeArray(nArr) != nil)
        #expect(StoreJSON.nodeArray(nObj) == nil)

        // The root check.
        guard case .success(let q) = StoreJSON.Document.parse(Array("{\"version\":3,\"x\":1}".utf8)) else {
            Issue.record("the root document did not parse")
            return
        }
        #expect(throws: Never.self) { try StoreJSON.rootObject(q, what: "doc", version: 3) }
        var e: WxStoreError?
        do {
            _ = try StoreJSON.rootObject(q, what: "doc", version: 4)
        } catch {
            e = error
        }
        #expect(Self.isParse(e))
        #expect(e?.message.contains("doc") == true)
        e = nil
        do {
            _ = try StoreJSON.rootObject(nil, what: "doc", version: 3)
        } catch {
            e = error
        }
        #expect(Self.isParse(e))
        e = nil
        do {
            _ = try StoreJSON.rootObject(nArr, what: "doc", version: 3)
        } catch {
            e = error
        }
        #expect(Self.isParse(e))

        #expect(Self.isPending(StoreJSON.pendingError("doc")))

        // wx_store_load_json: a valid file loads; the error messages carry the document name.
        let tmp = try TemporaryDirectory("store-json-helpers")
        let path = tmp.appending("x.json").path
        try Self.putText(path, "{\"version\":1}")
        #expect(throws: Never.self) { try StoreJSON.load(path: path, maxBytes: 100, what: "doc") }
        try Self.putText(path, "nope")
        e = nil
        do {
            _ = try StoreJSON.load(path: path, maxBytes: 100, what: "mydoc")
        } catch {
            e = error
        }
        #expect(Self.isParse(e))
        #expect(e?.message.hasPrefix("mydoc:") == true, "\(String(describing: e))")
    }

    // MARK: - Per-place units (macOS; the C places.json has no "units")

    /// The root node of `text`, which must parse.
    private static func element(_ text: String) -> StoreJSON.Node? {
        if case .success(let node?) = StoreJSON.Document.parse(Array(text.utf8)) {
            return node
        }
        Issue.record("did not parse: \(text)")
        return nil
    }

    @Test func placeUnitsMember() {
        let base = "{\"name\": \"P\", \"lat\": 1, \"lon\": 2"
        #expect(StoreJSON.placeUnits(nil) == nil)
        #expect(StoreJSON.placeUnits(Self.element("[\"metric\"]")) == nil, "not an object")
        #expect(StoreJSON.placeUnits(Self.element(base + "}")) == nil)
        #expect(StoreJSON.placeUnits(Self.element(base + ", \"units\": \"metric\"}")) == .metric)
        #expect(StoreJSON.placeUnits(Self.element(base + ", \"units\": \"imperial\"}")) == .imperial)
        for bad in ["0", "1", "true", "null", "[]", "{}", "\"\"", "\"Metric\"", "\"IMPERIAL\"", "\"metric \"", "\"si\""] {
            #expect(StoreJSON.placeUnits(Self.element(base + ", \"units\": \(bad)}")) == nil, "units: \(bad)")
        }
    }

    /// Whatever its type, a "units" member never makes the place reader
    /// reject an element (which would drop the place).
    @Test func placeFromJSONIgnoresUnits() throws {
        let base = "{\"name\": \"P\", \"lat\": 1, \"lon\": 2"
        let plain = try #require(StoreJSON.placeFromJSON(Self.element(base + "}")))
        for units in ["\"metric\"", "\"imperial\"", "1", "null", "[]", "{}", "\"si\""] {
            #expect(StoreJSON.placeFromJSON(Self.element(base + ", \"units\": \(units)}")) == plain, "units: \(units)")
        }
    }

    @Test func appendPlaceUnits() throws {
        let p = try WxPlace(name: "P", lat: 1, lon: 2).withCustomLocation(customName: "Home", streetAddress: "1 Main St")
        var plain = ""
        StoreJSON.appendPlace(p, to: &plain)
        #expect(plain == "{\"name\": \"Home\", \"admin1\": \"1 Main St\", \"country\": \"\", \"country_code\": \"\", \"lat\": 1, \"lon\": 2, "
            + "\"timezone\": \"\", \"custom\": true, \"custom_name\": \"Home\", \"street_address\": \"1 Main St\"}")
        // No units: the bytes of the forecast cache's place are unchanged.
        var none = ""
        StoreJSON.appendPlace(p, units: nil, to: &none)
        #expect(none == plain)
        var metric = ""
        StoreJSON.appendPlace(p, units: .metric, to: &metric)
        #expect(metric == String(plain.dropLast()) + ", \"units\": \"metric\"}")
        var imperial = ""
        StoreJSON.appendPlace(p, units: .imperial, to: &imperial)
        #expect(imperial == String(plain.dropLast()) + ", \"units\": \"imperial\"}")
        #expect(StoreJSON.placeFromJSON(Self.element(metric)) == p)
        #expect(StoreJSON.placeUnits(Self.element(metric)) == .metric)
        #expect(StoreJSON.placeUnits(Self.element(imperial)) == .imperial)
    }
}
