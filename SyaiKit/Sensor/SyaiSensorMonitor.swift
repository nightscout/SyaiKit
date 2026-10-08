//
//  SyaiSensorMonitor.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import os.log

public final class SyaiSensorMonitor: @unchecked Sendable {
    public typealias ReadingHandler = @Sendable(GlucoseSample) -> Void
    public typealias UploadRecordHandler = @Sendable(SyaiUploadRecord) -> Void
    public typealias DisconnectHandler = @Sendable() -> Void
    public typealias StatusHandler = @Sendable(String) -> Void
    public typealias TerminalFaultHandler = @Sendable(SyaiSensorFault) -> Void
    public typealias BackfillCompleteHandler = @Sendable() -> Void
    public typealias NotifyInfoHandler = @Sendable(String) -> Void

    private let session: SyaiSensorSession

    public var peripheralID: UUID { session.peripheralID }
    public var reportedCmdState: Int? { session.reportedCmdState }
    private let sensorKit: SyaiBLE
    private let decoder = SyaiGlucoseDecoder()
    private let lock = NSLock()

    private var calibration: Calibration
    private var task: Task<Void, Never>?
    private var faultTask: Task<Void, Never>?
    private var notifyInfoTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var batchWatchdogTask: Task<Void, Never>?

    /// Rearmed on every frame; forces a real disconnect if the BLE link stays
    /// nominally connected but the sensor goes silent, since that produces no
    /// CoreBluetooth disconnect on its own.
    private var staleWatchdogTask: Task<Void, Never>?

    private var readingHandler: ReadingHandler?
    private var uploadRecordHandler: UploadRecordHandler?
    private var disconnectHandler: DisconnectHandler?
    private var statusHandler: StatusHandler?
    private var terminalFaultHandler: TerminalFaultHandler?
    private var backfillCompleteHandler: BackfillCompleteHandler?
    private var notifyInfoHandler: NotifyInfoHandler?

    /// Sticky once a fault arrives: firmware fault-clear semantics are unknown,
    /// so there is no signal to reset this short of a fresh session.
    private var faultActive = false

    /// Previous sample used to derive trend/rate-of-change. Tracked separately
    /// per source so a historical-backfill burst can't corrupt the realtime
    /// trend's continuity, or vice versa.
    private var lastRealtimeSample: (sequence: UInt16, valueMgDL: Double, elapsedSeconds: TimeInterval)?
    private var lastHistoricalSample: (sequence: UInt16, valueMgDL: Double, elapsedSeconds: TimeInterval)?
    private static let maxTrendGapMinutes: Double = 6

    /// A record's elapsed-seconds field is `60·index + offset`. The offset is
    /// constant for a sensor but differs between them (60, 62 and 69 seen), so
    /// it is learned rather than assumed: live frames carry an index the sensor
    /// states itself, which pins it exactly.
    private var elapsedOffset: TimeInterval?

    /// How far a backfilled record's own clock may sit from what its position
    /// in the batch implies. Records are exactly 60 s apart, so half that is
    /// the widest value that still names one record: at 30 s a reading is
    /// equidistant between two indices, hence rejected. Measured deviation is
    /// zero, so anything below this behaves the same on real data.
    private static let elapsedLabelTolerance: TimeInterval = 30

    private let logger = SyaiLogger(category: "SyaiSensorMonitor")

    init(session: SyaiSensorSession, sensorKit: SyaiBLE, calibration: Calibration) {
        self.session = session
        self.sensorKit = sensorKit
        self.calibration = calibration
    }

    static func make(session: SyaiSensorSession, sensorKit: SyaiBLE, calibration: Calibration) -> SyaiSensorMonitor {
        SyaiSensorMonitor(session: session, sensorKit: sensorKit, calibration: calibration)
    }

