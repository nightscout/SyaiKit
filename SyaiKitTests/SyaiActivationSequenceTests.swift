//
//  SyaiActivationSequenceTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
@testable import SyaiKit
import XCTest

/// Pins the activation write **set and order**. The server builds and encrypts
/// the frames (`cgmAuth/verify`); this side writes them verbatim, in order:
///
///     coefficient (ctlDevice) → duration (activeDuration) → RTC(0) → activate (cmd)
///
/// Activation is a one-shot, irreversible operation on real hardware: a wrong
/// write set can only be observed on the actual sensor, so it is locked down here.
final class SyaiActivationSequenceTests: XCTestCase {
    /// Records every GATT op in order. `cmdStateOnRead` drives the `readCmd` freshness
    /// gate (`state >= 3` ⇒ already activated); `cmdReadPayload` overrides it with raw
    /// bytes so the "only the first byte counts" rule can be exercised.
    final class RecordingTransport: SyaiGATTTransport {
        struct Write { let characteristic: CBUUID
            let data: Data
            let withResponse: Bool }

        let peripheralID = UUID()
        var writes: [Write] = []
        var reads: [CBUUID] = []
        var cmdStateOnRead: Int = 0
        var cmdReadPayload: Data?
        var readError: Error?
        /// Fail the write to this characteristic, as a dropped link would.
        var failWriteTo: CBUUID?

        func read(_ characteristic: CBUUID) async throws -> Data {
            reads.append(characteristic)
            if let readError { throw readError }
            return cmdReadPayload ?? Data([UInt8(cmdStateOnRead & 0xFF)])
        }

        func write(_ data: Data, to characteristic: CBUUID, withResponse: Bool) async throws {
            struct LinkDropped: Error {}
            if characteristic == failWriteTo { throw LinkDropped() }
            writes.append(Write(characteristic: characteristic, data: data, withResponse: withResponse))
        }

        func notifications(for _: CBUUID) -> AsyncStream<Data> {
            AsyncStream { $0.finish() }
        }

        func disconnect() {}
    }

    /// Distinct, recognisable stand-ins for the server's encrypted frames.
    private let coefficientFrame = Data([0xC0, 0xEF, 0x01])
    private let durationFrame = Data([0xD0, 0x02])
    private let activateFrame = Data([0xAC, 0x03])

    private func activation(
        coefficient: Data? = Data([0xC0, 0xEF, 0x01]),
        duration: Data? = Data([0xD0, 0x02]),
        activate: Data? = Data([0xAC, 0x03])
    ) -> SyaiRemoteActivation {
        SyaiRemoteActivation(
            authHost: Data([0xA1]), authFlag: Data([0xF1]),
            coefficientFrame: coefficient, durationFrame: duration, activateFrame: activate
        )
    }

    func testWriteSetAndOrderMatchTheOfficialApp() async throws {
        let transport = RecordingTransport()
        try await SyaiActivationSequence.run(transport: transport, activation: activation())

        // Exactly four writes — no more (the app sends no calibration/authKey/wake-up
        // /destroy-duration writes) and no fewer.
        XCTAssertEqual(transport.writes.count, 4, "expected coefficient, duration, RTC, activate")

        XCTAssertEqual(transport.writes.map(\.characteristic), [
            SyaiGATT.ctlDevice,
            SyaiGATT.activeDuration,
            SyaiGATT.currentTime,
            SyaiGATT.cmd
        ])

        // Every activation write takes the ATT write-response ACK path.
        XCTAssertTrue(transport.writes.allSatisfy(\.withResponse))
    }

    /// The server's frames go out byte-for-byte, each to its own characteristic.
    func testServerFramesAreWrittenVerbatim() async throws {
        let transport = RecordingTransport()
        try await SyaiActivationSequence.run(transport: transport, activation: activation())

        func written(to characteristic: CBUUID) -> Data? {
            transport.writes.first { $0.characteristic == characteristic }?.data
        }
        XCTAssertEqual(written(to: SyaiGATT.ctlDevice), coefficientFrame)
        XCTAssertEqual(written(to: SyaiGATT.activeDuration), durationFrame)
        XCTAssertEqual(written(to: SyaiGATT.cmd), activateFrame)
    }

