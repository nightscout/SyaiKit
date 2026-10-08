//
//  CGMManager+Reconnect.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

extension SyaiCGMManager {
    @MainActor func adopt(monitor: SyaiSensorMonitor) {
        guard !isDeleted else {
            monitor.stop()
            return
        }

        logger.debug("adopted monitor; mac=\(SyaiRedact.mac(state.mac))")
        // Disconnect any monitor being replaced: an unstopped monitor's stale
        // watchdog keeps forcing disconnects on the same peripheral forever,
        // and a still-connected one holds a zombie link. The replaced monitor's
        // delayed disconnect tail is ignored by the identity check in
        // handleMonitorDisconnect, so this can't tear down the new monitor.
        self.monitor?.disconnect()
        self.monitor = monitor
        connectedAt = Date()
        firstConnectionFailed = false

        var newState = state
        newState.sensors.setPeripheralID(monitor.peripheralID)
        setState(newState)

        if let reported = monitor.reportedCmdState {
            if reported > SyaiBLE.healthyCmdState {
                markSensorFailed(SyaiSensorFault(
                    kind: .deviceStateObsolete(state: reported),
                    raw: Data([UInt8(clamping: reported)]),
                    receivedAt: Date()
                ))
            } else if reported < SyaiBLE.healthyCmdState, state.activatedAt != nil {
                markSensorFailed(SyaiSensorFault(
                    kind: .deviceStateUnactivated(state: reported),
                    raw: Data([UInt8(clamping: reported)]),
                    receivedAt: Date()
                ))
            }
        }

        // The monitor fires its handlers from background stream tasks; every
        // state-touching handler hops to the main actor at this boundary so
        // manager state is only ever mutated there. The frame stream is serial,
        // so the hops stay in record order.
        monitor.setHandlers(
            onReading: { [weak self] sample in
                Task { @MainActor in self?.ingest(sample) }
            },
            onDisconnect: { [weak self, weak monitor] in
                guard let monitor else { return }
                Task { @MainActor in self?.handleMonitorDisconnect(monitor) }
            },
            onStatus: { [weak self] text in self?.updateStatusDetail(text) },
            onTerminalFault: { [weak self] fault in
                Task { @MainActor in self?.markSensorFailed(fault) }
            },
            onUploadRecord: { [weak self] record in
                guard let service = self?.telemetryService else { return }
                Task { await service.enqueue(record) }
            },
            onBackfillComplete: { [weak self] in
                Task { @MainActor in self?.flushPendingBackfill() }
            },
            onNotifyInfo: { [weak self] orgHex in
                guard let self, let service = self.telemetryService, let mac = self.state.mac else { return }
                Task { await service.reportNotifyInfo(orgHex: orgHex, mac: mac) }
            }
        )
        monitor.start()

        if let service = telemetryService {
            Task { await service.reportConnState(connected: true) }
        }
    }

    @MainActor func markSensorFailed(_ fault: SyaiSensorFault) {
        guard !isDeleted, state.sensorFault == nil else { return }
        logger.error("marking sensor as needing replacement: \(String(describing: fault.kind))")
        var newState = state
        newState.sensorFault = fault.kind
        setState(newState)
        if sensorLifecycle == .expired {
            updateStatusDetail(LocalizedString(
                "Sensor expired, replace sensor",
                comment: "Status: sensor wear window ended"
            ))
        } else {
            updateStatusDetail(SyaiSensorLifecycle.faultStatusDetail(for: fault.kind))
        }
    }

    @MainActor private func handleMonitorDisconnect(_ monitor: SyaiSensorMonitor) {
        // A replaced monitor's stop() lets its stream tasks end with a delayed
        // disconnect tail; only the current monitor may tear things down.
        guard self.monitor === monitor else { return }
        flushPendingBackfill()
        // Stop the outgoing monitor rather than only dropping the reference:
        // its stale watchdog otherwise keeps looping and forcing disconnects
        // on the same peripheral, including mid-reconnect.
        self.monitor = nil
        monitor.stop()
        connectedAt = nil
        guard !isDeleted else { return }
        logger.debug("monitor disconnect; scheduling reconnect")
        scheduleReconnect()
        if let service = telemetryService {
            Task {
                await service.reportConnState(connected: false)
                await service.flushEvents()
            }
        }
    }

    static let reconnectBackoffSeconds: [TimeInterval] = [2, 5, 10, 20, 40, 80, 160, 300]

    private static let rescanGapSeconds: TimeInterval = 5

    static func reconnectBackoff(failures: Int) -> TimeInterval {
        reconnectBackoffSeconds[min(max(failures, 0), reconnectBackoffSeconds.count - 1)]
    }

