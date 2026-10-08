//
//  SyaiPairingServiceTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

final class SyaiPairingServiceTests: XCTestCase {
    /// NFC is off the shipping path, so the dormant-sensor copy must not
    /// suggest tapping the phone.
    func testSensorDormantNeedsNFCDescription() {
        let failure = SyaiPairingService.Failure.sensorDormantNeedsNFC
        XCTAssertEqual(failure.description, "Sensor is out of range or not advertising. Keep it nearby; \(Bundle.main.syaiHostAppName) will keep trying.")
    }

    func testDroppedAfterConnectDescription() {
        let failure = SyaiPairingService.Failure.droppedAfterConnect("peer closed")
        XCTAssertEqual(failure.description, "Lost the connection, reconnecting…")
    }
}
