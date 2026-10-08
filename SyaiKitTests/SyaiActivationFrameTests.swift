//
//  SyaiActivationFrameTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Byte-exact validation of `SyaiActivationFrame` payload bytes.
final class SyaiActivationFrameTests: XCTestCase {
    /// The per-batch coefficient set (box `SDEN10/003SD2606.001`) that the golden
    /// 60-byte coefficient frame was computed from — NOT the app's hardcoded
    /// product defaults (`Calibration.appDefaultCoefficientsFixture`), which differ.
    private static let batchCoefficients: [Double] = [
        0.1, 0.5, 18.5, 0.0, -0.0014, 0.5212, -0.2606, 0.015,
        0.95, 0.8, 1.1, 0.05, 172_800, 1.0
    ]

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    func testFloat32BESpotValues() {
        XCTAssertEqual(hex(Data(SyaiActivationFrame.float32BE(0.1))), "3D CC CC CD")
        XCTAssertEqual(hex(Data(SyaiActivationFrame.float32BE(0.5))), "3F 00 00 00")
        XCTAssertEqual(hex(Data(SyaiActivationFrame.float32BE(18.5))), "41 94 00 00")
        XCTAssertEqual(hex(Data(SyaiActivationFrame.float32BE(0.0))), "00 00 00 00")
        XCTAssertEqual(hex(Data(SyaiActivationFrame.float32BE(172_800))), "48 28 C0 00")
        XCTAssertEqual(hex(Data(SyaiActivationFrame.float32BE(1.0))), "3F 80 00 00")
    }

    func testUInt32LE() {
        XCTAssertEqual(hex(Data(SyaiActivationFrame.uint32LE(1_209_600))), "00 75 12 00")
        XCTAssertEqual(hex(Data(SyaiActivationFrame.uint32LE(0))), "00 00 00 00")
    }

    /// Checked against the **real GATT write the official app made** for the same
    /// sensor whose server-supplied coefficients are in `Self.batchCoefficients`,
    /// so this is a true end-to-end vector: server record in, app's on-wire bytes out.
    ///
    /// The captured renderer shows a typed-array view header before the wire bytes
    /// and stops at 60 bytes, cutting the frame mid-way through its 14th float, so
    /// the last 4 bytes below (`80 3F` completing 1.0, then the CRC) are the only
    /// part not directly witnessed.
    ///
    /// ⚠️ This test previously asserted **big-endian** floats and called itself
    /// "byte exact" while only checking our own output against itself. All 13 fully
    /// visible coefficients in the capture decode correctly as little-endian and as
    /// garbage as big-endian (`cdcccc3d` = 0.1 LE vs -4.29e8 BE), so the builder was
    /// corrected.
    func testCoefficientFrameMatchesTheAppsRealWrite() {
        // Exactly the bytes in the log, minus the view-header artifact.
        let capturedPrefix =
            "09 0E CD CC CC 3D 00 00 00 3F 00 00 94 41 00 00 00 00 34 80 B7 BA " +
            "5D 6D 05 3F 5D 6D 85 BE 8F C2 75 3C 33 33 73 3F CD CC 4C 3F CD CC 8C 3F " +
            "CD CC 4C 3D 00 C0 28 48 00 00"

        let frame = SyaiActivationFrame.coefficientFrame(Self.batchCoefficients)
        XCTAssertEqual(frame.count, 60, "1 opcode + 1 count + 14×f32 + 2 CRC")
        XCTAssertEqual(
            hex(frame.prefix(56)),
            capturedPrefix,
            "must reproduce the app's write byte-for-byte"
        )

        // Beyond the capture's cutoff: the rest of the 14th float (1.0 → 00 00 80 3F LE)
        // and the CRC. This is a CHANGE-DETECTOR, not a validation: `"80 3F 9C FF"` is
        // computed by our own `coefficientFrame`, not witnessed in any capture. It exists
        // so a future edit to the LE float encoder or the CRC routine gets caught, not to
        // assert correctness against ground truth — that would be the exact
        // self-referential anti-pattern this test replaced.
        XCTAssertEqual(hex(frame.suffix(4)), "80 3F 9C FF")
    }

    func testCoefficientFrameFloatsAreLittleEndian() {
        let frame = SyaiActivationFrame.coefficientFrame([0.1])
        // 0.1f = 0x3DCCCCCD → LE bytes CD CC CC 3D.
        XCTAssertEqual(hex(frame.prefix(6)), "09 01 CD CC CC 3D")
    }

    func testActiveDuration14Days() {
        // activeExpireTime/1000 = 1_209_600 s = 14 days.
        XCTAssertEqual(hex(SyaiActivationFrame.activeDurationPayload(seconds: 1_209_600)), "00 75 12 00")
    }

    /// `CgmAuth.encrypt` zero-fills to one AES block; the cipher is built with
    /// `padding: null`, so there is no PKCS7 anywhere in this path. Both real ENC'd
    /// activation payloads are sub-block, so this is the difference between the write
    /// the sensor accepts and a garbage block.
    func testEncPayloadsAreZeroPaddedNotPKCS7() {
        // The duration write, with the V1.6 sensor's real value (1_816_200 → 88 B6 1B 00).
        let duration = SyaiActivationFrame.activeDurationPayload(seconds: 1_816_200)
        XCTAssertEqual(
            hex(SyaiActivationFrame.zeroPadToBlock(duration)),
            "88 B6 1B 00 00 00 00 00 00 00 00 00 00 00 00 00",
            "PKCS7 would put 0C×12 here"
        )

        let cmd = Data(SyaiActivationFrame.cmdActivate)
        XCTAssertEqual(
            hex(SyaiActivationFrame.zeroPadToBlock(cmd)),
            "03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
            "PKCS7 would put 0F×15 here"
        )
    }

    /// The app only ever pads *up to* one block — it never appends a whole extra block
    /// to an already-aligned payload the way PKCS7 does.
    func testAlreadyAlignedPayloadIsNotPadded() {
        let block = Data(repeating: 0xAB, count: 16)
        XCTAssertEqual(SyaiActivationFrame.zeroPadToBlock(block), block)
    }

    /// `3`, not the `6` blutter prints for `_active`'s Smi-tagged list element.
    func testActivateCommandByte() {
        XCTAssertEqual(SyaiActivationFrame.cmdActivate, [0x03])
    }

    func testAdvanceWakeUpFrame() {
        XCTAssertEqual(hex(SyaiActivationFrame.advanceWakeUpFrame()), "0A 02 00 00 00 00")
    }

    func testDelayWakeUpFrameLittleEndianDuration() {
        // 0A 01 <dur:4 LE>. 3600 s = 0x00000E10 → LE 10 0E 00 00.
        XCTAssertEqual(hex(SyaiActivationFrame.delayWakeUpFrame(durationSeconds: 3600)), "0A 01 10 0E 00 00")
    }

    /// The lifecycle channel takes a bare little-endian control word: no opcode
    /// byte, no length prefix, no CRC. Pinned to the byte because the write is
    /// irreversible on real hardware and a mis-encoded word could land on a
    /// neighbouring command.
    func testEndSensorFrame() {
        XCTAssertEqual(hex(SyaiActivationFrame.endSensorFrame()), "07 00 00 00")
    }
}
