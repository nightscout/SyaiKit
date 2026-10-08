//
//  SyaiPlausibilityGuardTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// The plausibility engine is a port of the official app's
/// `GlucoseAbnormalNotifier` configs; these tests pin the recovered numbers:
/// streak thresholds (5/35, 10/250), the mmol/L cut points, the 2000 raw
/// current floor, and the shake-point heuristic (local extremum, both
/// neighbours >= 2.0 mmol/L away, 30 accumulated points).
final class SyaiPlausibilityGuardTests: XCTestCase {
    private func feed(
        _ guard_: inout SyaiPlausibilityGuard,
        count: Int,
        from start: UInt16 = 1,
        current: Double,
        mmol: Double
    ) -> SyaiPlausibilityGuard.Event? {
        var lastEvent: SyaiPlausibilityGuard.Event?
        for i in 0 ..< count {
            if let event = guard_.record(sequence: start + UInt16(i), current: current, glucoseMmolL: mmol) {
                lastEvent = event
            }
        }
        return lastEvent
    }

    func testLowCurrentFiresAttentionOnFifthConsecutiveSample() {
        var g = SyaiPlausibilityGuard()
        XCTAssertNil(feed(&g, count: 4, current: 47, mmol: 2.0))
        XCTAssertFalse(g.attentionActive)
        let event = g.record(sequence: 5, current: 47, glucoseMmolL: 2.0)
        XCTAssertEqual(event, SyaiPlausibilityGuard.Event(reason: .lowCurrent, level: .attention))
        XCTAssertTrue(g.attentionActive)
    }

    func testLowCurrentFiresBrokenOnThirtyFifthConsecutiveSample() {
        var g = SyaiPlausibilityGuard()
        XCTAssertEqual(feed(&g, count: 34, current: 47, mmol: 2.0)?.level, .attention)
        let event = g.record(sequence: 35, current: 47, glucoseMmolL: 2.0)
        XCTAssertEqual(event, SyaiPlausibilityGuard.Event(reason: .lowCurrent, level: .broken))
    }

    func testExactlyAtThresholdIsNotAnError() {
        // The app errors only when the value is strictly below 2000.
        var g = SyaiPlausibilityGuard()
        XCTAssertNil(feed(&g, count: 40, current: 2000, mmol: 5.0))
        XCTAssertFalse(g.attentionActive)
    }

    func testOnePlausibleSampleResetsTheStreak() {
        var g = SyaiPlausibilityGuard()
        XCTAssertNil(feed(&g, count: 4, current: 47, mmol: 5.0))
        XCTAssertNil(g.record(sequence: 5, current: 10000, glucoseMmolL: 5.0))
        XCTAssertNil(feed(&g, count: 4, from: 6, current: 47, mmol: 5.0))
        XCTAssertFalse(g.attentionActive, "4+1+4 must never reach the 5-streak")
    }

    func testAttentionClearsWhenTheDataRecovers() {
        var g = SyaiPlausibilityGuard()
        _ = feed(&g, count: 5, current: 47, mmol: 2.5)
        XCTAssertTrue(g.attentionActive)
        // 2.5 mmol is above low1's 2.1 floor, so the low-current streak is
        // the only active one; a healthy sample clears it.
        XCTAssertNil(g.record(sequence: 6, current: 12000, glucoseMmolL: 5.0))
        XCTAssertFalse(g.attentionActive)
    }

    func testHigh0AndLow0UseTheShortStreak() {
        var high = SyaiPlausibilityGuard()
        XCTAssertEqual(
            feed(&high, count: 5, current: 10000, mmol: 41),
            SyaiPlausibilityGuard.Event(reason: .glucoseHigh0, level: .attention)
        )
        var low = SyaiPlausibilityGuard()
        XCTAssertEqual(
            feed(&low, count: 5, current: 10000, mmol: 0.9),
            SyaiPlausibilityGuard.Event(reason: .glucoseLow0, level: .attention)
        )
    }

