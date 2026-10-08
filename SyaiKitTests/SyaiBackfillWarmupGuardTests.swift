//
//  SyaiBackfillWarmupGuardTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Pins `firstBackfillableSequence` — the request-side clamp that keeps
/// historical backfill (`firePendingBackfill`) from asking the sensor for
/// warmup-era records. Warmup records exist on the sensor, but the ingest
/// preheat gate drops any sample with `date - activatedAt <= preheat`,
/// so they can never survive to Loop.
/// seq 0 is emitted ~1 min after activation (+63 s), so seq n is the reading
/// taken at minute n+1 — the 30-min preheat covers seq 0…29 and the first
/// post-warmup reading (minute 31) is index 30. Blocked request range:
/// `[0, preheatMinutes)`.
final class SyaiBackfillWarmupGuardTests: XCTestCase {
    func testStandardThirtyMinutePreheatBlocksThroughIndex29() {
        XCTAssertEqual(
            SyaiCGMManager.firstBackfillableSequence(preheatDuration: 30 * 60),
            30,
            "30-min preheat: sequences 0…29 are warmup-era, first requestable is 30 (the minute-31 reading)"
        )
    }

    func testFirstRequestableIndexEqualsPreheatMinutes() {
        for minutes in [1, 15, 30, 60, 120] {
            XCTAssertEqual(
                SyaiCGMManager.firstBackfillableSequence(preheatDuration: TimeInterval(minutes * 60)),
                UInt16(minutes)
            )
        }
    }

    func testZeroAndNegativePreheatBlocksNothing() {
        XCTAssertEqual(SyaiCGMManager.firstBackfillableSequence(preheatDuration: 0), 0)
        XCTAssertEqual(SyaiCGMManager.firstBackfillableSequence(preheatDuration: -60), 0)
    }

    func testAbsurdPreheatSaturatesInsteadOfTrapping() {
        XCTAssertEqual(
            SyaiCGMManager.firstBackfillableSequence(preheatDuration: .greatestFiniteMagnitude),
            UInt16.max
        )
    }
}

/// Pins `isWarmup` — the single test for "this reading was taken during
/// warmup", used both to keep the reading out of `recentSamples` and to stop it
/// reaching Loop. A fresh sensor's first records decode to ~31 mmol/L, so a
/// warmup reading is wrong rather than merely unforwarded; nothing should be
/// able to display one.
final class SyaiWarmupReadingTests: XCTestCase {
    private let preheat: TimeInterval = 30 * 60

    func testBoundaryIsInclusiveOnElapsedSeconds() {
        XCTAssertTrue(SyaiCGMManager.isWarmup(elapsedSeconds: 0, preheatDuration: preheat))
        XCTAssertTrue(SyaiCGMManager.isWarmup(elapsedSeconds: preheat - 1, preheatDuration: preheat))
        XCTAssertTrue(SyaiCGMManager.isWarmup(elapsedSeconds: preheat, preheatDuration: preheat))
        XCTAssertFalse(SyaiCGMManager.isWarmup(elapsedSeconds: preheat + 1, preheatDuration: preheat))
    }

    func testUnknownDurationsAreNotWarmup() {
        XCTAssertFalse(SyaiCGMManager.isWarmup(elapsedSeconds: 60, preheatDuration: nil))
        XCTAssertFalse(SyaiCGMManager.isWarmup(elapsedSeconds: nil, preheatDuration: preheat))
    }

    /// The record index is NOT a usable proxy for elapsed time. Cadence is
    /// exactly 60 s on both firmwares, but index 0 does not sit at the same
    /// offset: `runSec == 60·idx + 60` on the V1.6 fresh-activation capture,
    /// and `60·idx + 62` across 1165 consecutive V1.7 records with zero
    /// variance. A 30-minute preheat therefore ends after index 29 on one and
    /// index 28 on the other — which is exactly why `isWarmup` tests elapsed
    /// seconds and never a sequence range.
    func testWarmupBoundaryIndexIsFirmwareDependent() {
        func lastWarmupIndex(offset: TimeInterval) -> Int? {
            (0 ... 40).last {
                SyaiCGMManager.isWarmup(
                    elapsedSeconds: 60 * TimeInterval($0) + offset, preheatDuration: preheat
                )
            }
        }
        XCTAssertEqual(lastWarmupIndex(offset: 60), 29, "V1.6 mapping")
        XCTAssertEqual(lastWarmupIndex(offset: 62), 28, "V1.7 mapping")
    }

    /// Backfill must never request a record ingest would drop. The clamp is one
    /// index conservative on the V1.7 mapping — it skips index 29, a real
    /// post-warmup reading — which costs nothing, because the first grid index
    /// at or after either boundary is 30 either way.
    func testBackfillClampNeverRequestsAWarmupRecord() {
        let firstRequestable = SyaiCGMManager.firstBackfillableSequence(preheatDuration: preheat)
        XCTAssertEqual(firstRequestable, 30)
        for offset in [60.0, 62.0] {
            XCTAssertFalse(
                SyaiCGMManager.isWarmup(
                    elapsedSeconds: 60 * TimeInterval(firstRequestable) + offset,
                    preheatDuration: preheat
                ),
                "index \(firstRequestable) is past preheat on both mappings"
            )
        }
    }
}

/// Pins `isPastWear` — the ingest gate that drops records the sensor keeps
/// streaming after its wear window ends. The boundary matches the lifecycle's
/// `age >= wear`, so no reading can outlive the expired verdict.
final class SyaiExpiredReadingTests: XCTestCase {
    private let wear: TimeInterval = 14 * 24 * 60 * 60

    func testBoundaryMatchesLifecycleExpiry() {
        XCTAssertFalse(SyaiCGMManager.isPastWear(elapsedSeconds: wear - 1, activeDuration: wear))
        XCTAssertTrue(SyaiCGMManager.isPastWear(elapsedSeconds: wear, activeDuration: wear))
        XCTAssertTrue(SyaiCGMManager.isPastWear(elapsedSeconds: wear + 60, activeDuration: wear))
    }

    func testUnknownDurationsAreNotExpired() {
        XCTAssertFalse(SyaiCGMManager.isPastWear(elapsedSeconds: wear + 60, activeDuration: nil))
        XCTAssertFalse(SyaiCGMManager.isPastWear(elapsedSeconds: nil, activeDuration: wear))
    }
}
