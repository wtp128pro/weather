// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SmokeTests.swift - proves the test harness: the bundle is unhosted (not run
// inside the sandboxed app), links WeatherCore from a nonisolated context, and
// the shared helpers in Support/TestSupport.swift behave as documented.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct SmokeTests {
    @Test func weatherCoreLinksAndIsNonisolated() {
        // Synchronous, nonisolated test function: compiles only because
        // WeatherCore's default isolation is nonisolated.
        // Expected value: WX_APP_ID, src/ui/wx-app.h:149.
        #expect(WeatherCoreInfo.applicationID == "io.github.wtp128pro.Weather")
    }

    @Test func bundleIsUnhosted() {
        let env = ProcessInfo.processInfo.environment
        #expect(env["APP_SANDBOX_CONTAINER_ID"] == nil, "test bundle runs inside an app sandbox")
        #expect(Bundle.main.bundleIdentifier != "io.github.wtp128pro.Weather", "test bundle is hosted in Weather.app")
        #expect(Fixtures.bundle.bundleURL.lastPathComponent == "WeatherCoreTests.xctest")
    }

    @Test func temporaryDirectoryLivesUnderSystemTempAndIsRemoved() throws {
        var dir: TemporaryDirectory? = try TemporaryDirectory("smoke")
        let url = try #require(dir?.url)
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        #expect(url.resolvingSymlinksInPath().path.hasPrefix(temp + "/"), "\(url.path) not under \(temp)")
        #expect(!url.path.hasPrefix(home + "/"), "\(url.path) is under ~/Library")
        let file = try #require(dir?.appending("probe.txt"))
        try Data("x".utf8).write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        dir = nil
        #expect(!FileManager.default.fileExists(atPath: url.path), "directory survived deinit")

        let scoped = try TemporaryDirectory.with("scoped") { inner -> URL in
            #expect(FileManager.default.fileExists(atPath: inner.path))
            return inner
        }
        #expect(!FileManager.default.fileExists(atPath: scoped.path), "scoped directory survived")
    }

    @Test func seededRNGMatchesSplitMix64ReferenceVector() {
        // Reference outputs of splitmix64 for seed 1234567 (Rosetta Code
        // "Pseudo-random numbers/Splitmix64"), independent of this code.
        var rng = SeededRNG(seed: 1_234_567)
        let got = (0..<5).map { _ in rng.next() }
        #expect(got == [
            6_457_827_717_110_365_317, 3_203_168_211_198_807_973, 9_817_491_932_198_370_423,
            4_593_380_528_125_082_431, 16_408_922_859_458_223_821,
        ])
    }

    @Test func seededRNGIsDeterministicPerSeed() {
        var a = SeededRNG(seed: 42), b = SeededRNG(seed: 42), c = SeededRNG(seed: 43)
        let sa = (0..<16).map { _ in Int.random(in: 0..<1_000_000, using: &a) }
        let sb = (0..<16).map { _ in Int.random(in: 0..<1_000_000, using: &b) }
        let sc = (0..<16).map { _ in Int.random(in: 0..<1_000_000, using: &c) }
        #expect(sa == sb)
        #expect(sa != sc)
    }

    @Test(arguments: [
        (String?.none, 1), ("", 1), ("0", 1), ("1", 10), ("yes", 10), ("5", 5), ("25", 25),
    ])
    func slowTestsMultiplier(value: String?, expected: Int) {
        #expect(TestEnvironment.multiplier(for: value) == expected)
    }

    @Test func fuzzIterationsReadsWeatherSlowTests() {
        // The variable is read here by its literal name (the contract in the
        // brief and the policy header), independently of TestSupport, so a
        // misspelt or unread variable in TestEnvironment fails this test.
        let raw = ProcessInfo.processInfo.environment["WEATHER_SLOW_TESTS"]
        #expect(TestEnvironment.slowTestsVariable == "WEATHER_SLOW_TESTS")
        #expect(
            TestEnvironment.slowTestsMultiplier == TestEnvironment.multiplier(for: raw),
            "WEATHER_SLOW_TESTS=\(raw ?? "<unset>") is not what TestEnvironment read")
        #expect(fuzzIterations(200) == 200 * TestEnvironment.multiplier(for: raw))
        #expect(fuzzIterations(200) >= 200)
    }

    @Test func nearAndNaNExpectations() {
        expectNear(0.1 + 0.2, 0.3, eps: 1e-12)
        expectNear(-273.15, -273.1, eps: 0.06)
        expectNear(.infinity, .infinity, eps: 0)
        expectNaN(.nan)
        expectNaN(Double.infinity - Double.infinity)
    }

    @Test func missingFixtureThrowsNotFound() {
        #expect(throws: Fixtures.NotFound.self) {
            _ = try Fixtures.data("no-such-fixture.json")
        }
    }
}
