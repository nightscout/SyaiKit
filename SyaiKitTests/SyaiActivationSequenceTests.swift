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

/// Pins the activation write **set and order**. The write sequence is:
///
///     writeCoefficientList → writeActiveDuration → writeRTC(0) → activate cmd
///
/// The app calls `_setCalibrationParameterIfNeed` and declines, so the sequence
/// notably **never** writes calibration parameters. These tests exist because
/// activation is a one-shot, irreversible operation on real hardware: a wrong
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

        func read(_ characteristic: CBUUID) async throws -> Data {
            reads.append(characteristic)
            if let readError { throw readError }
            return cmdReadPayload ?? Data([UInt8(cmdStateOnRead & 0xFF)])
        }

        func write(_ data: Data, to characteristic: CBUUID, withResponse: Bool) async throws {
            writes.append(Write(characteristic: characteristic, data: data, withResponse: withResponse))
        }

        func notifications(for _: CBUUID) -> AsyncStream<Data> {
            AsyncStream { $0.finish() }
        }

        func disconnect() {}
    }

    /// Identity "encryption" so the test can read the plaintext a step wrote. The real
    /// AES-ECB wrap is covered by `SyaiActivationFrameTests` / `SyaiTransportTests`.
    private let passthroughEncrypt: (Data) throws -> Data = { $0 }

    private func calibration() -> Calibration {
        Calibration(coefficients: (0 ..< 14).map { Double($0) + 0.5 }, k: 2.0, b: 3.0)
    }

    /// A device record shaped like a real `validateDeviceByMacV2` response.
    private func deviceInfo(activeDuration: TimeInterval, preheat: TimeInterval) -> DeviceInfo {
        DeviceInfo(
            mac: "112233445566", serialNo: "", batchNo: "", deviceType: "X1",
            deviceVersion: "V1.6.SH22523.3",
            coefficients: Array(repeating: 0, count: 14), k: 1, b: 1,
            produceTime: Date(timeIntervalSince1970: 0),
            expireTime: nil, activeDuration: activeDuration, preheatDuration: preheat
        )
    }

    func testWriteSetAndOrderMatchTheOfficialApp() async throws {
        let transport = RecordingTransport()
        try await SyaiActivationSequence.run(
            transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
        )

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

    /// The calibration frame (`0x0B` on ctlDevice) must not appear at all. Guarding on
    /// the opcode rather than the count so a reordering can't mask a re-introduction.
    func testCalibrationParameterIsNeverWritten() async throws {
        let transport = RecordingTransport()
        try await SyaiActivationSequence.run(
            transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
        )

        let ctlWrites = transport.writes.filter { $0.characteristic == SyaiGATT.ctlDevice }
        XCTAssertEqual(ctlWrites.count, 1, "ctlDevice should carry only the coefficient frame")
        for write in ctlWrites {
            XCTAssertNotEqual(
                write.data.first,
                SyaiActivationFrame.opCalibration,
                "the official app never writes calibration parameters"
            )
        }
        XCTAssertEqual(ctlWrites.first?.data.first, SyaiActivationFrame.opCoefficient)
    }

    /// The end-of-sensor control word shares `ctlDevice` with the coefficient
    /// frame and permanently kills the hardware. Activation must never emit it.
    func testEndSensorCommandIsNeverWrittenDuringActivation() async throws {
        let transport = RecordingTransport()
        try await SyaiActivationSequence.run(
            transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
        )

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
        try await SyaiActivationSequence.run(
            transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
        )

        let rtc = try XCTUnwrap(transport.writes.first { $0.characteristic == SyaiGATT.currentTime })
        XCTAssertEqual(Array(rtc.data), [0, 0, 0, 0], "RTC payload must be int32LE(0)")
    }

    /// The written duration is `(activeExpireTime + preheatPeriodTime) / 1000`, and it
    /// is **per-sensor**. These are the two real records + the exact plaintexts the app
    /// wrote for them:
    ///
    ///     V1.7 AABBCCDDEEFF  activeExpireTime 1_209_600_000 ms + preheat 1_800_000 ms
    ///                        → wrote `087c1200` = 1_211_400
    ///     V1.6 112233445566  activeExpireTime 1_814_400_000 ms + preheat 1_800_000 ms
    ///                        → wrote `88b61b00` = 1_816_200
    ///
    /// The old code wrote a hardcoded 1_209_600 for both — over a week short on
    /// the longer-duration V1.6 unit, on a write that cannot be undone.
    func testDurationMatchesTheCapturedPlaintextPerSensor() async throws {
        let vectors: [(info: DeviceInfo, expected: [UInt8])] = [
            (deviceInfo(activeDuration: 1_209_600, preheat: 1800), [0x08, 0x7C, 0x12, 0x00]),
            (deviceInfo(activeDuration: 1_814_400, preheat: 1800), [0x88, 0xB6, 0x1B, 0x00])
        ]
        for vector in vectors {
            let transport = RecordingTransport()
            try await SyaiActivationSequence.run(
                transport: transport, calibration: calibration(),
                durationSeconds: SyaiActivationSequence.activationDurationSeconds(for: vector.info),
                encrypt: passthroughEncrypt
            )

            let write = try XCTUnwrap(transport.writes.first { $0.characteristic == SyaiGATT.activeDuration })
            XCTAssertEqual(
                Array(write.data),
                vector.expected,
                "duration payload must match the app's captured plaintext"
            )
        }
    }

    /// The activate command is `0x03`. Blutter renders `_active`'s literal as `6`, but
    /// that is the **Smi tag** (`3 << 1`) of a `List<int>` element — see
    /// `SyaiActivationFrame.cmdActivate`. Pinned here because `0x06` is not a command
    /// the sensor knows, so getting it wrong makes activation fail on hardware only.
    func testActivateCommandByteIsThree() async throws {
        let transport = RecordingTransport()
        try await SyaiActivationSequence.run(
            transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
        )

        let cmd = try XCTUnwrap(transport.writes.first { $0.characteristic == SyaiGATT.cmd })
        XCTAssertEqual(
            Array(cmd.data),
            [0x03],
            "activate cmd is 3 (Smi-untagged), not the literal 6 in the disassembly"
        )
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
                try await SyaiActivationSequence.run(
                    transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
                )
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
            try await SyaiActivationSequence.run(
                transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
            )
            XCTAssertEqual(transport.writes.count, 4, "cmd-state \(state) must still activate")
        }
    }

    /// `readCmd` takes `bytes.first`; trailing bytes are the sensor's business, not
    /// ours. The old little-endian fold turned `00 01` into 256 and would have skipped
    /// activation on a factory sensor reporting state 0.
    func testOnlyTheFirstByteOfTheCmdReadIsTheState() async throws {
        let transport = RecordingTransport()
        transport.cmdReadPayload = Data([0x00, 0x01, 0xFF, 0xFF])
        try await SyaiActivationSequence.run(
            transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
        )
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
            try await SyaiActivationSequence.run(
                transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
            )
            XCTFail("expected the read error to propagate")
        } catch {
            XCTAssertTrue(transport.writes.isEmpty, "no writes may be issued when the state is unknown")
        }
    }

    func testEmptyCmdReadAbortsWithoutWrites() async {
        let transport = RecordingTransport()
        transport.cmdReadPayload = Data()
        do {
            try await SyaiActivationSequence.run(
                transport: transport, calibration: calibration(), encrypt: passthroughEncrypt
            )
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
}
