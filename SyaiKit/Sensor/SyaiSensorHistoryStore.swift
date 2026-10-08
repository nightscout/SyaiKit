//
//  SyaiSensorHistoryStore.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Durable mirror of `SyaiSensorStore.records`, written to a plist file next
/// to `SyaiLogger`'s log files (`Documents/syai/`). `CGMManagerState`'s own
/// `rawState` is deleted wholesale by the host app when a CGM manager is
/// removed, so sensor history would otherwise be lost every time a user
/// swaps CGMs; this file survives that and is merged back in on the next
/// `SyaiCGMManager` construction.
enum SyaiSensorHistoryStore {
    private static let fileManager = FileManager.default
    private static let logger = SyaiLogger(category: "SensorHistoryStore")

    private static var fileURL: URL {
        documentsDirectory.appendingPathComponent("syai/syai_sensor_history.plist")
    }

    private static var directoryURL: URL {
        documentsDirectory.appendingPathComponent("syai")
    }

    private static var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func load() -> [SyaiSensorRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let recordsRaw = plist as? [[String: Any]] else { return [] }
        return recordsRaw.compactMap(SyaiSensorRecord.init(rawValue:))
    }

    static func save(_ records: [SyaiSensorRecord]) {
        // This file is the only surviving copy of the active sensor's record
        // once the host app deletes rawState, so a silent write failure means
        // an unpairable sensor with no trace of why.
        if !fileManager.fileExists(atPath: directoryURL.path) {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                logger.error("failed to create history directory: \(error.localizedDescription)")
            }
        }
        let recordsRaw = records.map(\.rawValue)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: recordsRaw, format: .binary, options: 0)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("failed to save sensor history (\(records.count) records): \(error.localizedDescription)")
        }
    }
}
