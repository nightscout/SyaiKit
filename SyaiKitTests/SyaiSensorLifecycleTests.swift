//
//  SyaiSensorLifecycleTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// `activeDuration`/`preheatDuration` come from the server (`validateDeviceByMacV2` via
/// `DeviceInfo`) and are always present once a sensor is activated. `compute` no longer
/// substitutes a hardcoded placeholder when one is missing - that would silently report a
/// plausible-but-wrong lifecycle. Missing either one reports `.noSensor` instead.
final class SyaiSensorLifecycleTests: XCTestCase {
    private let testActiveDuration: TimeInterval = 14 * 24 * 60 * 60
    private let testWarmupDuration: TimeInterval = 30 * 60

    func testCustomPreheatDuration() {
        let activatedAt = Date().addingTimeInterval(-10 * 60)
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: Date(),
            hasLiveMonitor: true, activeDuration: testActiveDuration, preheatDuration: 5 * 60
        )
        guard case .active = phase else {
            return XCTFail("expected .active with a 5-min preheat 10 min in, got \(phase)")
        }
    }

    func testMissingPreheatDurationReportsNoSensor() {
        let activatedAt = Date().addingTimeInterval(-10 * 60)
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: nil,
            hasLiveMonitor: true, activeDuration: testActiveDuration, preheatDuration: nil
        )
        XCTAssertEqual(phase, .noSensor)
    }

    func testMissingActiveDurationReportsNoSensor() {
        let activatedAt = Date().addingTimeInterval(-10 * 60)
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: nil,
            hasLiveMonitor: true, activeDuration: nil, preheatDuration: testWarmupDuration
        )
        XCTAssertEqual(phase, .noSensor)
    }

    func testStillWithinCustomPreheatWindowReportsWarmup() {
        let activatedAt = Date().addingTimeInterval(-3 * 60)
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: nil,
            hasLiveMonitor: true, activeDuration: testActiveDuration, preheatDuration: 5 * 60
        )
        guard case let .warmup(progress, remaining) = phase else {
            return XCTFail("expected .warmup within a 5-min preheat at 3 min in, got \(phase)")
        }
        XCTAssertEqual(progress, 3.0 / 5.0, accuracy: 1E-6)
        XCTAssertEqual(remaining, 2 * 60, accuracy: 1)
    }

    func testReportedObsoleteFaultOverridesActiveTimestamps() {
        // Well within the active window by timestamps alone — the reported
        // fault must still win outright.
        let activatedAt = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: Date(),
            hasLiveMonitor: true, reportedFault: .deviceStateObsolete(state: 4)
        )
        XCTAssertEqual(phase, .failed)
    }

    func testReportedObsoleteFaultPastWearReportsExpired() {
        // The firmware latches its obsolete state when the wear window runs
        // out; that is expiry, not a malfunction.
        let activatedAt = Date().addingTimeInterval(-(testActiveDuration + 3600))
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: Date(),
            hasLiveMonitor: true, reportedFault: .deviceStateObsolete(state: 4),
            activeDuration: testActiveDuration, preheatDuration: testWarmupDuration
        )
        XCTAssertEqual(phase, .expired)
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: phase), [.expired])
    }

    func testReportedObsoleteFaultWithUnknownAgeStaysFailed() {
        // No durations to judge the wear window by — dead is the safer reading.
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: nil, latestReadingAt: Date(),
            hasLiveMonitor: true, reportedFault: .deviceStateObsolete(state: 4)
        )
        XCTAssertEqual(phase, .failed)
    }

    func testReportedUnactivatedFaultOverridesActiveTimestamps() {
        let activatedAt = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: Date(),
            hasLiveMonitor: true, reportedFault: .deviceStateUnactivated(state: 2)
        )
        XCTAssertEqual(phase, .unactivated)
    }

    func testSignalImplausibleFaultSurfacesAsFailed() {
        // The client-side plausibility verdict is not sensor-reported ground
        // truth, but it is equally terminal for the lifecycle.
        let activatedAt = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: Date(),
            hasLiveMonitor: true, reportedFault: .signalImplausible
        )
        XCTAssertEqual(phase, .failed)
        XCTAssertTrue(phase.needsEnding)
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: phase), [.failed])
    }

    func testNoReportedFaultFallsBackToTimestampMath() {
        let activatedAt = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let phase = SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, latestReadingAt: Date(),
            hasLiveMonitor: true, reportedFault: nil,
            activeDuration: testActiveDuration, preheatDuration: testWarmupDuration
        )
        guard case .active = phase else {
            return XCTFail("expected .active with no reported fault, got \(phase)")
        }
    }

    /// Only a sensor that reported itself dead offers "End Sensor". The action
    /// is irreversible, so the gate is deliberately narrow: expiry is
    /// wall-clock derived, signal loss usually resolves itself, and
    /// `unactivated` just means its reported lifecycle state doesn't match
    /// what we expect for an already-activated sensor.
    func testOnlyFailedNeedsEnding() {
        XCTAssertTrue(SyaiSensorLifecycle.failed.needsEnding)
        for phase: SyaiSensorLifecycle in [
            .noSensor, .expired, .unactivated,
            .warmup(progress: 0.5, remaining: 900),
            .active(remaining: 3600, total: 7200),
            .signalLost(since: Date())
        ] {
            XCTAssertFalse(phase.needsEnding, "\(phase) must not offer End Sensor")
        }
    }
}

/// Sensor age comes from the sensor's own elapsed-seconds field, with the phone
/// clock spanning only the silence since that record arrived. A wrong
/// `activatedAt` must not be able to misreport warmup or expiry.
final class SyaiSensorAgeTests: XCTestCase {
    private let wear: TimeInterval = 14 * 24 * 60 * 60
    private let warmup: TimeInterval = 30 * 60

    private func phase(activatedAt: Date, sensorAge: (elapsed: TimeInterval, at: Date)?) -> SyaiSensorLifecycle {
        SyaiSensorLifecycle.compute(
            sensorPaired: true, activatedAt: activatedAt, sensorAge: sensorAge,
            latestReadingAt: Date(), hasLiveMonitor: true,
            activeDuration: wear, preheatDuration: warmup
        )
    }

    func testSensorClockOverridesAWrongAnchor() {
        // Anchor says 10 minutes in (warmup); the sensor says it has been
        // running an hour. The sensor wins.
        let wrongAnchor = Date().addingTimeInterval(-10 * 60)
        guard case .active = phase(activatedAt: wrongAnchor, sensorAge: (3600, Date())) else {
            return XCTFail("expected .active from the sensor's own elapsed field")
        }

        // And the other way: anchor says two days in, sensor says still warming.
        let alsoWrong = Date().addingTimeInterval(-2 * 24 * 3600)
        guard case .warmup = phase(activatedAt: alsoWrong, sensorAge: (600, Date())) else {
            return XCTFail("expected .warmup from the sensor's own elapsed field")
        }
    }

    func testWallClockOnlySpansTheSilence() {
        // Last word from the sensor was 5 min before expiry, received 10 min
        // ago: expired, because the outage is spanned on top of sensor time.
        let phase = phase(
            activatedAt: Date().addingTimeInterval(-wear),
            sensorAge: (wear - 5 * 60, Date().addingTimeInterval(-10 * 60))
        )
        XCTAssertEqual(phase, .expired)
    }

    func testFallsBackToTheAnchorBeforeTheSensorHasReported() {
        guard case .warmup = phase(activatedAt: Date().addingTimeInterval(-10 * 60), sensorAge: nil) else {
            return XCTFail("expected .warmup from the anchor when no sensor age is known")
        }
    }
}