    func testHigh1AndLow1NeedTenSamplesAndBreakAtTwoFifty() {
        var g = SyaiPlausibilityGuard()
        XCTAssertNil(feed(&g, count: 9, current: 10000, mmol: 36))
        XCTAssertEqual(
            g.record(sequence: 10, current: 10000, glucoseMmolL: 36),
            SyaiPlausibilityGuard.Event(reason: .glucoseHigh1, level: .attention)
        )
        XCTAssertNil(feed(&g, count: 239, from: 11, current: 10000, mmol: 36))
        XCTAssertEqual(
            g.record(sequence: 250, current: 10000, glucoseMmolL: 36),
            SyaiPlausibilityGuard.Event(reason: .glucoseHigh1, level: .broken)
        )

        var low = SyaiPlausibilityGuard()
        XCTAssertEqual(
            feed(&low, count: 10, current: 10000, mmol: 2.05),
            SyaiPlausibilityGuard.Event(reason: .glucoseLow1, level: .attention)
        )
    }

    func testBoundaryValuesAreExclusive() {
        // Level-0 boundaries (high0=40, low0=1.0) sit inside the level-1
        // detectors' ranges, so stop short of the level-1 attention count.
        for mmol in [40.0, 1.0] {
            var g = SyaiPlausibilityGuard()
            XCTAssertNil(
                feed(&g, count: 9, current: 10000, mmol: mmol),
                "mmol=\(mmol) sits exactly on a threshold and must not count"
            )
        }
        for mmol in [35.0, 2.1] {
            var g = SyaiPlausibilityGuard()
            XCTAssertNil(
                feed(&g, count: 12, current: 10000, mmol: mmol),
                "mmol=\(mmol) sits exactly on a threshold and must not count"
            )
            XCTAssertFalse(g.attentionActive)
        }
    }

    func testExactBackfillRedeliveryIsIgnored() {
        var g = SyaiPlausibilityGuard()
        XCTAssertNil(feed(&g, count: 3, current: 10000, mmol: 5.0))
        XCTAssertNil(g.record(sequence: 1, current: 47, glucoseMmolL: 0.5))
        XCTAssertNil(g.record(sequence: 3, current: 47, glucoseMmolL: 0.5))
        XCTAssertFalse(g.attentionActive)
    }

    /// Reproduces the real gap this test used to leave open: after a long
    /// disconnect, the live sample that triggers a backfill request is always
    /// fed to the guard first (it's what makes the request fire), landing on
    /// a *higher* sequence than the entire backfill batch that arrives right
    /// behind it. A monotonic "highest sequence fed" watermark would silently
    /// drop that whole batch as if it were already-seen overlap. It isn't —
    /// it's the first (and only) time the guard has seen those sequences, and
    /// a long implausible streak sitting in it should still be caught.
    func testBackfillArrivingBehindANewerLiveSampleIsStillEvaluated() {
        var g = SyaiPlausibilityGuard()
        // The live sample that triggered the backfill request: fed first,
        // sequence far ahead of the gap it's about to backfill.
        XCTAssertNil(g.record(sequence: 1000, current: 10000, glucoseMmolL: 5.0))
        // The backfill batch for the gap behind it (sequences 1..34): never
        // seen by the guard before, even though they're all < 1000. mmol
        // stays plausible so only the lowCurrent detector is in play.
        let event = feed(&g, count: 5, current: 47, mmol: 5.0)
        XCTAssertEqual(event, SyaiPlausibilityGuard.Event(reason: .lowCurrent, level: .attention))
        XCTAssertTrue(g.attentionActive)
    }

    /// Alternating 5/9 mmol/L: every interior point is an extremum 4 mmol/L
    /// from both neighbours — a shake point per triple.
    private func feedZigzag(_ g: inout SyaiPlausibilityGuard, count: Int, from start: UInt16 = 1) -> SyaiPlausibilityGuard
        .Event?
    {
        var lastEvent: SyaiPlausibilityGuard.Event?
        for i in 0 ..< count {
            let mmol = i % 2 == 0 ? 5.0 : 9.0
            if let event = g.record(sequence: start + UInt16(i), current: 10000, glucoseMmolL: mmol) {
                lastEvent = event
            }
        }
        return lastEvent
    }

