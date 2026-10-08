//
//  SyaiSensorSession.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public final class SyaiSensorSession: @unchecked Sendable {
    public let peripheralID: UUID
    public let keyGroup: SyaiKeyGroup

    private let transport: SyaiGATTTransport
    private let sessionKey: Data
    private let parseVersion: String
    private let recLen: Int
    private let aes: AESECB

    /// The cmd characteristic's lifecycle state read at connect (0 initialize,
    /// 1 self-test, 2 unactivated, 3 activated/healthy, 4+ dead), or nil if the
    /// read failed. Exposed as the raw value (not pre-filtered to just the
    /// fault case) so callers above the BLE layer, which know whether this
    /// sensor was already activated, can decide what a reported state below
    /// 3 means, not just whether it's above the obsolete threshold.
    public let reportedCmdState: Int?

    private let logger = SyaiLogger(category: "SensorSession")

    init(
        transport: SyaiGATTTransport,
        keyGroup: SyaiKeyGroup,
        sessionKey: Data,
        parseVersion: String,
        aes: AESECB,
        reportedCmdState: Int? = nil
    ) {
        self.transport = transport
        peripheralID = transport.peripheralID
        self.keyGroup = keyGroup
        self.sessionKey = sessionKey
        self.reportedCmdState = reportedCmdState
        self.parseVersion = parseVersion
        recLen = SyaiFrameCipher.recordLength(parseVersion: parseVersion)
        self.aes = aes
    }

    public func glucoseFrames() -> AsyncStream<SyaiDecryptedFrame> {
        AsyncStream { continuation in
            let live = transport.notifications(for: SyaiGATT.newGlucose)
            let history = transport.notifications(for: SyaiGATT.glucoseRecord)
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await data in live { self.emit(data, isHistorical: false, into: continuation) } }
                    group.addTask { for await data in history { self.emit(data, isHistorical: true, into: continuation) } }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func emit(
        _ notify: Data,
        isHistorical: Bool,
        into continuation: AsyncStream<SyaiDecryptedFrame>.Continuation
    ) {
        do {
            let org = try SyaiFrameCipher.decryptOrg(notify: notify, sessionKey: sessionKey, aes: aes)
            let records = try SyaiFrameCipher.split(org: org, recLen: recLen)
            let now = Date()
            for r in records {
                let frame = SyaiDecryptedFrame(
                    plaintext: r.framed, sequence: r.index, parseVersion: parseVersion,
                    receivedAt: now, isHistorical: isHistorical
                )
                continuation.yield(frame)
            }
            if isHistorical, let info = try? SyaiFrameCipher.packetInfo(org: org) {
                batchContinuation?.yield(.packetReceived(
                    startIndex: info.startIndex, recordCount: records.count,
                    surplusPackage: info.surplusPackage
                ))
                if info.isBatchComplete { batchContinuation?.yield(.batchComplete) }
            }
        } catch {
            logger.warning("frame decode skipped: \(error.localizedDescription) notify=\(SyaiDiagnostics.hex(notify))")
        }
    }

    private var batchContinuation: AsyncStream<SyaiHistoricalBatchStatus>.Continuation?

    public func historicalBatchEvents() -> AsyncStream<SyaiHistoricalBatchStatus> {
        AsyncStream { continuation in
            self.batchContinuation = continuation
        }
    }

    public func requestHistorical(fromIndex: UInt16, count: UInt16) async throws {
        var payload = Data()
        payload.append(UInt8(fromIndex & 0xFF))
        payload.append(UInt8(fromIndex >> 8))
        payload.append(UInt8(count & 0xFF))
        payload.append(UInt8(count >> 8))
        try await transport.write(payload, to: SyaiGATT.requestByCount, withResponse: true)
    }

    public func faultEvents() -> AsyncStream<SyaiSensorFault> {
        AsyncStream { continuation in
            if let state = reportedCmdState, state > SyaiBLE.healthyCmdState {
                logger.error("device state obsolete (cmd-state \(state)); sensor must be replaced")
                continuation.yield(SyaiSensorFault(
                    kind: .deviceStateObsolete(state: state),
                    raw: Data([UInt8(clamping: state)]),
                    receivedAt: Date()
                ))
            }
            let errors = transport.notifications(for: SyaiGATT.errorInfo)
            let task = Task {
                for await data in errors {
                    let hex = data.map { String(format: "%02x", $0) }.joined()
                    if let frame = SyaiNotifyInfo.decode(data) {
                        self.logger.info("\(frame.logDescription)")
                    } else {
                        self.logger.info("errorInfo (undecodable, \(data.count) B): \(hex)")
                    }

                    // Mirrors the official app's `cgm_notify_info` telemetry event,
                    // fired for every errorInfo notify, not just the decodable ones.
                    self.notifyInfoContinuation?.yield(hex)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var notifyInfoContinuation: AsyncStream<String>.Continuation?

    public func notifyInfoEvents() -> AsyncStream<String> {
        AsyncStream { continuation in
            self.notifyInfoContinuation = continuation
        }
    }

    public func disconnect() { transport.disconnect() }

    public func endSensor() async throws {
        logger.info("writing end-of-sensor command to ctlDevice")
        try await transport.write(
            SyaiActivationFrame.endSensorFrame(),
            to: SyaiGATT.ctlDevice,
            withResponse: true
        )
    }
}
