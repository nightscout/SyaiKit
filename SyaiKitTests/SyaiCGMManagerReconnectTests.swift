//
//  SyaiCGMManagerReconnectTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Pins `scheduleReconnect`'s backoff schedule — the piece of the reconnect
/// retry loop that's a pure function and testable without standing up a full
/// `SyaiCGMManager` (which needs a LoopKit `CGMManagerDelegate`/delegateQueue
/// this test target doesn't wire up). `SyaiBLE` exposes no CoreBluetooth
/// primitives yet, so capped backoff-and-retry (rather than CB-event-driven
/// retry) is what's implementable today; this guards that schedule doesn't
/// regress to either hammering (no backoff) or stalling (unbounded growth).
final class SyaiCGMManagerReconnectTests: XCTestCase {
    func testBackoffIsNonDecreasing() {
        var previous: TimeInterval = 0
        for failures in 0 ..< 10 {
            let backoff = SyaiCGMManager.reconnectBackoff(failures: failures)
            XCTAssertGreaterThanOrEqual(backoff, previous)
            previous = backoff
        }
    }

    func testBackoffCapsAtTheSchedulesLastValue() {
        let cap = SyaiCGMManager.reconnectBackoffSeconds.last!
        XCTAssertEqual(SyaiCGMManager.reconnectBackoff(failures: SyaiCGMManager.reconnectBackoffSeconds.count), cap)
        XCTAssertEqual(SyaiCGMManager.reconnectBackoff(failures: 1000), cap)
    }

    func testBackoffNeverHammersImmediately() {
        // failures=0 shouldn't happen in practice (the loop only backs off
        // after a failed attempt) but a 0s backoff would defeat the point.
        XCTAssertGreaterThan(SyaiCGMManager.reconnectBackoff(failures: 0), 0)
    }
}
