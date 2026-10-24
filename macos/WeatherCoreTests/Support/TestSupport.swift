// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// TestSupport.swift - shared helpers of the WeatherCoreTests bundle: per-test
// temporary directories, the fixture loader, a deterministic random number
// generator, fuzz-iteration scaling and floating-point expectations.
//
// Parallel-test policy (every suite in this bundle follows it)
// ------------------------------------------------------------
// Swift Testing runs tests in parallel by default, in one process.
// 1. Timing-sensitive suites (deadlines, timers, schedulers driven by a real
//    clock) and suites that touch process-global state (environment
//    variables, shared singletons, the current directory) are declared
//    `@Suite(.serialized)`.
// 2. No test calls setenv/putenv for TZ, LANG, LC_* or any locale setting:
//    time zones (`TimeZone(identifier:)`), locales (`Locale(identifier:)`)
//    and calendars are injected into the code under test as parameters.
// 3. Deadline and timeout tests inject short timeouts (milliseconds) into the
//    code under test instead of waiting for production defaults, and use the
//    injected clock (WxClock/ManualClock) once it exists.
// 4. Slow cases (large fuzz loops, long soak runs) are gated by the
//    environment variable WEATHER_SLOW_TESTS: scale loops with
//    `fuzzIterations(_:)` and gate whole tests with
//    `@Test(.enabled(if: TestEnvironment.slowTestsEnabled))`.
//    xcodebuild forwards it with the TEST_RUNNER_ prefix:
//    `TEST_RUNNER_WEATHER_SLOW_TESTS=1 xcodebuild test -scheme Weather ...`.
// 5. The bundle is unhosted and not sandboxed, so FileManager's standard
//    directories resolve to the real ~/Library: no test touches ~/Library.
//    Every file a test writes lives in a `TemporaryDirectory` (under the
//    system temporary directory), injected into the code under test.
// 6. No test uses the real network; servers bind 127.0.0.1 only.
// 7. print() output is not visible in xcodebuild logs: put diagnostics into
//    #expect / #require comments or Issue.record.
// 8. Randomised tests use `SeededRNG` with a fixed seed recorded in the test,
//    never SystemRandomNumberGenerator, so a failure reproduces exactly.

import Foundation
import Testing

/// Environment switches read by tests.
enum TestEnvironment {
    /// The name of the environment variable that enables slow tests.
    static let slowTestsVariable = "WEATHER_SLOW_TESTS"

    /// The fuzz multiplier: 1 when WEATHER_SLOW_TESTS is unset, empty or "0";
    /// its integer value when it is an integer greater than 1; 10 for any
    /// other value (for example "1", "yes").
    static var slowTestsMultiplier: Int {
        multiplier(for: ProcessInfo.processInfo.environment[slowTestsVariable])
    }

    /// True when WEATHER_SLOW_TESTS enables slow tests (see `slowTestsMultiplier`).
    static var slowTestsEnabled: Bool { slowTestsMultiplier > 1 }

    /// The multiplier for a given value of WEATHER_SLOW_TESTS (nil = unset).
    static func multiplier(for value: String?) -> Int {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "0" else {
            return 1
        }
        if let n = Int(raw), n > 1 {
            return n
        }
        return 10
    }
}

/// The number of iterations a fuzz loop runs: `base` normally, `base` times
/// `TestEnvironment.slowTestsMultiplier` when WEATHER_SLOW_TESTS is set.
func fuzzIterations(_ base: Int) -> Int {
    base * TestEnvironment.slowTestsMultiplier
}

/// Expects `abs(actual - expected) <= eps` (equal infinities also pass; NaN
/// never does). Failures are reported at the caller's source location.
func expectNear(
    _ actual: Double,
    _ expected: Double,
    eps: Double,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let near = actual == expected || abs(actual - expected) <= eps
    #expect(
        near,
        "\(actual) is not within \(eps) of \(expected)\(comment.map { ": \($0.rawValue)" } ?? "")",
        sourceLocation: sourceLocation
    )
}

/// Expects `value` to be NaN. Failures are reported at the caller's source location.
func expectNaN(
    _ value: Double,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(value.isNaN, "\(value) is not NaN\(comment.map { ": \($0.rawValue)" } ?? "")", sourceLocation: sourceLocation)
}