    /// A partial server answer must not leave the sensor half-written: every
    /// frame is checked before the first write.
    func testMissingFrameAbortsBeforeAnyWrite() async {
        let partials = [
            activation(coefficient: nil),
            activation(duration: nil),
            activation(activate: nil)
        ]
        for partial in partials {
            let transport = RecordingTransport()
            do {
                try await SyaiActivationSequence.run(transport: transport, activation: partial)
                XCTFail("expected .missingFrame")
            } catch let error as SyaiActivationSequence.ActivationError {
                guard case .missingFrame = error else { return XCTFail("wrong error: \(error)") }
                XCTAssertTrue(transport.writes.isEmpty, "no writes may be issued for a partial answer")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// The end-of-sensor control word shares `ctlDevice` with the coefficient
    /// frame and permanently kills the hardware. Activation must never emit it.
    func testEndSensorCommandIsNeverWrittenDuringActivation() async throws {
        let transport = RecordingTransport()
        try await SyaiActivationSequence.run(transport: transport, activation: activation())

        for write in transport.writes {
            XCTAssertNotEqual(
                write.data,
                SyaiActivationFrame.endSensorFrame(),
                "activation must never send the end-of-sensor command"
            )
        }
    }

    /// `_active` passes 0 in both captures — not a real epoch, which is what this code
    /// used to send off the back of a `[?]` guess from the field name.
    func testRTCIsWrittenAsZero() async throws {
        let transport = RecordingTransport()
        try await SyaiActivationSequence.run(transport: transport, activation: activation())

        let rtc = try XCTUnwrap(transport.writes.first { $0.characteristic == SyaiGATT.currentTime })
        XCTAssertEqual(Array(rtc.data), [0, 0, 0, 0], "RTC payload must be int32LE(0)")
    }

    /// The freshness gate still wins: an already-activated sensor must not be re-fired.
    ///
    /// **3 counts as already-active.** It is the activate command's own value, read
    /// back — the steady state of every activated sensor, not an edge case. The app
    /// bails at `>= 3` (`readCgmActiveStatus`); a `> 3` bound here would have re-run
    /// the entire write set against a live sensor.
    func testAlreadyActiveSensorIsNotRewritten() async {
        for state in [3, 4] {
            let transport = RecordingTransport()
            transport.cmdStateOnRead = state
            do {
                try await SyaiActivationSequence.run(transport: transport, activation: activation())
                XCTFail("expected .alreadyActive for cmd-state \(state)")
            } catch let error as SyaiActivationSequence.ActivationError {
                guard case let .alreadyActive(reported) = error else {
                    return XCTFail("wrong error: \(error)")
                }
                XCTAssertEqual(reported, state)
                XCTAssertTrue(transport.writes.isEmpty, "no writes may be issued once already active")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testStatesBelowThreeStillActivate() async throws {
        for state in [0, 1, 2] {
            let transport = RecordingTransport()
            transport.cmdStateOnRead = state
            try await SyaiActivationSequence.run(transport: transport, activation: activation())
            XCTAssertEqual(transport.writes.count, 4, "cmd-state \(state) must still activate")
        }
    }

    /// `readCmd` takes `bytes.first`; trailing bytes are the sensor's business, not
    /// ours. The old little-endian fold turned `00 01` into 256 and would have skipped
    /// activation on a factory sensor reporting state 0.
    func testOnlyTheFirstByteOfTheCmdReadIsTheState() async throws {
        let transport = RecordingTransport()
        transport.cmdReadPayload = Data([0x00, 0x01, 0xFF, 0xFF])
        try await SyaiActivationSequence.run(transport: transport, activation: activation())
        XCTAssertEqual(
            transport.writes.count,
            4,
            "state is byte 0 (= 0 here); trailing bytes must not inflate it"
        )
    }

    /// The cmd-state gate fails closed: a sensor whose state can't be read must
    /// not be written to. A transient read error used to fall through to the
    /// full write sequence, which on an already-activated sensor would re-write
    /// RTC(0) and re-date every reading.
    func testCmdReadErrorAbortsWithoutWrites() async {
        struct ReadFailed: Error {}
        let transport = RecordingTransport()
        transport.readError = ReadFailed()
        do {
            try await SyaiActivationSequence.run(transport: transport, activation: activation())
            XCTFail("expected the read error to propagate")
        } catch {
            XCTAssertTrue(transport.writes.isEmpty, "no writes may be issued when the state is unknown")
        }
    }

    func testEmptyCmdReadAbortsWithoutWrites() async {
        let transport = RecordingTransport()
        transport.cmdReadPayload = Data()
        do {
            try await SyaiActivationSequence.run(transport: transport, activation: activation())
            XCTFail("expected .emptyCmdRead")
        } catch let error as SyaiActivationSequence.ActivationError {
            guard case .emptyCmdRead = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(transport.writes.isEmpty, "no writes may be issued when the state is unknown")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A failed write names its step and nothing after it goes out: a link that
    /// dropped mid-sequence is retried on a fresh connection, and a future
    /// duration step-down needs to know the duration was the last write landed.
    func testInterruptedWriteNamesItsStepAndStops() async {
        let cases: [(CBUUID, SyaiActivationSequence.Step, Int)] = [
            (SyaiGATT.ctlDevice, .coefficient, 0),
            (SyaiGATT.activeDuration, .duration, 1),
            (SyaiGATT.currentTime, .rtc, 2),
            (SyaiGATT.cmd, .activate, 3)
        ]
        for (characteristic, expectedStep, landed) in cases {
            let transport = RecordingTransport()
            transport.failWriteTo = characteristic
            do {
                try await SyaiActivationSequence.run(transport: transport, activation: activation())
                XCTFail("expected .interrupted at \(expectedStep)")
            } catch let SyaiActivationSequence.ActivationError.interrupted(step, _) {
                XCTAssertEqual(step, expectedStep)
                XCTAssertEqual(transport.writes.count, landed, "no write may follow the failed one")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }
}
