//
//  SyaiTraceIDTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Validates the `traceId` generator against real UUIDs emitted by the official app.
///
/// The vectors are verbatim app output paired with the timestamp header the same request
/// carried, so the decode assertions are checked against ground truth rather than against
/// our own encoder's idea of the format.
final class SyaiTraceIDTests: XCTestCase {
    /// Decoded independently in Python before being pasted here.
    private static let appVectors: [(uuid: String, utc: String)] = [
        ("00d20260-8cd2-11f1-ac48-1b26fbf14ace", "2026-07-31 11:21:40.998"),
        ("019b0bd0-8cdf-11f1-ac48-1b26fbf14ace", "2026-07-31 12:54:45.773"),
        ("01a34930-8cdf-11f1-ac48-1b26fbf14ace", "2026-07-31 12:54:45.827"),
        ("01b300a0-8cdf-11f1-ac48-1b26fbf14ace", "2026-07-31 12:54:45.930")
    ]

    private static let gregorianOffset: UInt64 = 0x01B2_1DD2_1381_4000

    private func decodeTimestamp(_ uuid: String) throws -> TimeInterval {
        let parts = uuid.split(separator: "-")
        let low = try XCTUnwrap(UInt64(parts[0], radix: 16))
        let mid = try XCTUnwrap(UInt64(parts[1], radix: 16))
        let hiVer = try XCTUnwrap(UInt64(parts[2], radix: 16))
        let ticks = low | (mid << 32) | ((hiVer & 0x0FFF) << 48)
        return TimeInterval(ticks - Self.gregorianOffset) / 1E7
    }

    private func version(_ uuid: String) throws -> Int {
        let group = uuid.split(separator: "-")[2]
        let value = try XCTUnwrap(UInt16(group, radix: 16))
        return Int((value >> 12) & 0xF)
    }

    func testAppVectorsAreVersion1AndDecodeToTheirWallClock() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")

        for vector in Self.appVectors {
            XCTAssertEqual(try version(vector.uuid), 1, "\(vector.uuid) should be v1")
            let expected = try XCTUnwrap(formatter.date(from: vector.utc))
            let decoded = try decodeTimestamp(vector.uuid)
            XCTAssertEqual(
                decoded,
                expected.timeIntervalSince1970,
                accuracy: 0.001,
                "\(vector.uuid) should decode to \(vector.utc)"
            )
        }
    }

    /// The app's node has the multicast bit set — a random node, not a hardware MAC.
    /// This is why generating a random one is faithful rather than lazy.
    func testAppNodeIsARandomNodeNotAMAC() throws {
        for vector in Self.appVectors {
            let node = vector.uuid.split(separator: "-")[4]
            let firstOctet = try XCTUnwrap(UInt8(node.prefix(2), radix: 16))
            XCTAssertEqual(firstOctet & 0x01, 0x01, "multicast bit must be set")
        }
    }

    func testGeneratedIDMatchesTheAppsShape() throws {
        let id = SyaiTraceID.next()

        let groups = id.split(separator: "-")
        XCTAssertEqual(groups.map(\.count), [8, 4, 4, 4, 12], "wrong group layout: \(id)")
        XCTAssertEqual(id, id.lowercased())
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit || $0 == "-" }, "non-hex character in \(id)")

        // Version 1 — the whole point (Foundation's UUID() would be 4 here).
        XCTAssertEqual(try version(id), 1)

        // Variant: top two bits of clock_seq_hi are `10`, as in the app's `ac48`.
        let clockSeqHi = try XCTUnwrap(UInt8(groups[3].prefix(2), radix: 16))
        XCTAssertEqual(clockSeqHi & 0xC0, 0x80)

        // Random-node marker, matching the app.
        let nodeFirst = try XCTUnwrap(UInt8(groups[4].prefix(2), radix: 16))
        XCTAssertEqual(nodeFirst & 0x01, 0x01)
    }

    func testGeneratedTimestampTracksTheSuppliedClock() throws {
        let now = Date()
        let decoded = try decodeTimestamp(SyaiTraceID.next(now: now))
        // Millisecond resolution (plus a sub-ms tick), like the app.
        XCTAssertEqual(decoded, now.timeIntervalSince1970, accuracy: 0.002)
    }

    /// Ids minted inside one millisecond must stay distinct — that's what the
    /// same-millisecond tick counter is for.
    func testIDsMintedInTheSameMillisecondAreDistinctAndOrdered() throws {
        let instant = Date()
        let ids = (0 ..< 50).map { _ in SyaiTraceID.next(now: instant) }

        XCTAssertEqual(Set(ids).count, ids.count, "same-millisecond ids collided")
        let timestamps = try ids.map { try decodeTimestamp($0) }
        XCTAssertEqual(timestamps, timestamps.sorted(), "same-millisecond ids must be monotonic")
    }

    /// The node and clock_seq are stable for the process.
    func testNodeAndClockSeqAreStableAcrossCalls() {
        let ids = (0 ..< 20).map { _ in SyaiTraceID.next() }
        let nodes = Set(ids.map { $0.split(separator: "-")[4] })
        let clockSeqs = Set(ids.map { $0.split(separator: "-")[3] })
        XCTAssertEqual(nodes.count, 1, "node must not change between requests")
        XCTAssertEqual(clockSeqs.count, 1, "clock_seq must not change between requests")
    }
}
