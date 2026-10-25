// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// dump_weights.swift - writes every model's base weights (WxWeights) per region,
// variable and horizon band as JSON, for weight_tables.py. Built against the
// WeatherCore framework of a Debug build (see weight_tables.py).

import Foundation
import WeatherCore

/// One representative hour per horizon band: H0 0-3 h, H1 3-18 h, H2 18-72 h, H3 72 h+.
let hours: [Double] = [1, 6, 36, 96]
var out: [[String: Any]] = []
for region in WxRegion.allCases {
    for d in WxWeights.modelDescriptors {
        var weights: [String: [Double]] = [:]
        for v in WxVar.allCases {
            weights["\(v)"] = hours.map {
                WxWeights.baseWeight(sourceID: d.sourceID, modelID: d.modelID, variable: v, horizonH: $0, region: region)
            }
        }
        out.append(["region": "\(region)", "id": d.id, "name": d.displayName, "w": weights])
    }
}
let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: data)
