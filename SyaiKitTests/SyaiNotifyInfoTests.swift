//
//  SyaiNotifyInfoTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Pins `SyaiNotifyInfo` to real captured `errorInfo` frames. Every vector below
/// is a verbatim payload lifted from a live log, not a constructed one — the point of
/// this decoder is to make session debugging readable, and a decoder that only agrees
/// with itself is worse than no decoder.
final class SyaiNotifyInfoTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i ..< j], radix: 16)!)
            i = j
        }
        return out
    }

    /// Five events: four watchdog kicks and one central-side teardown.
    func testDisconnectRingDecodesRealFrame() throws {
        let frame = try XCTUnwrap(SyaiNotifyInfo.decode(data(
            "0477973d130013100000b53d130013100000d43d1300131000002f3e130013100000a33e130016100000"
        )))
        XCTAssertEqual(frame.header, 0x7704)
        guard case let .disconnectLog(events) = frame.content else {
            return XCTFail("expected disconnectLog, got \(frame.content)")
        }
        XCTAssertEqual(events.count, 5, "40-byte body = 5 × 8-byte records")
        XCTAssertEqual(events.map(\.tick), [1_260_951, 1_260_981, 1_261_012, 1_261_103, 1_261_219])
        XCTAssertEqual(events.map(\.reason), [0x1013, 0x1013, 0x1013, 0x1013, 0x1016])
        XCTAssertNil(events[0].lastStatus, "0x7704 records carry no lastStatus")
        // 4 Hz tick → the last two events are 29 s apart.
        XCTAssertEqual(events[4].tickSeconds - events[3].tickSeconds, 29, accuracy: 0.01)
    }

    /// The three correlated codes get names; anything else stays hex rather than being
    /// guessed at.
    func testReasonNames() {
        XCTAssertEqual(SyaiNotifyInfo.reasonName(0x1008), "orderly")
        XCTAssertEqual(SyaiNotifyInfo.reasonName(0x1013), "abnormal/early")
        XCTAssertEqual(SyaiNotifyInfo.reasonName(0x1016), "central-side")
        XCTAssertEqual(SyaiNotifyInfo.reasonName(0x1040), "0x1040")
    }

    /// 12-byte records, not 8 — the extra field is `lastStatus`. The real frame's
    /// 60-byte body divides evenly by 12 and not by 8, which is what pins the shape.
    func testRebootRingDecodesRealFrame() throws {
        let frame = try XCTUnwrap(SyaiNotifyInfo.decode(data(
            "05770000000003000000030000000000000003000000000000000200000040100000"
                + "01000000000000000300000003000000000000000400000003000000"
        )))
        XCTAssertEqual(frame.header, 0x7705)
        guard case let .rebootLog(events) = frame.content else {
            return XCTFail("expected rebootLog, got \(frame.content)")
        }
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[2].tick, 2)
        XCTAssertEqual(events[2].reason, 0x1040)
        XCTAssertEqual(events.map { $0.lastStatus ?? 999 }, [3, 0, 1, 3, 3])
    }

    func testIntervalInfoLongAndShortForms() throws {
        let long = try XCTUnwrap(SyaiNotifyInfo.decode(data("0777860104007017")))
        XCTAssertEqual(long.content, .intervalInfo(interval: 390, delay: 4, timeout: 6000))

        let short = try XCTUnwrap(SyaiNotifyInfo.decode(data("07778601")))
        XCTAssertEqual(short.content, .intervalInfo(interval: 390, delay: nil, timeout: nil))

        let other = try XCTUnwrap(SyaiNotifyInfo.decode(data("07772d00")))
        XCTAssertEqual(other.content, .intervalInfo(interval: 45, delay: nil, timeout: nil))
    }

    /// The coefficient-echo body carries a **2-byte trailing CRC** (so it is not a
    /// clean multiple of 4), and that CRC covers the *original write frame* —
    /// `09 ‖ count ‖ floats` — including the two bytes the echo strips.
    /// Verifying it as `09 0e ‖ floats` gives 0xE427 (matching the wire), whereas the
    /// float bytes alone give 0x8EDF.
    func testCoefficientEchoDecodesWithTrailingCRC() throws {
        let frame = try XCTUnwrap(SyaiNotifyInfo.decode(data(
            "08773dcccccd3f0000004194000000000000bab780343f056d5dbe856d5d3c75c28f"
                + "3f7333333f4ccccd3f8ccccd3d4ccccd4828c0003f80000027e4"
        )))
        XCTAssertEqual(frame.header, 0x7708)
        guard case let .coefficients(values, crc, crcOK) = frame.content else {
            return XCTFail("expected coefficients, got \(frame.content)")
        }
        XCTAssertEqual(values.count, 14)
        XCTAssertEqual(crc, 0xE427)
        XCTAssertTrue(crcOK, "CRC must verify over `09 ‖ count ‖ floats`")
        // Sensor #1's real vector, read big-endian.
        XCTAssertEqual(Double(values[0]), 0.1, accuracy: 1E-6)
        XCTAssertEqual(Double(values[2]), 18.5, accuracy: 1E-6)
        XCTAssertEqual(Double(values[6]), -0.2606, accuracy: 1E-6)
        XCTAssertEqual(Double(values[12]), 172_800, accuracy: 1)
    }

    func testTrivialAndUnknownHeaders() throws {
        // 0x7706 and unknown headers both reduce to a single little-endian int.
        XCTAssertEqual(try XCTUnwrap(SyaiNotifyInfo.decode(data("06772a000000"))).content, .value(42))
        XCTAssertEqual(try XCTUnwrap(SyaiNotifyInfo.decode(data("997701"))).content, .value(1))

        // 0x7709 is UTF-8 text, not binary.
        XCTAssertEqual(try XCTUnwrap(SyaiNotifyInfo.decode(data("09774f4b"))).content, .stateText("OK"))

        // 0x770A is hex passthrough by design.
        XCTAssertEqual(
            try XCTUnwrap(SyaiNotifyInfo.decode(data("0a77deadbeef"))).content,
            .rawHex("deadbeef")
        )
    }

    /// A body that doesn't fit its header's shape must be reported as malformed with
    /// its bytes intact — never silently dropped, and never mistaken for `0x770A`'s
    /// legitimate passthrough.
    func testMalformedBodyKeepsBytes() throws {
        let frame = try XCTUnwrap(SyaiNotifyInfo.decode(data("04779153")))
        XCTAssertEqual(frame.content, .malformed(header: 0x7704, hex: "9153"))
        XCTAssertEqual(frame.orgHex, "04779153", "raw frame is always preserved")
    }

    func testTooShortFrameIsRejected() {
        XCTAssertNil(SyaiNotifyInfo.decode(Data([0x04])))
        XCTAssertNil(SyaiNotifyInfo.decode(Data()))
    }

    /// Every real frame must survive decoding and keep its raw hex — this is the
    /// property the log depends on.
    func testAllCapturedFramesRoundTripTheirRawHex() throws {
        let captured = [
            "0477973d130013100000b53d130013100000d43d1300131000002f3e130013100000a33e130016100000",
            "04779153130013100000ea53130016100000d55113001310000098521300131000005d53130013100000",
            "0777860104007017", "07778601", "07772d00"
        ]
        for hex in captured {
            let frame = try XCTUnwrap(SyaiNotifyInfo.decode(data(hex)), "failed to decode \(hex)")
            XCTAssertEqual(frame.orgHex, hex)
            if case .malformed = frame.content { XCTFail("real frame decoded as malformed: \(hex)") }
        }
    }
}
