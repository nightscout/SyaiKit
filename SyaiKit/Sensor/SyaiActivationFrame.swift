//
//  SyaiActivationFrame.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Byte-exact builder for Syai activation / control write payloads.
///
/// Encoding rules:
/// - Integers are little-endian.
/// - Coefficients are `float32` big-endian.
/// - CRC16/Modbus: init `0xFFFF`, poly `0xA001` (reflected), no final xor,
///   appended lo, hi (little-endian).
/// - The opcode byte is plaintext; data is AES-128 encrypted when the auth
///   session requires it, except the coefficient frame and RTC, which are
///   always plaintext.
///
/// Only the coefficient frame and the plaintext payloads below are
/// session-independent. `activeDuration`/`writeCmd` are wrapped in the per-connect
/// ephemeral AES key, so this type emits their plaintext; the AES wrap happens in
/// BLE/crypto at connect time.
///
/// The AES wrap is ECB with manual zero-padding to 16.
///
/// This type only emits payload bytes; write order and ACK semantics are owned by
/// `SyaiActivationSequence`.
public enum SyaiActivationFrame {
    /// `writeCoefficientList` frame opcode.
    public static let opCoefficient: UInt8 = 0x09

    /// Never written — kept as a named constant so a regression test can assert
    /// against a symbol instead of a magic byte.
    public static let opCalibration: UInt8 = 0x0B

    /// `writeCmd` activation arm: the single atomic write that starts the 14-day
    /// clock. The command family is initialize = 0, self-test = 1,
    /// inactive = 2, active = 3; the state-readback gate treats `>= 3` as
    /// activated.
    public static let cmdActivate: [UInt8] = [0x03]

    // The sibling commands (initialize/self-test/inactive) are deliberately not
    // exposed: inactive ends the session and must never appear in an activation
    // path, and the other two have no client-side use.
    /// Wake-command family. `0A 01 <dur:4 LE>` arms a delayed wake;
    /// `0A 02 00000000` wakes immediately.
    public static let opWake: UInt8 = 0x0A

    /// `writeBleIntervalSetting` opcode: BLE connection-parameter profile.
    public static let opBleInterval: UInt8 = 0x08

    // The remaining destructive/OTA opcodes are deliberately not modelled.
    // The only lifecycle command we send is `endSensorFrame()`, and it must
    // never appear in an activation path.

    // Primitive encoders

    /// Big-endian IEEE-754 `float32` bytes.
    public static func float32BE(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) }
    }

    /// Little-endian IEEE-754 `float32` bytes: the byte order the coefficient frame
    /// uses.
    public static func float32LE(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }

    /// Little-endian `uint32` bytes.
    public static func uint32LE(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// Pad an `ENC(...)` payload the way the app does before the AES wrap: append
    /// zero bytes up to 16, not PKCS7. Both ENC'd activation payloads are sub-block,
    /// so PKCS7 padding would produce a different ciphertext block and a rejected
    /// write.
    ///
    /// Payloads already >= 16 bytes are returned untouched.
    public static func zeroPadToBlock(_ payload: Data, blockSize: Int = 16) -> Data {
        guard payload.count < blockSize else { return payload }
        return payload + Data(repeating: 0, count: blockSize - payload.count)
    }

    // Frame builders

    /// Full on-wire coefficient frame: `[0x09][count][N x f32 LE] + CRC16(lo,hi)`.
    /// Plaintext + CRC, never AES-wrapped; fully pre-computable with no session key.
    public static func coefficientFrame(_ coefficients: [Double]) -> Data {
        var body: [UInt8] = [opCoefficient, UInt8(coefficients.count)]
        for c in coefficients {
            body.append(contentsOf: float32LE(Float(c)))
        }
        let crc = CRC16.modbus(body)
        body.append(UInt8(crc & 0xFF)) // lo
        body.append(UInt8((crc >> 8) & 0xFF)) // hi
        return Data(body)
    }

    public static func coefficientFrame(for calibration: Calibration) -> Data {
        coefficientFrame(calibration.coefficients)
    }

    /// Pre-AES active-duration payload: `int32_LE(seconds)`. On-wire = `ENC(that)`.
    /// The value is per-sensor, not a constant.
    public static func activeDurationPayload(seconds: UInt32) -> Data {
        Data(uint32LE(seconds))
    }

    /// Plaintext RTC payload: `int32_LE(epochSeconds)`. At activation the app passes `0`.
    public static func rtcPayload(epochSeconds: UInt32) -> Data {
        Data(uint32LE(epochSeconds))
    }

    // BLE connection-parameter profile

    /// `writeBleIntervalSetting`: `08 <min> <max> <latency> <timeout>`, plaintext on
    /// `ctlDevice`, written once right after auth.
    ///
    /// This is not a keepalive. The app runs a connection-parameter ladder: a fast
    /// link while the connect-time history burst drains, then relaxed to save sensor
    /// battery. Only the initial fast profile is modelled.
    public static func bleIntervalFrame(
        minInterval: UInt8,
        maxInterval: UInt8,
        latency: UInt8,
        timeout: UInt8
    ) -> Data {
        Data([opBleInterval, minInterval, maxInterval, latency, timeout])
    }

    /// The exact fast profile written at connect: `08 19 1a 04 06`
    /// (min 25, max 26, latency 4, timeout 6).
    public static func defaultBleIntervalFrame() -> Data {
        bleIntervalFrame(minInterval: 25, maxInterval: 26, latency: 4, timeout: 6)
    }

    // Wake commands

    /// Arm a delayed wake: `0A 01 <durationSeconds:4 LE>`. Plaintext, command char.
    public static func delayWakeUpFrame(durationSeconds: UInt32) -> Data {
        Data([opWake, 0x01] + uint32LE(durationSeconds))
    }

    /// Wake the sensor now (advance wake): `0A 02 00 00 00 00`. Plaintext, command char.
    public static func advanceWakeUpFrame() -> Data {
        Data([opWake, 0x02] + uint32LE(0))
    }

    // End of sensor life

    /// Device-lifecycle control word that permanently shuts a spent sensor down.
    /// One-way and unrecoverable: a sensor that has taken this write never
    /// advertises again. Only send this for a sensor the user explicitly chose to end.
    static let ctlEndSensor: UInt32 = 0x07

    /// End-of-life write for `ctlDevice`: a bare little-endian 4-byte control word,
    /// no opcode or length prefix. Plaintext, never AES-wrapped.
    public static func endSensorFrame() -> Data {
        Data(uint32LE(ctlEndSensor))
    }
}
