//
//  SyaiUnbindReasonTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Pins the `unBindDevice` attribution codes recovered from the official app's
/// `DeviceUnbindFrom` enum and index -> code jump table.
///
/// These are not cosmetic. The code tells Syai whether a sensor was retired
/// normally or died, so a wrong value misreports a hardware failure as a
/// voluntary end.
final class SyaiUnbindReasonTests: XCTestCase {
    func testCodesMatchTheAppsTable() {
        XCTAssertEqual(SyaiUnbindReason.sensorFailed.rawValue, 19) // idx 0
        XCTAssertEqual(SyaiUnbindReason.endedDuringWarmup.rawValue, 16) // idx 8
        XCTAssertEqual(SyaiUnbindReason.expired.rawValue, 10) // idx 12
        XCTAssertEqual(SyaiUnbindReason.expiredDiscardingData.rawValue, 11) // idx 14
        XCTAssertEqual(SyaiUnbindReason.endedEarly.rawValue, 13) // idx 9
        XCTAssertEqual(SyaiUnbindReason.endedEarlyDiscardingData.rawValue, 20) // idx 11, wire-confirmed
    }

    /// The app's `mine_monitor` flow tests warmup first, then expiry, then falls
    /// through to a plain early end. Our fault latch outranks all three, and
    /// neither of those two has a sync-dependent variant.
    func testLifecycleMappingMirrorsTheApp() {
        for unsynced in [true, false] {
            XCTAssertEqual(
                SyaiUnbindReason.forLifecycle(.failed, hasUnsyncedData: unsynced),
                .sensorFailed
            )
            XCTAssertEqual(
                SyaiUnbindReason.forLifecycle(
                    .warmup(progress: 0.5, remaining: 900),
                    hasUnsyncedData: unsynced
                ),
                .endedDuringWarmup
            )
        }
        XCTAssertEqual(SyaiUnbindReason.forLifecycle(.expired, hasUnsyncedData: false), .expired)
        XCTAssertEqual(SyaiUnbindReason.forLifecycle(
            .active(remaining: 3600, total: 7200),
            hasUnsyncedData: false
        ), .endedEarly)
    }

    /// A final sync that couldn't land is what separates each pair: the reading
    /// data is being discarded, and the code has to say so.
    func testUnsyncedDataSelectsTheDiscardVariant() {
        XCTAssertEqual(
            SyaiUnbindReason.forLifecycle(.expired, hasUnsyncedData: true),
            .expiredDiscardingData
        )
        XCTAssertEqual(
            SyaiUnbindReason.forLifecycle(
                .active(remaining: 3600, total: 7200),
                hasUnsyncedData: true
            ),
            .endedEarlyDiscardingData
        )
    }

    /// Neither of these describes this sensor's wear ending on its own:
    /// `signalLost` is usually transient, and `unactivated` just means the
    /// sensor's reported state doesn't match what we expect. Both are a
    /// user-chosen early end.
    func testTransientAndUnexpectedStateAreAVoluntaryEnd() {
        XCTAssertEqual(SyaiUnbindReason.forLifecycle(
            .signalLost(since: Date()),
            hasUnsyncedData: false
        ), .endedEarly)
        XCTAssertEqual(
            SyaiUnbindReason.forLifecycle(.unactivated, hasUnsyncedData: false),
            .endedEarly
        )
        XCTAssertEqual(
            SyaiUnbindReason.forLifecycle(.noSensor, hasUnsyncedData: false),
            .endedEarly
        )
    }
}
