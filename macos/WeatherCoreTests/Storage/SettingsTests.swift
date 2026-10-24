// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SettingsTests.swift - port of the settings groups of src/storage/test-storage.c
// (/settings/*, and the settings half of the generic /store/* cases). Expected
// values are the C test literals, cited as test-storage.c:LINE.

import Darwin
import Foundation
import Testing
@testable import WeatherCore

/// The settings row of the StoreOps table (k_settings_ops, test-storage.c:1141-1166, 1247-1257).
private enum SettingsOps: StoreJSONTests.StoreOps {
    static let name = "settings"
    static let maxFileBytes = WxSettings.maxFileBytes
    static let docPrefix = "{\"version\":1"

    static func create(_ path: String) throws -> WxSettings {
        try #require(WxSettings(path: path))
    }

    static func mutate(_ s: WxSettings, _ step: Int) throws {
        #expect(s.setProviderDisabled("prov\(step)", true), "settings_mutate \(step)")
    }

    static func isDirty(_ s: WxSettings) -> Bool { s.isDirty }
    static func save(_ s: WxSettings) throws(WxStoreError) { try s.save() }
    static func load(_ s: WxSettings) throws(WxStoreError) { try s.load() }
    static func fingerprint(_ s: WxSettings) -> String { settingsFingerprint(s) }
    static func setOnChanged(_ s: WxSettings, _ body: @escaping () -> Void) { s.onChanged = body }
    static func beginSave(_ s: WxSettings) throws(WxStoreError) -> StoreJSON.SaveJob { try s.beginSave() }
    static func finishSave(_ s: WxSettings, _ job: StoreJSON.SaveJob, _ outcome: Result<Void, WxStoreError>) throws(WxStoreError) {
        try s.finishSave(job, outcome)
    }

    static func saveAsync(_ s: WxSettings) async throws(WxStoreError) { try await s.saveAsync() }
}

/// settings_fingerprint (test-storage.c:1154-1166).
private func settingsFingerprint(_ st: WxSettings) -> String {
    var s = "\(st.units.rawValue)|\(st.selected ?? "(none)")|"
    for i in 0 ..< 40 where st.isProviderDisabled("prov\(i)") {
        s += "prov\(i),"
    }
    return s
}

@Suite struct SettingsTests {
    // MARK: - Generic store cases, settings row

    @Test func storeRoundtrip() throws {
        // C: /store/roundtrip
        try StoreJSONTests.roundtripAndFiles(SettingsOps.self)
    }

    @Test func storeLoadErrors() throws {
        // C: /store/load-errors
        try StoreJSONTests.loadErrors(SettingsOps.self)
    }

    @Test func storeHostileNesting() throws {
        // C: /store/hostile-nesting
        try StoreJSONTests.hostileNesting(SettingsOps.self)
    }

    @Test func storeSaveFailure() throws {
        // C: /store/save-failure
        try StoreJSONTests.saveFailure(SettingsOps.self)
    }

    @Test func storeSaveAsync() async throws {
        // C: /store/save-async
        try await StoreJSONTests.saveAsyncSnapshot(SettingsOps.self)
    }

    @Test func storeSaveAsyncFailureAndCancel() async throws {
        // C: /store/save-async-failure-and-cancel
        try await StoreJSONTests.saveAsyncFailureAndCancel(SettingsOps.self)
    }

    @Test func storeSaveAsyncMany() async throws {
        // C: /store/save-async-many
        try await StoreJSONTests.saveAsyncMany(SettingsOps.self)
    }

    @Test func storeStaleTemps() throws {
        // C: /store/stale-temps
        try StoreJSONTests.staleTemps(SettingsOps.self)
    }

    @Test func storeFuzz() throws {
        // C: /store/fuzz (GRand seed 777 + k with k = 1 for settings, test-storage.c:4042)
        try StoreJSONTests.fuzz(SettingsOps.self, seed: 778)
    }

