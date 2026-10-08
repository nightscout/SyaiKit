//
//  SyaiActivationSequence.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public enum SyaiActivationSequence {
    private static let logger = SyaiLogger(category: "Activation")

    /// The activation writes, in order.
    public enum Step: String, Sendable {
        case coefficient, duration, rtc, activate
    }

    public enum ActivationError: Error, CustomStringConvertible {
        case alreadyActive(Int)
        case emptyCmdRead
        case missingFrame(String)
        /// The write for `step` failed, usually because the link dropped. The
        /// sensor rejects a duration it won't accept by dropping the link right
        /// after that write, which surfaces here as an interruption at `.rtc`.
        case interrupted(at: Step, String)
        public var description: String {
            switch self {
            case let .alreadyActive(s): return "sensor already activated (cmd-state \(s) >= 3)"
            case .emptyCmdRead: return "cmd characteristic read returned no bytes"
            case let .missingFrame(name): return "the server sent no \(name) frame for this sensor"
            case let .interrupted(step, reason): return "activation interrupted at the \(step.rawValue) write: \(reason)"
            }
        }
    }

    /// Writes the server-built activation frames, in the official app's order:
    /// coefficient → active duration → RTC(0) → activate cmd. The frames are
    /// already encrypted for this connection and go out verbatim; only RTC is
    /// built here (plaintext zero).
    ///
    /// Gated on the cmd characteristic: a sensor reading `>= 3` is already
    /// activated and is never written to. All three frames are checked before
    /// the first write so a partial answer can't leave the sensor half-written.
    public static func run(
        transport: SyaiGATTTransport,
        activation: SyaiRemoteActivation,
        rtcEpoch: UInt32 = 0
    ) async throws {
        let state = try await readCmdState(transport: transport)
        if state >= 3 {
            throw ActivationError.alreadyActive(state)
        }
        guard let coefficientFrame = activation.coefficientFrame else { throw ActivationError.missingFrame("coefficient") }
        guard let durationFrame = activation.durationFrame else { throw ActivationError.missingFrame("duration") }
        guard let activateFrame = activation.activateFrame else { throw ActivationError.missingFrame("activate") }

        logger.debug("activation: sensor is unactivated (cmd-state \(state)), starting write sequence")

        try await write(.coefficient, coefficientFrame, to: SyaiGATT.ctlDevice, transport)
        try await write(.duration, durationFrame, to: SyaiGATT.activeDuration, transport)
        try await write(.rtc, SyaiActivationFrame.rtcPayload(epochSeconds: rtcEpoch), to: SyaiGATT.currentTime, transport)
        try await write(.activate, activateFrame, to: SyaiGATT.cmd, transport)
        logger.debug("activation: write sequence complete")
    }

    private static func write(
        _ step: Step, _ data: Data, to characteristic: CBUUID, _ transport: SyaiGATTTransport
    ) async throws {
        do {
            try await transport.write(data, to: characteristic, withResponse: true)
        } catch {
            throw ActivationError.interrupted(at: step, error.localizedDescription)
        }
        logger.debug("activation: wrote \(step.rawValue) (\(data.count) bytes)")
    }

    static func readCmdState(transport: SyaiGATTTransport) async throws -> Int {
        let data = try await transport.read(SyaiGATT.cmd)
        if data.count != 1 {
            logger.debug("activation: cmd read returned \(data.count) bytes (expected 1); using first byte only")
        }

        // Payloads are just 1 byte but we always take first byte to match official app behavior
        guard let first = data.first else { throw ActivationError.emptyCmdRead }
        return Int(first)
    }
}
