//
//  SyaiSensorSessionResetTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// A sensor swap must not inherit any per-sensor session state. The concrete
/// failure this guards: a 14-day sensor ended at elapsed ~1.2M s left
/// `latestElapsedSeconds` behind, and the freshness gate then never advanced
/// for the next sensor (whose elapsed restarts near 0), so it reported
/// `.expired` for its entire session.
final class SyaiSensorSessionResetTests: XCTestCase {
    private func sample() -> GlucoseSample {
        GlucoseSample(
            date: Date(timeIntervalSince1970: 1_757_000_000), valueMgDL: 100, trend: .stable,
            rateOfChangeMgDLPerMinute: nil, sequence: 42, rawBaseMgDL: 100,
            source: .realtime
        )
    }

    func testResetClearsEveryPerSensorField() {
        var state = CGMManagerState()
        state.latestReadingTimestamp = Date()
        state.lastGridSequence = 30265
        state.latestElapsedSeconds = 1_209_600
        state.latestElapsedReceivedAt = Date()
        state.latestSample = sample()
        state.recentSamples = [sample()]
        state.latestForwardedToLoopAt = Date()
        state.sensorFault = .deviceStateObsolete(state: 4)
        state.telemetryQueue = [
            SyaiUploadRecord(
                runSec: 3600, voltage: 30, receivedAtMs: 1_785_344_523_987, frontIdx: 1733,
                glucoseMmol: 9.2, current: 18612, temperatureC: 33.6,
                origin: Data([0, 0, 197, 6, 148, 72, 0, 120, 0, 0, 224, 12])
            )
        ]

        state.resetSensorSession()

        XCTAssertNil(state.latestReadingTimestamp)
        XCTAssertNil(state.lastGridSequence)
        XCTAssertNil(state.latestElapsedSeconds)
        XCTAssertNil(state.latestElapsedReceivedAt)
        XCTAssertNil(state.latestSample)
        XCTAssertTrue(state.recentSamples.isEmpty)
        XCTAssertNil(state.latestForwardedToLoopAt)
        XCTAssertNil(state.sensorFault)
        XCTAssertTrue(state.telemetryQueue.isEmpty)
    }

    func testResetKeepsInstallAndAccountLevelState() {
        var state = CGMManagerState()
        state.latestElapsedSeconds = 1_209_600
        state.telemetryTier = .minimal
        state.telemetryDisclosureShown = true
        state.accountLockedOutElsewhere = true

        state.resetSensorSession()

        XCTAssertEqual(state.telemetryTier, .minimal)
        XCTAssertTrue(state.telemetryDisclosureShown)
        XCTAssertTrue(state.accountLockedOutElsewhere)
    }
}
