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

    /// The bind needs the server-style version; the BLE string wraps it.
    func testDeviceVersionFromFirmwareString() {
        XCTAssertEqual(
            SyaiPairingService.deviceVersion(fromFirmware: "E2.0.3(V1.7.SH22601.3),STDRD "),
            "V1.7.SH22601.3"
        )
        XCTAssertEqual(SyaiPairingService.deviceVersion(fromFirmware: "V1.6.SH22523.3 "), "V1.6.SH22523.3")
        XCTAssertEqual(SyaiPairingService.deviceVersion(fromFirmware: "E2.0.3()"), "E2.0.3()")
    }

    /// The pre-activation and post-bind coefficient sets must agree exactly;
    /// any real difference refuses the sensor.
    func testCoefficientCrossCheck() {
        let set: [Double] = [0.1, 0.5, 18.5, 0, -0.0014, 0.5212, -0.2606, 0.015, 0.95, 0.8, 1.1, 0.05, 172_800, 1]
        XCTAssertTrue(SyaiPairingService.coefficientsMatch(set, set))
        var shifted = set
        shifted[5] += 0.0001
        XCTAssertFalse(SyaiPairingService.coefficientsMatch(set, shifted))
        XCTAssertFalse(SyaiPairingService.coefficientsMatch(set, Array(set.dropLast())))
    }

    /// Only a dropped link or an interrupted write earns another connection.
    func testOnlyLinkFailuresAreRetried() {
        typealias F = SyaiPairingService.Failure
        typealias A = SyaiActivationSequence.ActivationError
        XCTAssertTrue(SyaiPairingService.isRetryableActivationFailure(F.droppedAfterConnect("x")))
        XCTAssertTrue(SyaiPairingService.isRetryableActivationFailure(A.interrupted(at: .duration, "x")))
        XCTAssertFalse(SyaiPairingService.isRetryableActivationFailure(F.unsupportedFirmware("V1.5")))
        XCTAssertFalse(SyaiPairingService.isRetryableActivationFailure(A.missingFrame("duration")))
        XCTAssertFalse(SyaiPairingService.isRetryableActivationFailure(
            SyaiServerCalibrationProvider.ServerError.business(code: "AppDevice_AlreadyUsed")
        ))
    }
}
