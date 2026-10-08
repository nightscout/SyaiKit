//
//  SyaiSensorHistoryStoreTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Covers the file-backed sensor-history mirror
/// (`Documents/syai/syai_sensor_history.plist`) that lets history survive a
/// CGM manager being deleted and re-added, since the host app deletes
/// `CGMManagerState`'s own plist wholesale on removal.
final class SyaiSensorHistoryStoreTests: XCTestCase {
    private func makeDevice(mac: String) -> DeviceInfo {
        DeviceInfo(
            mac: mac, serialNo: "SER1", batchNo: "BATCH", deviceType: "X1",
            deviceVersion: "E2.0.1", coefficients: Calibration.appDefaultCoefficientsFixture,
            k: 1.25, b: -3.5, produceTime: Date(timeIntervalSince1970: 1_700_000_000),
            activeDuration: 14 * 24 * 3600, preheatDuration: 1800
        )
    }

    override func tearDown() {
        SyaiSensorHistoryStore.save([])
        super.tearDown()
    }

    func testLoadWithNoFileReturnsEmpty() {
        SyaiSensorHistoryStore.save([])
        XCTAssertEqual(SyaiSensorHistoryStore.load(), [])
    }

    func testSaveThenLoadRoundTrips() {
        let records = [
            SyaiSensorRecord(
                deviceInfo: makeDevice(mac: "AAA"),
                keyGroup: SyaiKeyGroup(raw: Data("keys-AAA".utf8)),
                activatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                retiredAt: Date(timeIntervalSince1970: 1_700_000_200)
            ),
            SyaiSensorRecord(
                deviceInfo: makeDevice(mac: "BBB"),
                keyGroup: SyaiKeyGroup(raw: Data("keys-BBB".utf8))
            )
        ]
        SyaiSensorHistoryStore.save(records)
        XCTAssertEqual(SyaiSensorHistoryStore.load(), records)
    }

    func testSaveOverwritesPreviousContent() {
        let first = [SyaiSensorRecord(
            deviceInfo: makeDevice(mac: "AAA"),
            keyGroup: SyaiKeyGroup(raw: Data("keys-AAA".utf8))
        )]
        let second = [SyaiSensorRecord(
            deviceInfo: makeDevice(mac: "BBB"),
            keyGroup: SyaiKeyGroup(raw: Data("keys-BBB".utf8))
        )]
        SyaiSensorHistoryStore.save(first)
        SyaiSensorHistoryStore.save(second)
        XCTAssertEqual(SyaiSensorHistoryStore.load(), second)
    }
}
