//
//  SyaiUploadRecordTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Byte-exactness tests for the telemetry upload payload.
///
/// The golden fixture is the captured V1.7 upload body for frontIdx 0.
/// Bodies are compared as PARSED dictionaries, not key-ordered strings:
/// JSON key order is semantically irrelevant to the server. V1.7 `voltage` is
/// pinned (`(d[3]>>4)|((d[4]&0x3)<<4)`), so the
/// golden body must match the capture on every field, voltage included.
final class SyaiUploadRecordTests: XCTestCase {
    /// Captured body fixture for frontIdx 0.
    private static let capturedBodyJSON = """
    {"deviceId":11994938,"embeddedSoftVersion":"E2.0.1(V1.7.SH22537.1)","dataList":[
     {"runSec":62,"voltage":31,"timeAppReceive":1785344523987,"frontIdx":0,
      "glucose":17.3,"cgmGlucose":17.3,"adjGlucose":17.3,"current":32739,
      "time":1785344521355,"glucoseStatus":0,"alignId":null,"temperature":31.85,
      "origin":[0,0,0,0,227,127,180,242,249,0,0,113,12],"dataType":1}]}
    """

    /// The record equivalent to the captured frontIdx-0 row. `activatedAtMs` is
    /// 1785344459355 (the bind call's `activeTime`): 1785344459355 + 62*1000 =
    /// the captured `time` 1785344521355. `voltage` 31 is what
    /// `voltage(fromPlaintext:)` lifts from this origin
    /// (d[3]=0xF2, d[4]=0xF9 → (0xF)|(1<<4) = 31) and what the app uploaded.
    private static func makeCapturedRecord() -> SyaiUploadRecord {
        SyaiUploadRecord(
            runSec: 62,
            voltage: 31,
            receivedAtMs: 1_785_344_523_987,
            frontIdx: 0,
            glucoseMmol: SyaiUploadRecord.mmol(fromMgDL: 17.3 * 18),
            current: 32739,
            temperatureC: 31.85,
            origin: Data([0, 0, 0, 0, 227, 127, 180, 242, 249, 0, 0, 113, 12])
        )
    }

    /// Shallow-deep JSON value equality: NSNumber numerically, NSNull by identity
    /// of kind, arrays element-wise. (NSDictionary/NSArray `isEqual` would also
    /// work; this keeps the failure messages per-key.)
    private func isEqualJSONValue(_ a: Any?, _ b: Any?) -> Bool {
        if a is NSNull || b is NSNull { return a is NSNull && b is NSNull }
        switch (a, b) {
        case let (x as NSNumber, y as NSNumber): return x == y
        case let (x as String, y as String): return x == y
        case let (x as [Any], y as [Any]):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { isEqualJSONValue($0.0, $0.1) }
        default: return false
        }
    }