/// A deterministic RandomNumberGenerator: SplitMix64 (Steele, Lea and Flood,
/// "Fast splittable pseudorandom number generators", OOPSLA 2014; the
/// reference constants of Vigna's splitmix64.c). The same seed always yields
/// the same sequence on every platform and run. It replaces GLib's GRand in
/// the ported fuzz tests: the C tests' oracles are kept, their exact random
/// sequences are not reproduced. Not cryptographically secure.
struct SeededRNG: RandomNumberGenerator, Sendable {
    /// The internal state (advanced by the golden-ratio increment per draw).
    private(set) var state: UInt64

    /// Creates a generator whose sequence is fully determined by `seed`.
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A uniquely named directory under the system temporary directory
/// (FileManager.default.temporaryDirectory), created on init and removed with
/// everything in it on deinit.
///
/// Keep the instance alive for as long as the directory is used: store it in
/// a stored property of the suite (one suite instance exists per test), or
/// use `TemporaryDirectory.with { url in ... }`. A local `let` whose last use
/// is `.url` may be released (and the directory removed) right after that use.
final class TemporaryDirectory: Sendable {
    /// The directory (exists until deinit).
    let url: URL

    /// Creates `<system temp>/WeatherCoreTests-<label>-<UUID>` with mode 0700.
    init(_ label: String = "test") throws {
        let name = "WeatherCoreTests-\(label)-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = dir
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// The URL of `relativePath` inside the directory (nothing is created).
    func appending(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// Runs `body` with a fresh temporary directory and removes it afterwards.
    static func with<R>(_ label: String = "test", _ body: (URL) throws -> R) throws -> R {
        let dir = try TemporaryDirectory(label)
        return try withExtendedLifetime(dir) { try body(dir.url) }
    }

    /// Async variant of `with(_:_:)`.
    static func with<R>(
        _ label: String = "test", _ body: (URL) async throws -> R
    ) async throws -> R {
        let dir = try TemporaryDirectory(label)
        let result = try await body(dir.url)
        withExtendedLifetime(dir) {}
        return result
    }
}

/// Loads fixture files copied into the WeatherCoreTests bundle.
///
/// Every file under macos/WeatherCoreTests/ that is not Swift (for example
/// `Fixtures/OpenMeteo/forecast-berlin.json`) is copied flat into the
/// bundle's Resources by the synchronized group, so fixture basenames must be
/// unique within the bundle (prefix them with the module, e.g. `nws-points.json`).
enum Fixtures {
    /// Thrown when no resource of that name is in the test bundle.
    struct NotFound: Error, CustomStringConvertible {
        let name: String
        let bundlePath: String
        var description: String { "fixture \(name) not found in \(bundlePath)" }
    }

    private final class BundleToken {}

    /// The WeatherCoreTests bundle (not Bundle.main, which is the xctest runner).
    static var bundle: Bundle { Bundle(for: BundleToken.self) }

    /// The URL of the fixture `name` ("forecast.json", or "forecast" + ext "json").
    static func url(_ name: String, ext: String? = nil) throws -> URL {
        let base = ext == nil ? (name as NSString).deletingPathExtension : name
        let type = ext ?? ((name as NSString).pathExtension.isEmpty ? nil : (name as NSString).pathExtension)
        guard let url = bundle.url(forResource: base, withExtension: type) else {
            throw NotFound(name: name, bundlePath: bundle.bundlePath)
        }
        return url
    }

    /// The bytes of the fixture `name`.
    static func data(_ name: String, ext: String? = nil) throws -> Data {
        try Data(contentsOf: url(name, ext: ext))
    }

    /// The fixture `name` decoded as UTF-8 text.
    static func string(_ name: String, ext: String? = nil) throws -> String {
        try String(decoding: data(name, ext: ext), as: UTF8.self)
    }

    /// The fixture `name` parsed with JSONSerialization (fragments allowed).
    static func json(_ name: String, ext: String? = nil) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name, ext: ext), options: [.fragmentsAllowed])
    }
}
