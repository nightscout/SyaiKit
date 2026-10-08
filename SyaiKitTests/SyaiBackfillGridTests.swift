//
//  SyaiBackfillGridTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Pins `isOnForwardGrid` — the 5-minute grid every reading is forwarded on,
/// live or backfilled. One shared grid, fixed by the sensor's own sequence,
/// is what keeps the two sources from interleaving a minute apart or landing
/// out of order when a gap is filled just after a fresh reading went out. It
/// also lets SyaiKit run on STOCK Trio with zero GlucoseStorage patches:
/// Trio's backfill dedupe drops any incoming point within 3.5 min of an
/// already-stored one, and `sequence % 5` clears that window.
final class SyaiBackfillGridTests: XCTestCase {
    func testGridKeepsFiveMinuteMultiples() {
        for sequence: UInt16 in [0, 5, 10, 45, 100, 500, 65535] {
            XCTAssertTrue(
                SyaiCGMManager.isOnForwardGrid(sequence: sequence),
                "seq \(sequence) should survive the grid"
            )
        }
    }

    func testGridDropsOffGridSequences() {
        for sequence: UInt16 in [1, 2, 3, 4, 6, 99, 101, 499, 65534] {
            XCTAssertFalse(
                SyaiCGMManager.isOnForwardGrid(sequence: sequence),
                "seq \(sequence) should be thinned out"
            )
        }
    }

    func testGridDensityIsExactlyOneInFive() {
        let kept = (UInt16(0) ... UInt16(999)).filter {
            SyaiCGMManager.isOnForwardGrid(sequence: $0)
        }
        XCTAssertEqual(kept.count, 200)
        // Consecutive kept sequences are exactly 5 minutes apart — no two kept
        // records can ever land inside stock Trio's 3.5-min dedupe window.
        for (a, b) in zip(kept, kept.dropFirst()) {
            XCTAssertEqual(Int(b) - Int(a), 5)
        }
    }
}

/// Pins `backfillRange` — what a gap actually asks the sensor for. The live
/// frame that triggers the request is excluded: it has already been ingested,
/// and re-requesting it lands a second copy of the same reading in Loop at the
/// same timestamp.
final class SyaiBackfillRangeTests: XCTestCase {
    private func range(
        have: UInt16, newest: UInt16, firstRequestable: UInt16 = 30, maxCount: UInt16 = 400
    ) -> (start: UInt16, count: UInt16, remaining: UInt16?)? {
        SyaiCGMManager.backfillRange(
            have: have, newest: newest, firstRequestable: firstRequestable, maxCount: maxCount
        )
    }

    func testContiguousStreamRequestsNothing() {
        XCTAssertNil(range(have: 2904, newest: 2905))
    }

    func testAlreadyHaveTheNewestRequestsNothing() {
        XCTAssertNil(range(have: 2905, newest: 2905))
        XCTAssertNil(range(have: 2910, newest: 2905))
    }

    func testHoleWithNoGridRecordIsNotRequested() {
        // seq 3064 alone: 3064 % 5 == 4, so the grid would discard it on
        // arrival — the round-trip buys nothing.
        XCTAssertNil(range(have: 3063, newest: 3065))
        XCTAssertNil(range(have: 3061, newest: 3065), "3062…3064 holds no multiple of 5")
    }

    func testBothEndsSnapToTheGrid() {
        // Hole is 3061…3074; only 3065 and 3070 would survive forwarding, and
        // the off-grid records either side of them are dead weight on the wire.
        let r = range(have: 3060, newest: 3075)
        XCTAssertEqual(r?.start, 3065)
        XCTAssertEqual(r?.count, 6, "3065…3070")
        XCTAssertNil(r?.remaining)
    }

    func testGapExcludesTheLiveFrameThatTriggeredIt() {
        // 2910 is the only grid record in 2909…2913; 2915 arrived live.
        XCTAssertNil(range(have: 2910, newest: 2915), "nothing on the grid between them")
        let r = range(have: 2905, newest: 2915)
        XCTAssertEqual(r?.start, 2910)
        XCTAssertEqual(r?.count, 1, "2915 arrived live and is already ingested")
    }

    func testWarmupEraRecordsAreClampedOut() {
        let r = range(have: 5, newest: 61, firstRequestable: 30)
        XCTAssertEqual(r?.start, 30)
        XCTAssertEqual(r?.count, 31, "30…60")
    }

    func testGapEntirelyBelowTheWarmupClampRequestsNothing() {
        XCTAssertNil(range(have: 2, newest: 20, firstRequestable: 30))
    }

    func testWideGapIsChunkedAndParksTheRemainder() {
        let r = range(have: 100, newest: 1001, maxCount: 400)
        XCTAssertEqual(r?.start, 105)
        XCTAssertEqual(r?.count, 396, "105…500, stopping on a grid index")
        XCTAssertEqual(r?.remaining, 500, "the next live sample resumes from 500")

        // Resuming from the parked remainder walks the rest of the same gap
        // without stepping over anything the chunk didn't reach.
        let next = range(have: 500, newest: 1001, maxCount: 400)
        XCTAssertEqual(next?.start, 505)
        XCTAssertEqual(next?.count, 396, "505…900")
        XCTAssertEqual(next?.remaining, 900)

        let last = range(have: 900, newest: 1001, maxCount: 400)
        XCTAssertEqual(last?.start, 905)
        XCTAssertEqual(last?.count, 96, "905…1000")
        XCTAssertNil(last?.remaining)
    }

    func testSaturatedSequencesDoNotTrap() {
        XCTAssertNil(range(have: .max, newest: .max))
        XCTAssertNil(range(have: .max, newest: 0))
        XCTAssertNil(range(have: 65530, newest: .max), "65531…65534 holds no grid record")
        let r = range(have: 65520, newest: .max)
        XCTAssertEqual(r?.start, 65525)
        XCTAssertEqual(r?.count, 6, "65525…65530")
    }
}

/// Pins the per-firmware chunk size. One history notify packet is 176 B, an
/// 8-byte header plus fixed-width records, and the sensor is only trusted to
/// serve a request that fits in one, because at least one V1.7 build mis-serves
/// a paged response while its header keeps counting correctly.
final class SyaiBackfillChunkSizeTests: XCTestCase {
    func testChunkFitsOneNotifyPacket() {
        let packetBytes = 176
        let usable = packetBytes - SyaiFrameCipher.headerWidth
        for version in ["V1.6", "V1.7"] {
            let recLen = SyaiFrameCipher.recordLength(parseVersion: version)
            let chunk = Int(SyaiCGMManager.maxBackfillRequestCount(parseVersion: version))
            XCTAssertLessThanOrEqual(
                chunk * recLen, usable,
                "\(version): a \(chunk)-record request must not spill into a second packet"
            )
        }
    }

    func testMatchesTheRecordCountsSeenOnTheWire() {
        XCTAssertEqual(SyaiCGMManager.maxBackfillRequestCount(parseVersion: "V1.7"), 18)
        XCTAssertEqual(SyaiCGMManager.maxBackfillRequestCount(parseVersion: "V1.6"), 20)
    }

    /// An unknown version must not silently get V1.6's larger chunk: 9-byte
    /// records are the safe assumption for anything we can't identify.
    func testUnknownVersionIsNotGivenTheLargerChunk() {
        let unknown = SyaiCGMManager.maxBackfillRequestCount(parseVersion: "V1.5")
        XCTAssertLessThanOrEqual(
            Int(unknown) * 9, 176 - SyaiFrameCipher.headerWidth,
            "an unidentified sensor must still fit one packet at the larger record width"
        )
    }
}