    func testGoldenBodyMatchesCaptureByteForByte() throws {
        let record = Self.makeCapturedRecord()
        let body = record.uploadBody(
            serverDeviceId: 11_994_938,
            embeddedSoftVersion: "E2.0.1(V1.7.SH22537.1)",
            activatedAtMs: 1_785_344_459_355
        )
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let ours = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let captured = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.capturedBodyJSON.utf8)) as? [String: Any]
        )

        XCTAssertEqual(ours["deviceId"] as? NSNumber, captured["deviceId"] as? NSNumber)
        XCTAssertEqual(ours["embeddedSoftVersion"] as? String, captured["embeddedSoftVersion"] as? String)

        let ourRows = try XCTUnwrap(ours["dataList"] as? [[String: Any]])
        let capturedRows = try XCTUnwrap(captured["dataList"] as? [[String: Any]])
        XCTAssertEqual(ourRows.count, 1)
        XCTAssertEqual(capturedRows.count, 1)
        let ourRow = ourRows[0]
        let capturedRow = capturedRows[0]

        XCTAssertEqual(Set(ourRow.keys), Set(capturedRow.keys))

        for key in capturedRow.keys {
            XCTAssertTrue(
                isEqualJSONValue(ourRow[key], capturedRow[key]),
                "field '\(key)': ours \(String(describing: ourRow[key])) "
                    + "vs captured \(String(describing: capturedRow[key]))"
            )
        }
    }

    func testV16VoltageExtraction() {
        // 30 deci-volts (3.0 V) = 30 << 10 = 30720 = 0x7800 → LE bytes [0x00, 0x78]
        // at positions 6-7 of the framed record (= d[2:4] of the 8-byte record).
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[6] = 0x00
        bytes[7] = 0x78
        XCTAssertEqual(SyaiUploadRecord.voltage(fromPlaintext: Data(bytes), parseVersion: "V1.6"), 30)
    }

    func testV17VoltageExtraction() {
        // The captured frontIdx-0 origin: d[3]=0xF2, d[4]=0xF9 →
        // (0xF2>>4) | ((0xF9&0x3)<<4) = 0xF | 0x10 = 31 = the uploaded value.
        let origin = Data([0, 0, 0, 0, 227, 127, 180, 242, 249, 0, 0, 113, 12])
        XCTAssertEqual(SyaiUploadRecord.voltage(fromPlaintext: origin, parseVersion: "V1.7"), 31)
    }

    func testVoltageShortRecordIsNil() {
        XCTAssertNil(SyaiUploadRecord.voltage(
            fromPlaintext: Data([0x00, 0x78]), parseVersion: "V1.6"
        ))
    }

    func testMmolRounding() throws {
        // 17.299… mg/dL-equivalent ⇒ 17.3 mmol.
        let mmol = SyaiUploadRecord.mmol(fromMgDL: 311.39) // /18 = 17.2994…
        XCTAssertEqual(mmol, 17.3, accuracy: 1E-12)
        // The rounded Double must round-trip JSONSerialization as exactly 17.3.
        let data = try JSONSerialization.data(withJSONObject: ["g": mmol])
        let parsed = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: data) as? [String: Any])?["g"] as? Double
        )
        XCTAssertEqual(parsed, 17.3, accuracy: 1E-12)
        XCTAssertEqual(SyaiUploadRecord.mmol(fromMgDL: 9.2 * 18), 9.2, accuracy: 1E-12)
    }

    func testCheckpointDuplicate() {
        let record = Self.makeCapturedRecord()
        let entry = record.dataListEntry(activatedAtMs: 1_785_344_459_355)
        let dup = record.checkpointDuplicate(activatedAtMs: 1_785_344_459_355)

        XCTAssertEqual(Set(dup.keys), Set(entry.keys))
        XCTAssertEqual(entry["dataType"] as? NSNumber, NSNumber(value: 1))
        XCTAssertEqual(dup["dataType"] as? NSNumber, NSNumber(value: 2))
        XCTAssertTrue(dup["origin"] is NSNull, "checkpoint origin must be JSON null")
        for (key, value) in entry where key != "dataType" && key != "origin" {
            XCTAssertTrue(
                isEqualJSONValue(dup[key], value),
                "checkpoint must be field-identical except origin/dataType (differs at '\(key)')"
            )
        }
    }

    func testPlistRoundTrip() throws {
        let record = Self.makeCapturedRecord()
        // Serialize through a real plist so only plist-safe types survive.
        let data = try PropertyListSerialization.data(
            fromPropertyList: record.plistRawValue, format: .binary, options: 0
        )
        let raw = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let restored = try XCTUnwrap(SyaiUploadRecord(plistRawValue: raw))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(restored.voltage, 31)
    }

    func testPlistRoundTripWithVoltage() throws {
        let record = SyaiUploadRecord(
            runSec: 3600, voltage: 30, receivedAtMs: 1_785_344_523_987, frontIdx: 1733,
            glucoseMmol: 9.2, current: 18612, temperatureC: 33.6,
            origin: Data([0, 0, 197, 6, 148, 72, 0, 120, 0, 0, 224, 12])
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: record.plistRawValue, format: .binary, options: 0
        )
        let raw = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let restored = try XCTUnwrap(SyaiUploadRecord(plistRawValue: raw))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(restored.voltage, 30)
    }

    func testSensorRecordServerDeviceIdRoundTrip() throws {
        let keyGroup = SyaiKeyGroup(raw: Data(repeating: 0xAB, count: 96))
        let deviceInfo = DeviceInfo(
            mac: "AA:BB:CC:DD:EE:FF", serialNo: "SER1", batchNo: "BATCH", deviceType: "X1",
            deviceVersion: "E2.0.1", coefficients: Calibration.appDefaultCoefficientsFixture,
            k: 1.25, b: -3.5, produceTime: Date(timeIntervalSince1970: 1_700_000_000),
            activeDuration: 14 * 24 * 3600, preheatDuration: 1800
        )
        var record = SyaiSensorRecord(deviceInfo: deviceInfo, keyGroup: keyGroup)
        // Records persisted before this field existed decode it as nil (absent key).
        let legacy = try XCTUnwrap(SyaiSensorRecord(rawValue: record.rawValue))
        XCTAssertNil(legacy.serverDeviceId)

        record.serverDeviceId = 11_994_938
        let data = try PropertyListSerialization.data(
            fromPropertyList: record.rawValue, format: .binary, options: 0
        )
        let raw = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let restored = try XCTUnwrap(SyaiSensorRecord(rawValue: raw))
        XCTAssertEqual(restored.serverDeviceId, 11_994_938)
        XCTAssertEqual(restored, record)
    }
}