    func testShakeFiresBrokenOnThirtiethPoint() {
        var g = SyaiPlausibilityGuard()
        // The first triple completes on the 3rd sample, so 30 points need 32.
        XCTAssertNil(feedZigzag(&g, count: 31))
        let event = g.record(sequence: 32, current: 10000, glucoseMmolL: 9.0)
        XCTAssertEqual(event, SyaiPlausibilityGuard.Event(reason: .shake, level: .broken))
    }

    func testShakeNeedsBothNeighboursBeyondTheDelta() {
        var g = SyaiPlausibilityGuard()
        // 1.9 mmol/L swings: big-looking but below the 2.0 delta.
        var lastEvent: SyaiPlausibilityGuard.Event?
        for i: UInt16 in 1 ... 40 {
            let mmol = i % 2 == 0 ? 5.0 : 6.9
            if let event = g.record(sequence: i, current: 10000, glucoseMmolL: mmol) { lastEvent = event }
        }
        XCTAssertNil(lastEvent)
    }

    func testShakeWindowBreaksOnASequenceGap() {
        var g = SyaiPlausibilityGuard()
        _ = g.record(sequence: 1, current: 10000, glucoseMmolL: 5.0)
        _ = g.record(sequence: 2, current: 10000, glucoseMmolL: 9.0)
        // seq 3 is missing (dropped record): 1,2,4 are not consecutive, so
        // seq 2 must not score as an extremum. If it did, 30 zigzag samples
        // after the gap would reach only 29 points and never fire.
        var lastEvent: SyaiPlausibilityGuard.Event?
        for i: UInt16 in 4 ... 34 {
            let mmol = i % 2 == 0 ? 5.0 : 9.0
            if let event = g.record(sequence: i, current: 10000, glucoseMmolL: mmol) { lastEvent = event }
        }
        XCTAssertNil(lastEvent)
        let event = g.record(sequence: 35, current: 10000, glucoseMmolL: 9.0)
        XCTAssertEqual(event, SyaiPlausibilityGuard.Event(reason: .shake, level: .broken))
    }
}

final class SyaiSignalImplausiblePersistenceTests: XCTestCase {
    func testSignalImplausibleFaultSurvivesRawStateRoundTrip() {
        var state = CGMManagerState()
        state.sensorFault = .signalImplausible
        let raw = state.rawValue
        XCTAssertEqual(raw["sensorFaultKind"] as? String, "implausible")
        XCTAssertNil(raw["sensorFaultState"], "the client-side verdict carries no cmd-state int")
        let restored = CGMManagerState(rawValue: raw)
        XCTAssertEqual(restored?.sensorFault, .signalImplausible)
        XCTAssertTrue(restored?.sensorNeedsReplacement ?? false)
    }

    func testGlucoseSampleRawCurrentSurvivesRoundTrip() {
        let sample = GlucoseSample(
            date: Date(timeIntervalSince1970: 1_757_000_000), valueMgDL: 100, trend: .stable,
            rateOfChangeMgDLPerMinute: nil, sequence: 42, rawBaseMgDL: 100,
            rawCurrent: 12345, source: .realtime
        )
        let restored = GlucoseSample(rawValue: sample.rawValue)
        XCTAssertEqual(restored?.rawCurrent, 12345)
    }

    func testLegacySampleWithoutRawCurrentDecodesAsNil() {
        var raw = GlucoseSample(
            date: Date(timeIntervalSince1970: 1_757_000_000), valueMgDL: 100, trend: .stable,
            rateOfChangeMgDLPerMinute: nil, sequence: 42, rawBaseMgDL: 100,
            source: .realtime
        ).rawValue
        raw.removeValue(forKey: "rc")
        let restored = GlucoseSample(rawValue: raw)
        XCTAssertNotNil(restored)
        XCTAssertNil(restored?.rawCurrent)
    }
}
