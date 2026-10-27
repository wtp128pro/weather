// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HelpBookTests.swift - the Help Book states what the code does: the weight
// tables of the Data Sources & Weights page are WxWeights' (the page is read
// from the source tree; scripts/help/weight_tables.py rebuilds the tables),
// every page carries its own <title>, and the weights prose matches the
// Canada profile.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct HelpBookTests {
    /// The book's en.lproj in the source tree (the test bundle is unhosted, not inside the app).
    static let lproj = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Weather/NeginatoMezora.help/Contents/Resources/en.lproj")

    /// A page of the book in the source tree.
    static func page(_ name: String) throws -> String {
        try String(contentsOf: lproj.appendingPathComponent(name), encoding: .utf8)
    }

    /// Python's html.escape, which regenerate.py applies to every title it writes.
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    /// The hour that stands for each horizon band in the tables (H0 0-3 h, H1 3-18 h, H2 18-72 h, H3 72 h+).
    static let bandHours: [Double] = [1, 6, 36, 96]

    static func weights(_ d: WxModelWeightDescriptor, _ v: WxVar, _ region: WxRegion) -> [Double] {
        bandHours.map {
            WxWeights.baseWeight(sourceID: d.sourceID, modelID: d.modelID, variable: v, horizonH: $0, region: region)
        }
    }

    @Test func weightTablesMatchTheCode() throws {
        let html = try Self.page("sources-weights.html")
        let row = try Regex(#"data-region="([A-Za-z]+)" data-model="([^"]+)" data-weights="([^"]+)""#)
        var listed: Set<String> = []
        for m in html.matches(of: row) {
            let regionName = try #require(m.output[1].substring.map(String.init))
            let modelID = try #require(m.output[2].substring.map(String.init))
            let cells = try #require(m.output[3].substring.map(String.init))
            let region = try #require(WxRegion.allCases.first { "\($0)" == regionName }, "\(regionName)")
            let d = try #require(WxWeights.modelDescriptors.first { $0.id == modelID }, "\(modelID)")
            var variables: Set<String> = []
            for cell in cells.split(separator: ";") {
                let parts = cell.split(separator: "=")
                try #require(parts.count == 2)
                let v = try #require(WxVar.allCases.first { "\($0)" == parts[0] }, "\(parts[0])")
                let shown = parts[1].split(separator: ",").map { Double($0) }
                #expect(shown == Self.weights(d, v, region).map(Optional.some), "\(region) \(modelID) \(v)")
                variables.insert(String(parts[0]))
            }
            #expect(variables.count == WxVar.count, "\(region) \(modelID)")
            #expect(listed.insert("\(region)|\(modelID)").inserted, "\(region) \(modelID) listed twice")
        }
        // Every model a profile uses is listed in it, and no other.
        for region in WxRegion.allCases {
            for d in WxWeights.modelDescriptors {
                let used = WxVar.allCases.contains { v in Self.weights(d, v, region).contains { $0 > 0 } }
                #expect(listed.contains("\(region)|\(d.id)") == used, "\(region) \(d.id)")
            }
        }
    }

    /// Every page's nav lists every title, so only the <title> element says which page a file is: each
    /// page of toc.json has exactly its own, and no other page is bundled (_shell.html is the template).
    @Test func everyPageHasItsOwnTitle() throws {
        struct TOC: Decodable {
            struct Page: Decodable { let href: String; let title: String }
            struct Section: Decodable { let pages: [Page] }
            let sections: [Section]
        }
        let toc = try JSONDecoder().decode(TOC.self, from: Data(Self.page("toc.json").utf8))
        let pages = toc.sections.flatMap(\.pages)
        let title = try Regex(#"<title>(.*?)</title>"#)
        for p in pages {
            let titles = try Self.page(p.href).matches(of: title).compactMap { $0.output[1].substring.map(String.init) }
            #expect(titles == ["\(Self.escaped(p.title)) — Neginato Mezora Help"], "\(p.href)")
        }
        let bundled = try FileManager.default.contentsOfDirectory(atPath: Self.lproj.path)
            .filter { $0.hasSuffix(".html") && $0 != "_shell.html" }
        #expect(Set(bundled) == Set(pages.map(\.href)))
    }

    /// HRRR and NBM run in southern Canada and the Canada profile weighs them (U26-F5), so the page must
    /// not say they weigh 0 outside the US.
    @Test func canadaWeightsProseMatchesTheCode() throws {
        for id in ["open-meteo:hrrr", "open-meteo:nbm"] {
            let d = try #require(WxWeights.modelDescriptors.first { $0.id == id }, "\(id)")
            #expect(Self.weights(d, .temp, .canada).contains { $0 > 0 }, "\(id)")
        }
        let html = try Self.page("sources-weights.html")
        #expect(!html.contains("Models that only run in the US (NWS, HRRR, NBM) weigh 0 elsewhere"))
        #expect(html.contains("weigh 0 elsewhere: NWS outside the US, HRRR and NBM outside the US and southern Canada;"))
        // The claim itself, not only the sentences: the page says "weigh 0" exactly once (the
        // corrected sentence), so a contradicting sentence beside it ("HRRR and NBM weigh 0
        // outside the US") is caught too (U66 verifier handoff).
        #expect(html.components(separatedBy: "weigh 0 ").count == 2)
    }
}
