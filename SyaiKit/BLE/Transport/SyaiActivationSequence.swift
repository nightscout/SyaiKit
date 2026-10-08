//
//  SyaiActivationSequence.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public enum SyaiActivationSequence {
    private static let logger = SyaiLogger(category: "Activation")

    public enum ActivationError: Error, CustomStringConvertible {
        case alreadyActive(Int)
        case emptyCmdRead
        public var description: String {
            switch self {
            case let .alreadyActive(s): return "sensor already activated (cmd-state \(s) >= 3)"
            case .emptyCmdRead: return "cmd characteristic read returned no bytes"
            }
        }
    }

    public static let defaultDurationSeconds: UInt32 = 1_209_600 // 14 days

    public static func activationDurationSeconds(for deviceInfo: DeviceInfo) -> UInt32 {
        UInt32(deviceInfo.activeDuration) &+ UInt32(deviceInfo.preheatDuration)
    }

    // writeCoefficientList -> writeActiveDuration -> writeRTC(0) -> cmd activate
    public static func run(
        transport: SyaiGATTTransport,
        calibration: Calibration,
        durationSeconds: UInt32 = defaultDurationSeconds,
        rtcEpoch: UInt32 = 0,
        encrypt: (Data) throws -> Data
    ) async throws {
        let state = try await readCmdState(transport: transport)
        if state >= 3 {
            throw ActivationError.alreadyActive(state)
        }

        logger.debug(
            "activation: sensor is unactivated  (cmd-state < 3), starting write sequence "
                + "(duration \(durationSeconds) s, rtc \(rtcEpoch))"
        )

        // 1. Coefficients (C0..C13).
        let coeffFrame = SyaiActivationFrame.coefficientFrame(for: calibration)
        try await transport.write(coeffFrame, to: SyaiGATT.ctlDevice, withResponse: true)
        logger.debug("activation: wrote coefficient frame (\(coeffFrame.count) bytes)")

        // 2. Active duration (ENC).
        try await transport.write(
            try encrypt(SyaiActivationFrame.activeDurationPayload(seconds: durationSeconds)),
            to: SyaiGATT.activeDuration, withResponse: true
        )
        logger.debug("activation: wrote activeDuration \(durationSeconds) s (ENC)")

        // 3. RTC (plaintext), then 4. the single atomic activate command (ENC).
        try await transport.write(
            SyaiActivationFrame.rtcPayload(epochSeconds: rtcEpoch),
            to: SyaiGATT.currentTime, withResponse: true
        )

        logger.debug("activation: wrote RTC(\(rtcEpoch))")

        try await transport.write(
            try encrypt(Data(SyaiActivationFrame.cmdActivate)),
            to: SyaiGATT.cmd, withResponse: true
        )

        logger.debug("activation: wrote activate cmd (ENC), write sequence complete")
    }

    private static func readCmdState(transport: SyaiGATTTransport) async throws -> Int {
        let data = try await transport.read(SyaiGATT.cmd)
        if data.count != 1 {
            logger.debug("activation: cmd read returned \(data.count) bytes (expected 1); using first byte only")
        }

        // Payloads are just 1 byte but we always take first byte to match official app behavior
        guard let first = data.first else { throw ActivationError.emptyCmdRead }
        return Int(first)
    }
}
