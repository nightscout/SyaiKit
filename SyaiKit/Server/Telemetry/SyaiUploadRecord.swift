//
//  SyaiUploadRecord.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// One decoded reading packaged for the OEM glucose-upload pipeline (`POST cgm/security/data/collect/collect/glucose/v2`).
/// Built from the same frame the dosing path just consumed and emitted after forwarding, so telemetry
/// never sits in front of dosing. Spilled to a plist queue only on upload failure.
public struct SyaiUploadRecord: Equatable, Sendable {
    /// Seconds since activation (`raw.v2`).
    public let runSec: UInt32
    /// Battery deci-volts (30 = 3.0 V); nil only for an unpinned parse version or short record.
    public let voltage: Int?
    /// Phone's receipt instant as epoch-ms; identical for every record in one batch.
    public let receivedAtMs: Int64
    /// Sensor record index (`frame.sequence`).
    public let frontIdx: UInt16
    /// RPN result in mmol/L, 1 decimal. Uploaded identically as `glucose`/`cgmGlucose`/`adjGlucose`.
    public let glucoseMmol: Double
    /// Raw electrode ADC (`raw.v0`).
    public let current: UInt32
    /// `raw.v1` as-is.
    public let temperatureC: Double
    /// `frame.plaintext` verbatim, the framed record `[00 00, idx LE, d]` (13 bytes V1.7 / 12 V1.6).
    public let origin: Data

    public init(
        runSec: UInt32,
        voltage: Int?,
        receivedAtMs: Int64,
        frontIdx: UInt16,
        glucoseMmol: Double,
        current: UInt32,
        temperatureC: Double,
        origin: Data
    ) {
        self.runSec = runSec
        self.voltage = voltage
        self.receivedAtMs = receivedAtMs
        self.frontIdx = frontIdx
        self.glucoseMmol = glucoseMmol
        self.current = current
        self.temperatureC = temperatureC
        self.origin = origin
    }

    /// RPN mg/dL to upload mmol/L, 1 decimal: `(x*10).rounded()/10`.
    public static func mmol(fromMgDL mgdl: Double) -> Double {
        ((mgdl / 18.0) * 10).rounded() / 10
    }

    /// Voltage lift from the framed record `[00 00, idx(2), d]`, deci-volts (30 = 3.0 V):
    ///   - V1.6: `LE16(d[2:4]) >> 10`, origin bytes 6-7.
    ///   - V1.7: `(d[3] >> 4) | ((d[4] & 0x3) << 4)`, origin bytes 7-8 (bits 4-9 of `LE16(d[3:5])`).
    /// nil for other parse versions or records too short for the window.
    public static func voltage(fromPlaintext plaintext: Data, parseVersion: String) -> Int? {
        let b = [UInt8](plaintext)
        switch parseVersion {
        case "V1.6":
            guard b.count >= 8 else { return nil }
            return Int((UInt16(b[6]) | UInt16(b[7]) << 8) >> 10)
        case "V1.7":
            guard b.count >= 9 else { return nil }
            return Int((b[7] >> 4) | ((b[8] & 0x3) << 4))
        default:
            return nil
        }
    }

    /// `dataList` entry for this record (`dataType: 1`). `time` = `activatedAtMs + runSec*1000`.
    public func dataListEntry(activatedAtMs: Int64) -> [String: Any] {
        entry(dataType: 1, origin: origin.map { Int($0) }, activatedAtMs: activatedAtMs)
    }

    /// `dataType: 2` checkpoint duplicate: field-identical copy with `origin: null`, piggybacked
    /// in the same `dataList` at `frontIdx % 5 == 0` (excluding 0).
    public func checkpointDuplicate(activatedAtMs: Int64) -> [String: Any] {
        entry(dataType: 2, origin: NSNull(), activatedAtMs: activatedAtMs)
    }

    /// Full upload body `{"deviceId":…,"embeddedSoftVersion":…,"dataList":[…]}` with this record
    /// as the single entry. `serverDeviceId` is from `device/authInfo`; `embeddedSoftVersion` is
    /// the sensor record's firmware string.
    public func uploadBody(
        serverDeviceId: Int,
        embeddedSoftVersion: String,
        activatedAtMs: Int64
    ) -> [String: Any] {
        [
            "deviceId": NSNumber(value: serverDeviceId),
            "embeddedSoftVersion": embeddedSoftVersion,
            "dataList": [dataListEntry(activatedAtMs: activatedAtMs)]
        ]
    }

    /// Shared entry builder.
    private func entry(dataType: Int, origin: Any, activatedAtMs: Int64) -> [String: Any] {
        let voltageValue: Any
        if let voltage {
            voltageValue = NSNumber(value: voltage)
        } else {
            // Unreachable for V1.6/V1.7; only an unpinned parse version or short record lands here.
            voltageValue = NSNull()
        }
        return [
            "runSec": NSNumber(value: runSec),
            "voltage": voltageValue,
            "timeAppReceive": NSNumber(value: receivedAtMs),
            "frontIdx": NSNumber(value: frontIdx),
            "glucose": glucoseMmol,
            "cgmGlucose": glucoseMmol,
            "adjGlucose": glucoseMmol,
            "current": NSNumber(value: current),
            "time": NSNumber(value: activatedAtMs + Int64(runSec) * 1000),
            "glucoseStatus": 0, // 0 everywhere observed; never invent other values
            "alignId": NSNull(),
            "temperature": temperatureC,
            "origin": origin,
            "dataType": dataType
        ]
    }

    /// plist-safe encoding for the offline-queue spill. `origin` rides as Data.
    public var plistRawValue: [String: Any] {
        var raw: [String: Any] = [
            "runSec": Int(runSec),
            "receivedAtMs": Int(receivedAtMs),
            "frontIdx": Int(frontIdx),
            "glucoseMmol": glucoseMmol,
            "current": Int(current),
            "temperatureC": temperatureC,
            "origin": origin
        ]
        raw["voltage"] = voltage // absent key means nil (V1.7)
        return raw
    }

    public init?(plistRawValue raw: [String: Any]) {
        guard let runSec = raw["runSec"] as? Int,
              let receivedAtMs = raw["receivedAtMs"] as? Int,
              let frontIdx = raw["frontIdx"] as? Int,
              let glucoseMmol = raw["glucoseMmol"] as? Double,
              let current = raw["current"] as? Int,
              let temperatureC = raw["temperatureC"] as? Double,
              let origin = raw["origin"] as? Data else { return nil }
        self.runSec = UInt32(runSec)
        voltage = raw["voltage"] as? Int
        self.receivedAtMs = Int64(receivedAtMs)
        self.frontIdx = UInt16(frontIdx)
        self.glucoseMmol = glucoseMmol
        self.current = UInt32(current)
        self.temperatureC = temperatureC
        self.origin = origin
    }
}
