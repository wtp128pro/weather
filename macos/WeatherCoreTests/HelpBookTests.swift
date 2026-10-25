// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HelpBookTests.swift - the Help Book states what the code does: the weight
// tables of the Data Sources & Weights page are WxWeights' (the page is read
// from the source tree; scripts/help/weight_tables.py rebuilds the tables).

import Foundation
import Testing
@testable import WeatherCore

@Suite struct HelpBookTests {
    /// A page of the book in the source tree (the test bundle is unhosted, not inside the app).
    static func page(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Weather/NeginatoMezora.help/Contents/Resources/en.lproj/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
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
}