    @MainActor func scheduleReconnect() {
        guard !isDeleted, !hasLiveLink else { return }
        guard state.sensors.current() != nil else { return }
        guard reconnectAttempt == nil else { return }
        guard let sensorKit else {
            logger.debug("reconnect: no sensor kit wired yet; skipping")
            return
        }
        guard let provider = calibrationProvider else {
            logger.debug("reconnect: no calibration provider wired yet; skipping")
            return
        }

        isReconnecting = true
        reconnectAttempt = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isReconnecting = false
                self.reconnectAttempt = nil
            }
            #if targetEnvironment(simulator)
                // CoreBluetooth can't reach anything here; see CGMManager+Simulation.
                await self.runSimulatedReconnect()
                _ = (sensorKit, provider)
            #else
            var failures = 0
            while !Task.isCancelled, !self.isDeleted, self.monitor == nil {
                guard let record = self.state.sensors.current() else {
                    self.logger.debug("reconnect: sensor no longer present; stopping retry loop")
                    return
                }
                do {
                    let outcome = try await self.attemptReconnect(record: record, sensorKit: sensorKit, provider: provider)
                    // No need to arm a backfill here: ingest compares every live
                    // sample against the record watermark, so the gap this
                    // disconnect opened is detected on the first frame back.
                    self.adopt(monitor: outcome.monitor)
                    let attemptsNote = failures > 0 ? " after \(failures) failed attempt(s)" : ""
                    self.logger.debug("reconnect: succeeded\(attemptsNote)")
                    return
                } catch SyaiPairingService.Failure.sensorDormantNeedsNFC {
                    failures += 1
                    self.noteConnectionFailure()
                    self.logger
                        .debug(
                            "reconnect attempt \(failures): no advertisement seen; rescanning in \(Int(Self.rescanGapSeconds))s"
                        )
                    self.updateStatusDetail(SyaiPairingService.Failure.sensorDormantNeedsNFC.description)
                    try? await Task.sleep(nanoseconds: UInt64(Self.rescanGapSeconds * 1_000_000_000))
                } catch let SyaiPairingService.Failure.droppedAfterConnect(reason) {
                    failures += 1
                    self.noteConnectionFailure()
                    self.logger
                        .debug(
                            "reconnect attempt \(failures): dropped after connect (\(reason)); retrying in \(Int(Self.rescanGapSeconds))s"
                        )
                    self.updateStatusDetail(SyaiPairingService.Failure.droppedAfterConnect(reason).description)
                    try? await Task.sleep(nanoseconds: UInt64(Self.rescanGapSeconds * 1_000_000_000))
                } catch let SyaiPairingService.Failure.unsupportedFirmware(version) {
                    // Retrying can't help. A taken-over sensor was never ours, so
                    // drop it rather than leave End Sensor able to shut it down.
                    self.logger.error("reconnect: unsupported firmware \(version); stopping")
                    if self.hasNeverConnected { self.discardSensor() }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                    self.noteConnectionFailure()
                    let backoff = Self.reconnectBackoff(failures: failures)
                    self.logger
                        .debug(
                            "reconnect attempt \(failures) failed: \(error.localizedDescription); retrying in \(Int(backoff))s"
                        )
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
            #endif
        }
    }

    private func attemptReconnect(
        record: SyaiSensorRecord, sensorKit: SyaiBLE, provider: CalibrationProvider
    ) async throws -> SyaiPairingService.AttachOutcome {
        let service = SyaiPairingService(sensorKit: sensorKit, calibrationProvider: provider)
        return try await service.reconnect(
            mac: record.deviceInfo.mac, keyGroup: record.keyGroup,
            deviceInfo: record.deviceInfo, expectedPeripheralID: record.peripheralID
        ) { [weak self] stage in
            self?.updateStatusDetail(Self.statusText(for: stage))
        }
    }

    @MainActor func noteConnectionFailure() {
        if hasNeverConnected, !firstConnectionFailed {
            logger.info("taken-over sensor unreachable; the official Syai app may still hold the connection")
            firstConnectionFailed = true
            // Re-publishes state so the host re-reads the status highlight.
            setState(state)
        }
    }

    @MainActor func cancelReconnect() {
        reconnectAttempt?.cancel()
        reconnectAttempt = nil
    }

    static func statusText(for stage: SyaiPairingService.Stage) -> String {
        switch stage {
        case .discoveringSensor: return LocalizedString("Searching for nearby sensors…", comment: "Stage: discovery")
        case let .sensorFound(mac): return String(format: LocalizedString("Found sensor %@", comment: "Stage: sensor found"), mac)
        case .bleSearching: return LocalizedString("Searching for sensor", comment: "Stage: BLE searching")
        case .bleConnecting: return LocalizedString("Connecting", comment: "Stage: connecting")
        case .handshaking: return LocalizedString("Authenticating", comment: "Stage: handshaking")
        case .resolvingCalibration: return LocalizedString("Loading calibration", comment: "Stage: calibration")
        case .binding: return LocalizedString("Registering sensor", comment: "Stage: binding")
        case .activating: return LocalizedString("Activating sensor", comment: "Stage: activating")
        }
    }
}