    // C: /store/save-async-context (test-storage.c:4358-4387): the completion is
    // delivered in the caller's context - here the caller's actor.
    @MainActor @Test func storeSaveAsyncContext() async throws {
        let tmp = try TemporaryDirectory("settings-ctx")
        let st = try SettingsOps.create(tmp.appending("ctx.json").path)
        try SettingsOps.mutate(st, 0)
        try await st.saveAsync()
        #expect(pthread_main_np() != 0, "resumed on the main actor")
        #expect(!st.isDirty)
    }

    // C: /store/load-on-worker-thread (test-storage.c:4426-4460): load() on a
    // worker, hand-off, use on the caller; "changed" is emitted on the worker.
    @Test func storeLoadOnWorkerThread() async throws {
        let tmp = try TemporaryDirectory("settings-worker")
        let path = tmp.appending("load.json").path
        let w = try SettingsOps.create(path)
        for i in 0 ..< 3 {
            try SettingsOps.mutate(w, i)
        }
        #expect(throws: Never.self) { try w.save() }
        let want = settingsFingerprint(w)
        let (loaded, changedOnMain, ok): (WxSettings?, Bool?, Bool) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                guard let st = WxSettings(path: path) else {
                    cont.resume(returning: (nil, nil, false))
                    return
                }
                var onMain: Bool?
                st.onChanged = { onMain = pthread_main_np() != 0 }
                let ok = (try? st.load()) != nil
                st.onChanged = nil
                cont.resume(returning: (st, onMain, ok))
            }
        }
        #expect(ok)
        #expect(changedOnMain == false, "emitted on the worker")
        let st = try #require(loaded)
        #expect(settingsFingerprint(st) == want, "usable after the hand-off")
    }

    // C: /store/default-paths (test-storage.c:1964-1993), settings part.
    @Test func storeDefaultPaths() throws {
        #expect(WxSettings.defaultPath(configDirectory: "/cfg") == "/cfg/weather/settings.json")
        let st = try #require(WxSettings(path: "/tmp/x/y.json"))
        #expect(st.path == "/tmp/x/y.json")
        #expect(WxSettings(path: "") == nil)
    }

    // C: /store/nul-escape-settings (test_store_nul_escape_settings, test-storage.c:3848-3882)
    @Test func storeNulEscapeSettings() throws {
        let tmp = try TemporaryDirectory("settings-nul")
        let path = tmp.appending("settings.json").path
        let bad: [(String, String)] = [
            ("units", "{\"version\":1,\"units\":\"metric\\u0000junk\"}"),
            ("units, whole value", "{\"version\":1,\"units\":\"\\u0000\"}"),
            ("units, case-less zeros", "{\"version\":1,\"units\":\"metric\\u00000\"}"),
            ("disabled provider", "{\"version\":1,\"disabled_providers\":[\"a\\u0000b\"]}"),
            ("disabled provider next to valid ones",
             "{\"version\":1,\"disabled_providers\":[\"ok\",\"a\\u0000\",\"fine\"]}"),
            ("selected", "{\"version\":1,\"selected\":\"25.7617,-80.1918\\u0000x\"}"),
            ("selected, escape inside the digits", "{\"version\":1,\"selected\":\"25.76\\u000017,-80.1918\"}"),
            ("unknown member value", "{\"version\":1,\"x\":\"\\u0000\"}"),
            ("member name", "{\"version\":1,\"un\\u0000its\":\"metric\"}"),
            ("version member name", "{\"vers\\u0000ion\":1}"),
        ]
        for (label, text) in bad {
            try StoreJSONTests.expectRejected(SettingsOps.self, path, text, label)
        }

        // The same text with an escaped backslash is ordinary data and loads (the value is
        // invalid, so the default stays).
        try StoreJSONTests.putText(path, "{\"version\":1,\"units\":\"metric\\\\u0000junk\"}")
        let st = try SettingsOps.create(path)
        #expect(throws: Never.self) { try st.load() }
        #expect(st.units == .imperial)
        // And the cleanly escaped neighbours load normally.
        try StoreJSONTests.putText(path, "{\"version\":1,\"units\":\"metric\",\"selected\":\"1.5000,2.5000\\u0031\"}")
        #expect(throws: Never.self) { try st.load() }
        #expect(st.units == .metric)
    }

    // MARK: - /settings/*

    // C: /settings/basic (test_settings_basic, test-storage.c:2394-2468)
    @Test func settingsBasic() throws {
        let st = try SettingsOps.create("/nonexistent/never-used.json")
        var changed = 0
        st.onChanged = { changed += 1 }
        // Defaults.
        #expect(st.units == .imperial)
        #expect(st.selected == nil)
        #expect(!st.isProviderDisabled("open-meteo"))
        #expect(!st.isDirty)
        #expect(st.path == "/nonexistent/never-used.json")

        // Units.
        #expect(!st.setUnits(.imperial))
        #expect(changed == 0)
        #expect(!st.isDirty)
        #expect(st.setUnits(.metric))
        #expect(st.units == .metric)
        #expect(changed == 1)
        #expect(st.isDirty)
        #expect(!st.setUnits(.metric))
        #expect(changed == 1)

        // Providers.
        #expect(st.setProviderDisabled("nws", true))
        #expect(st.isProviderDisabled("nws"))
        #expect(!st.isProviderDisabled("NWS")) // not a valid id
        #expect(!st.isProviderDisabled("met-no"))
        #expect(!st.setProviderDisabled("nws", true)) // already
        #expect(changed == 2)
        #expect(st.setProviderDisabled("met-no", true))
        #expect(st.setProviderDisabled("nws", false))
        #expect(!st.isProviderDisabled("nws"))
        #expect(st.isProviderDisabled("met-no"))
        #expect(!st.setProviderDisabled("nws", false)) // already enabled
        #expect(changed == 4)
        let badIDs = [
            "", " ", "NWS", "../x", ".", "..", "-a", "_a", "a b", "a/b", "a\n",
            "caf\u{E9}", "this-id-is-way-longer-than-thirty-two-bytes",
        ]
        for id in badIDs {
            #expect(!st.setProviderDisabled(id, true), "\(id)")
            #expect(!st.setProviderDisabled(id, false), "\(id)")
            #expect(!st.isProviderDisabled(id), "\(id)")
        }
        #expect(!st.setProviderDisabled(nil, true))
        #expect(!st.isProviderDisabled(nil))
        #expect(changed == 4)

        // The list is capped at 16; removing makes room.
        #expect(WxSettings.maxDisabledProviders == 16) // WX_SETTINGS_MAX_DISABLED, wx-settings.h:46
        for i in 0 ..< 16 {
            #expect(st.setProviderDisabled("p\(i)", true) == (i < 15), "p\(i)") // met-no already holds a slot
        }
        #expect(!st.isProviderDisabled("p15"))
        #expect(st.isProviderDisabled("p14"))
        #expect(st.setProviderDisabled("p0", false))
        #expect(st.setProviderDisabled("p15", true))
        #expect(!st.setProviderDisabled("p16", true))
        #expect(!st.setProviderDisabled("p16", false)) // absent: nothing to do

        // Selection.
        let before = changed
        #expect(st.setSelected("25.7617,-80.1918"))
        #expect(st.selected == "25.7617,-80.1918")
        #expect(!st.setSelected("25.7617,-80.1918"))
        #expect(st.setSelected("-33.8688,151.2093"))
        #expect(changed == before + 2)
        #expect(!st.setSelected("garbage"))
        #expect(st.selected == "-33.8688,151.2093")
        #expect(st.setSelected(nil))
        #expect(st.selected == nil)
        #expect(!st.setSelected(nil))
        #expect(changed == before + 3)
    }

    // C: /settings/selected-keys (test_settings_selected_keys, test-storage.c:2470-2498)
    @Test func settingsSelectedKeys() throws {
        let st = try SettingsOps.create("/nonexistent/never-used.json")
        let good = [
            "25.7617,-80.1918", "-33.8688,151.2093", "0.0000,0.0000", "90.0000,180.0000",
            "-90.0000,-180.0000", "1.0000,2.0000", "-0.0000,-0.0000", "89.9999,179.9999",
            "5.1234,-7.9999", "12.3456,100.0000",
        ]
        for key in good {
            #expect(st.setSelected(key), "\(key)")
            #expect(st.selected == key)
            #expect(st.setSelected(nil))
        }
        let bad = [
            "", ",", "1,2", "1.0,2.0", "1.0000,2.0", "1.00000,2.0000", ".5000,1.0000", "1.0000;2.0000",
            "1.0000, 2.0000", " 1.0000,2.0000", "1.0000,2.0000 ", "1.0000,2.0000\n", "+1.0000,2.0000",
            "1.0000,+2.0000", "--1.0000,2.0000", "1.0000,2.0000,3.0000", "1.0000", "1.0000,",
            ",2.0000", "91.0000,0.0000", "-91.0000,0.0000", "0.0000,181.0000", "0.0000,-181.0000",
            "1000.0000,0.0000", "0.0000,1000.0000", "90.0001,0.0000", "1e1.0000,2.0000", "nan,nan",
            "inf,inf", "0x1.0000,2.0000", "1.0000,2.000\u{E9}", "../../../etc/p,1.0000", "a.0000,1.0000",
            "1.0000,1.0000/", "1.0000,1.0000%00", "\"1.0000,2.0000\"", "1.0000,-",
            "123456789012345678901234", "1.0000,2.0000xxxxxxxxxxxxxxxxxxxxxxxxxxx",
        ]
        for key in bad {
            #expect(!st.setSelected(key), "\(key)")
            #expect(st.selected == nil, "\(key)")
            #expect(!WxSettings.isValidKey(key), "\(key)")
        }
        #expect(st.isDirty) // by the accepted keys above, not by the rejected ones
    }

    // C: /settings/load-partial (test_settings_load_partial, test-storage.c:2507-2587)
    @Test func settingsLoadPartial() throws {
        // Only these ids are probed, so cases must use them.
        let probe = ["a", "b", "ok"] + (0 ..< 20).map { "p\($0)" }
        let cases: [(String, WxUnits, String?, String)] = [
            ("{\"version\":1}", .imperial, nil, ""),
            ("{\"version\":1,\"units\":\"metric\"}", .metric, nil, ""),
            ("{\"version\":1,\"units\":\"imperial\"}", .imperial, nil, ""),
            ("{\"version\":1,\"units\":\"Metric\"}", .imperial, nil, ""),
            ("{\"version\":1,\"units\":\"METRIC\"}", .imperial, nil, ""),
            ("{\"version\":1,\"units\":\"si\"}", .imperial, nil, ""),
            ("{\"version\":1,\"units\":1}", .imperial, nil, ""),
            ("{\"version\":1,\"units\":null}", .imperial, nil, ""),
            ("{\"version\":1,\"units\":[\"metric\"]}", .imperial, nil, ""),
            ("{\"version\":1,\"disabled_providers\":[\"a\",\"b\"]}", .imperial, nil, "a,b"),
            ("{\"version\":1,\"disabled_providers\":[\"a\",\"a\",\"b\",\"a\"]}", .imperial, nil, "a,b"),
            ("{\"version\":1,\"disabled_providers\":[\"A\",\"../x\",\"\",\"a b\",5,null,[],{},true,\"ok\"]}",
             .imperial, nil, "ok"),
            ("{\"version\":1,\"disabled_providers\":\"a\"}", .imperial, nil, ""),
            ("{\"version\":1,\"disabled_providers\":{\"a\":1}}", .imperial, nil, ""),
            ("{\"version\":1,\"disabled_providers\":null}", .imperial, nil, ""),
            ("{\"version\":1,\"disabled_providers\":[]}", .imperial, nil, ""),
            ("{\"version\":1,\"disabled_providers\":[\"p0\",\"p1\",\"p2\",\"p3\",\"p4\",\"p5\",\"p6\",\"p7\","
                + "\"p8\",\"p9\",\"p10\",\"p11\",\"p12\",\"p13\",\"p14\",\"p15\",\"p16\",\"p17\",\"p18\",\"p19\"]}",
             .imperial, nil, "p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15"),
            ("{\"version\":1,\"selected\":\"25.7617,-80.1918\"}", .imperial, "25.7617,-80.1918", ""),
            ("{\"version\":1,\"selected\":\"1,2\"}", .imperial, nil, ""),
            ("{\"version\":1,\"selected\":\"95.0000,2.0000\"}", .imperial, nil, ""),
            ("{\"version\":1,\"selected\":5}", .imperial, nil, ""),
            ("{\"version\":1,\"selected\":null}", .imperial, nil, ""),
            ("{\"version\":1,\"selected\":\"\"}", .imperial, nil, ""),
            // An escaped backslash followed by "u0000" is plain text, not a NUL escape.
            ("{\"version\":1,\"selected\":\"1.0000,2.0000\\\\u0000x\"}", .imperial, nil, ""),
            ("{\"version\":1,\"units\":\"metric\",\"disabled_providers\":[\"b\"],\"selected\":\"-1.5000,2.2500\","
                + "\"unknown\":{\"x\":[1,2,3]}}", .metric, "-1.5000,2.2500", "b"),
            ("{\"unknown\":1,\"version\":1,\"units\":\"metric\"}", .metric, nil, ""),
        ]
        let tmp = try TemporaryDirectory("settings-partial")
        let path = tmp.appending("settings.json").path
        let st = try SettingsOps.create(path)
        var changed = 0
        st.onChanged = { changed += 1 }
        for (json, units, selected, disabled) in cases {
            // Start from non-default values: the load must replace them.
            #expect(st.setUnits(.metric) || st.units == .metric)
            st.setProviderDisabled("b", true)
            try StoreJSONTests.putText(path, json)
            let before = changed
            let e = StoreJSONTests.caught { () throws(WxStoreError) in try st.load() }
            #expect(e == nil, "\(json): \(String(describing: e))")
            #expect(changed == before + 1, "\(json)")
            #expect(!st.isDirty, "\(json)")
            #expect(st.units == units, "\(json)")
            #expect(st.selected == selected, "\(json)")
            let expected = disabled.isEmpty ? [] : disabled.split(separator: ",").map(String.init)
            for id in expected {
                #expect(st.isProviderDisabled(id), "\(json): \(id)")
            }
            #expect(probe.filter { st.isProviderDisabled($0) }.count == expected.count, "\(json)")
        }

        // A failing load resets to the defaults and announces it, once.
        st.setUnits(.metric)
        let before = changed
        try StoreJSONTests.putText(path, "garbage")
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try st.load() } != nil)
        #expect(changed == before + 1)
        #expect(st.units == .imperial)
    }

    // C: /settings/roundtrip (test_settings_roundtrip, test-storage.c:2657-2687): the exact
    // file text is the C test literal.
    @Test func settingsRoundtrip() throws {
        let tmp = try TemporaryDirectory("settings-roundtrip")
        let path = tmp.appending("cfg/weather/settings.json").path
        let st = try SettingsOps.create(path)
        #expect(st.setUnits(.metric))
        #expect(st.setProviderDisabled("nws", true))
        #expect(st.setProviderDisabled("met-no", true))
        #expect(st.setSelected("-33.8688,151.2093"))
        #expect(throws: Never.self) { try st.save() }
        // test-storage.c:2669-2672
        #expect(try StoreJSONTests.readAll(path)
            == "{\n  \"version\": 1,\n  \"units\": \"metric\",\n"
            + "  \"disabled_providers\": [\"nws\", \"met-no\"],\n"
            + "  \"selected\": \"-33.8688,151.2093\"\n}\n")
        let back = try SettingsOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        #expect(back.units == .metric)
        #expect(back.isProviderDisabled("nws"))
        #expect(back.isProviderDisabled("met-no"))
        #expect(!back.isProviderDisabled("open-meteo"))
        #expect(back.selected == "-33.8688,151.2093")
        #expect(back.disabledProviders == ["nws", "met-no"])

        // Defaults: no "selected" member, empty list (test-storage.c:2685-2686).
        let def = try SettingsOps.create(path)
        #expect(throws: Never.self) { try def.save() }
        #expect(try StoreJSONTests.readAll(path)
            == "{\n  \"version\": 1,\n  \"units\": \"imperial\",\n  \"disabled_providers\": []\n}\n")
    }
}