    public func setHandlers(
        onReading: @escaping ReadingHandler,
        onDisconnect: @escaping DisconnectHandler,
        onStatus: @escaping StatusHandler = { _ in },
        onTerminalFault: @escaping TerminalFaultHandler = { _ in },
        onUploadRecord: @escaping UploadRecordHandler = { _ in },
        onBackfillComplete: @escaping BackfillCompleteHandler = {},
        onNotifyInfo: @escaping NotifyInfoHandler = { _ in }
    ) {
        lock.withLock {
            readingHandler = onReading
            uploadRecordHandler = onUploadRecord
            disconnectHandler = onDisconnect
            statusHandler = onStatus
            terminalFaultHandler = onTerminalFault
            backfillCompleteHandler = onBackfillComplete
            notifyInfoHandler = onNotifyInfo
        }
    }

    public func start() {
        let alreadyRunning = lock.withLock { task != nil }
        guard !alreadyRunning else { return }

        let newTask = Task { [weak self] in
            guard let self else { return }
            self.emitStatus("Waiting for first reading")
            self.armStaleWatchdog()
            for await frame in self.session.glucoseFrames() {
                if Task.isCancelled { break }
                self.handle(frame)
            }
            logger.debug("monitor: frame stream ended; invoking disconnect handler")
            let handler = self.lock.withLock { self.disconnectHandler }
            handler?()
        }
        lock.withLock { task = newTask }

        let newFaultTask = Task { [weak self] in
            guard let self else { return }
            for await fault in self.session.faultEvents() {
                if Task.isCancelled { break }
                self.logger.error("sensor fault received at \(fault.receivedAt): \(String(describing: fault.kind))")
                let onTerminal = self.lock.withLock { () -> TerminalFaultHandler? in
                    self.faultActive = true
                    return self.terminalFaultHandler
                }
                // A terminal fault outlives the session: `faultActive` resets on the
                // next reconnect, but a cmd-state-latched sensor is finished, so the
                // manager persists it into rawState instead.
                if fault.isTerminal { onTerminal?(fault) }
            }
        }
        lock.withLock { faultTask = newFaultTask }

        let newNotifyInfoTask = Task { [weak self] in
            guard let self else { return }
            for await orgHex in self.session.notifyInfoEvents() {
                if Task.isCancelled { break }
                let handler = self.lock.withLock { self.notifyInfoHandler }
                handler?(orgHex)
            }
        }
        lock.withLock { notifyInfoTask = newNotifyInfoTask }

        let newBatchTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.session.historicalBatchEvents() {
                if Task.isCancelled { break }
                self.handleBatchStatus(status)
            }
        }
        lock.withLock { batchTask = newBatchTask }
    }

    /// Each backfill packet reports its own paging status, so no cross-packet
    /// reassembly is needed. The watchdog timeout is a generous guess so a
    /// stalled batch doesn't leave the caller waiting forever.
    private func handleBatchStatus(_ status: SyaiHistoricalBatchStatus) {
        let watchdog = lock.withLock { () -> Task<Void, Never>? in
            let watchdog = batchWatchdogTask
            batchWatchdogTask = nil
            return watchdog
        }
        watchdog?.cancel()
        switch status {
        case let .packetReceived(startIndex, recordCount, surplusPackage):
            logger.debug(
                "received backfill packet: startIndex=\(startIndex) records=\(recordCount) "
                    + "surplus=\(surplusPackage)"
            )
            guard surplusPackage >= 1 else { return }
            // Requests are sized to fit one packet, so a paged response means
            // this device's packets are smaller than assumed: a lower
            // negotiated MTU than the 176 B the sizing is based on. Harmless on
            // firmware that pages correctly; on firmware that doesn't, the
            // per-record clock check drops the batch and the gap can't close,
            // so make the broken assumption loud rather than silent.
            logger.warning(
                "backfill paged unexpectedly: this packet holds \(recordCount) records, "
                    + "fewer than the request was sized for (surplus=\(surplusPackage))"
            )
            let newWatchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.batchWatchdogTimeout * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.logger.debug(
                    "backfill stalled: no packet within "
                        + "\(Int(Self.batchWatchdogTimeout))s of surplus=\(surplusPackage) "
                        + "(startIndex=\(startIndex)), giving up on this batch"
                )
                // A stall shouldn't strand whatever the manager already buffered;
                // flush it rather than leaving it to sit until the next reconnect.
                let handler = self.lock.withLock { self.backfillCompleteHandler }
                handler?()
            }
            lock.withLock { batchWatchdogTask = newWatchdog }
        case .batchComplete:
            logger.debug("backfill batch complete")
            let handler = lock.withLock { backfillCompleteHandler }
            handler?()
        }
    }

    private static let batchWatchdogTimeout: TimeInterval = 15

    private static let staleWatchdogTimeout: TimeInterval = 6 * 60

    /// Cancel-and-rearm on every sign of life. If nothing arrives in time,
    /// request a real disconnect so CoreBluetooth drives the normal reconnect
    /// path and a stuck-but-still-connected link isn't stranded. Keeps retrying
    /// every `staleWatchdogTimeout` rather than firing once, since the forced
    /// `disconnect()` is only a request — if it doesn't produce a real
    /// CoreBluetooth callback (e.g. the link already died silently), a
    /// single-shot watchdog would leave the monitor stranded forever.
    private func armStaleWatchdog() {
        let old = lock.withLock { staleWatchdogTask }
        old?.cancel()
        let newWatchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(Self.staleWatchdogTimeout * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let hasFault = self.lock.withLock { self.faultActive }
                // A fault is already surfaced via terminalFaultHandler; forcing a
                // reconnect on top of it would just churn a sensor known to be failing.
                guard !hasFault else { return }
                self.logger.debug("no frame within \(Int(Self.staleWatchdogTimeout))s; forcing disconnect to trigger recovery")
                self.session.disconnect()
            }
        }
        lock.withLock { staleWatchdogTask = newWatchdog }
    }

    public func stop() {
        let (t, ft, nt, bt, wt, sw) = lock.withLock { () -> (
            Task<Void, Never>?, Task<Void, Never>?, Task<Void, Never>?,
            Task<Void, Never>?, Task<Void, Never>?, Task<Void, Never>?
        ) in
            let t = task
            let ft = faultTask
            let nt = notifyInfoTask
            let bt = batchTask
            let wt = batchWatchdogTask
            let sw = staleWatchdogTask
            task = nil
            faultTask = nil
            notifyInfoTask = nil
            batchTask = nil
            batchWatchdogTask = nil
            staleWatchdogTask = nil
            return (t, ft, nt, bt, wt, sw)
        }
        t?.cancel()
        ft?.cancel()
        nt?.cancel()
        bt?.cancel()
        wt?.cancel()
        sw?.cancel()
    }

    public func disconnect() {
        stop()
        session.disconnect()
    }

    public func endSensor() async throws {
        try await session.endSensor()
    }

    public func requestHistoricalBackfill(fromSequence: UInt16, count: UInt16) async throws {
        try await session.requestHistorical(fromIndex: fromSequence, count: count)
    }

    private func emitStatus(_ text: String) {
        let h = lock.withLock { statusHandler }
        h?(text)
    }

    private func handle(_ frame: SyaiDecryptedFrame) {
        armStaleWatchdog()
        let (cal, handler, uploadHandler, fault) = lock.withLock {
            (calibration, readingHandler, uploadRecordHandler, faultActive)
        }
        do {
            let raw = try sensorKit.rawChannels(from: frame)
            // A backfilled record's index is synthesised from its position in
            // the batch (the sensor doesn't put one in the record), so a
            // firmware that mis-serves a request silently relabels real
            // readings onto the wrong minutes. The record's own elapsed field
            // is the check: it must agree with the index we just gave it.
            // Seen in the field on E2.0.1, which answers a large request by
            // replaying its previous responses in a loop while the batch
            // header keeps counting; the readings are genuine but land at
            // wrong times. Dropping rather than relabelling is deliberate:
            // when a record's two identities disagree we don't know which is
            // wrong, and the grid watermark re-requests whatever we drop.
            if !frame.isHistorical {
                lock.withLock { elapsedOffset = raw.v2 - 60 * Double(frame.sequence) }
            } else if let offset = lock.withLock({ elapsedOffset }) {
                let implied = 60 * Double(frame.sequence) + offset
                if abs(raw.v2 - implied) >= Self.elapsedLabelTolerance {
                    logger.warning(
                        "dropping backfilled seq=\(frame.sequence): its own clock says record \(Int((raw.v2 - offset) / 60)) "
                            + SyaiFrameParser.captureLine(for: frame)
                    )
                    return
                }
            }
            let output = try decoder.glucose(from: raw, calibration: cal)
            let (trend, rate) = deriveTrend(frame: frame, valueMgDL: output.adjustedGlucoseMgDL, elapsedSeconds: raw.v2)
            let sample = GlucoseSample(
                date: frame.receivedAt,
                valueMgDL: output.adjustedGlucoseMgDL,
                trend: trend,
                rateOfChangeMgDLPerMinute: rate,
                sequence: frame.sequence,
                rawBaseMgDL: output.rawGlucoseMgDL,
                rawCurrent: raw.v0,
                elapsedSeconds: raw.v2,
                condition: output.condition,
                hasBlockingIssue: fault,
                source: frame.isHistorical ? .historicalBackfill : .realtime
            )
            logger.info(
                SyaiFrameParser.captureLine(for: frame)
                    + " v0=\(Int(raw.v0)) v1=\(raw.v1) v2=\(Int(raw.v2))"
                    + " base=\(Int(output.rawGlucoseMgDL)) adj=\(Int(output.adjustedGlucoseMgDL))"
            )
            handler?(sample)
            // Telemetry mirror: built from the same frame+raw+output and
            // emitted only after the reading is forwarded, so the upload
            // path can never delay dosing. Nothing is emitted on decode
            // failure, the catch below already skips, and an undecodable
            // record has no trusted fields.
            let uploadRecord = SyaiUploadRecord(
                runSec: UInt32(raw.v2),
                voltage: SyaiUploadRecord.voltage(
                    fromPlaintext: frame.plaintext,
                    parseVersion: frame.parseVersion
                ),
                receivedAtMs: Int64(frame.receivedAt.timeIntervalSince1970 * 1000),
                frontIdx: frame.sequence,
                glucoseMmol: SyaiUploadRecord.mmol(fromMgDL: output.rawGlucoseMgDL),
                current: UInt32(raw.v0),
                temperatureC: raw.v1,
                origin: frame.plaintext
            )
            uploadHandler?(uploadRecord)
        } catch {
            logger.error("decode failed: \(String(describing: error)) " + SyaiFrameParser.captureLine(for: frame))
        }
    }

    private func deriveTrend(
        frame: SyaiDecryptedFrame, valueMgDL: Double, elapsedSeconds: TimeInterval
    ) -> (GlucoseSample.Trend, Double?) {
        let previous = lock.withLock { () -> (sequence: UInt16, valueMgDL: Double, elapsedSeconds: TimeInterval)? in
            let previous = frame.isHistorical ? lastHistoricalSample : lastRealtimeSample
            if frame.isHistorical {
                lastHistoricalSample = (frame.sequence, valueMgDL, elapsedSeconds)
            } else {
                lastRealtimeSample = (frame.sequence, valueMgDL, elapsedSeconds)
            }
            return previous
        }

        guard let previous, frame.sequence > previous.sequence else { return (.notDetermined, nil) }
        let elapsedMinutes = (elapsedSeconds - previous.elapsedSeconds) / 60
        guard elapsedMinutes > 0, elapsedMinutes <= Self.maxTrendGapMinutes else {
            return (.notDetermined, nil)
        }
        let rate = (valueMgDL - previous.valueMgDL) / elapsedMinutes
        return (Self.classifyTrend(rate: rate), rate)
    }

    private static func classifyTrend(rate: Double) -> GlucoseSample.Trend {
        if rate <= -3 { return .fallingQuickly }
        if rate <= -2 { return .falling }
        if rate < 2 { return .stable }
        if rate < 3 { return .rising }
        return .risingQuickly
    }
}
