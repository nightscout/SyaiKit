//
//  SyaiTraceID.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Version-1 (time-based) UUID for the `traceId` header. Foundation's `UUID()`
/// is version 4, which would show in the version nibble on every request.
enum SyaiTraceID {
    /// 100-ns intervals between the UUID epoch (1582-10-15) and the Unix epoch.
    private static let gregorianOffset: UInt64 = 0x01B2_1DD2_1381_4000

    private static let lock = NSLock()
    /// Random per-process node with the RFC 4122 multicast bit set (not a hardware MAC).
    private static var node: [UInt8] = {
        var bytes = (0 ..< 6).map { _ in UInt8.random(in: 0 ... 255) }
        bytes[0] |= 0x01 // multicast bit: marks a non-MAC node (RFC 4122)
        return bytes
    }()

    private static let clockSeq = UInt16.random(in: 0 ... 0x3FFF)
    private static var lastMillis: UInt64 = 0
    /// 100-ns tiebreaker within a millisecond, range 0-9999.
    private static var ticksInMillis: UInt64 = 0

    /// A fresh v1 UUID, lowercase with dashes.
    static func next(now: Date = Date()) -> String {
        let millis = UInt64((now.timeIntervalSince1970 * 1000).rounded(.down))

        lock.lock()
        if millis == lastMillis {
            ticksInMillis += 1
            if ticksInMillis > 9999 { ticksInMillis = 0 } // ms will advance; just wrap
        } else {
            lastMillis = millis
            ticksInMillis = 0
        }
        let ticks = ticksInMillis
        let nodeBytes = node
        lock.unlock()

        let timestamp = millis &* 10000 &+ gregorianOffset &+ ticks

        let timeLow = UInt32(truncatingIfNeeded: timestamp)
        let timeMid = UInt16(truncatingIfNeeded: timestamp >> 32)
        let timeHiAndVersion = UInt16(truncatingIfNeeded: (timestamp >> 48) & 0x0FFF) | (1 << 12)
        let clockSeqHi = UInt8(truncatingIfNeeded: (clockSeq >> 8) & 0x3F) | 0x80 // variant 10
        let clockSeqLow = UInt8(truncatingIfNeeded: clockSeq)

        let nodeHex = nodeBytes.map { String(format: "%02x", $0) }.joined()
        return String(
            format: "%08x-%04x-%04x-%02x%02x-%@",
            timeLow,
            timeMid,
            timeHiAndVersion,
            clockSeqHi,
            clockSeqLow,
            nodeHex
        )
    }
}
