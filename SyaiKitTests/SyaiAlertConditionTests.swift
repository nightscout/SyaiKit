//
//  SyaiAlertConditionTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

final class SyaiAlertConditionTests: XCTestCase {
    func testAlertableLifecycleStatesMapToTheirCondition() {
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: .signalLost(since: Date())), [.signalLost])
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: .expired), [.expired])
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: .failed), [.failed])
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: .unactivated), [.unactivated])
    }

    func testBenignLifecycleStatesNeverAlert() {
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: .noSensor), [])
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: .warmup(progress: 0.5, remaining: 900)), [])
        XCTAssertEqual(SyaiAlertCondition.currentlyFiring(for: .active(remaining: 3600, total: 7200)), [])
    }

    func testIdentifierIsStableAndNamespacedPerManager() {
        let identifier = SyaiAlertCondition.signalLost.identifier(managerIdentifier: "SyaiCGMManager")
        XCTAssertEqual(identifier.managerIdentifier, "SyaiCGMManager")
        XCTAssertEqual(identifier.alertIdentifier, "syai.signalLost")
    }

    func testEachConditionProducesADistinctIdentifier() {
        let identifiers = Set(SyaiAlertCondition.allCases.map { $0.identifier(managerIdentifier: "SyaiCGMManager") })
        XCTAssertEqual(identifiers.count, SyaiAlertCondition.allCases.count)
    }

    func testAlertUsesImmediateTriggerAndMatchingContent() {
        let alert = SyaiAlertCondition.failed.alert(managerIdentifier: "SyaiCGMManager")
        XCTAssertEqual(alert.trigger, .immediate)
        XCTAssertEqual(alert.foregroundContent, alert.backgroundContent)
        XCTAssertEqual(alert.interruptionLevel, .critical)
    }
}
