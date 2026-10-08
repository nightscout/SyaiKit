//
//  CGMManager+EndSensor.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public extension SyaiCGMManager {
    enum EndSensorError: Error, CustomStringConvertible {
        case noSensor
        case serverRejected(String)
        /// The active shutdown attempt below couldn't reach the sensor within
        /// the timeout. Nothing has been touched yet (no unbind, no state
        /// change) - the caller decides whether to retry or to call
        /// `endSensor(force: true)` and proceed without confirmation.
        case shutdownNotConfirmed
        public var description: String {
            switch self {
            case .noSensor:
                return "No sensor is paired."
            case let .serverRejected(code):
                return "Syai refused to end the session (\(code))."
            case .shutdownNotConfirmed:
                return "Could not confirm the sensor shut down."
            }
        }
    }

    enum EndSensorStage {
        case confirmingShutdown
        case releasingAccount
    }

    /// Whether "End Sensor" applies: the sensor has reported itself dead, but
    /// keeps its radio and account binding until explicitly ended.
    var canEndSensor: Bool {
        state.mac != nil && sensorLifecycle.needsEnding
    }

    /// Finalize a spent sensor: shut the hardware down over BLE, release the
    /// account bind, then retire the record. The shutdown write runs first and
    /// is actively confirmed; an orphaned-but-alive sensor (account released but
    /// hardware still transmitting) can never be re-paired, so the unbind only
    /// runs after the shutdown is acknowledged or the caller forces past an
    /// unreachable sensor.
    func endSensor(
        force: Bool = false,
        onStage: @Sendable @escaping (EndSensorStage) -> Void = { _ in }
    ) async throws {
        guard let mac = state.mac else { throw EndSensorError.noSensor }
        logger.info("=== END SENSOR: mac=\(SyaiRedact.mac(mac)) force=\(force) ===")

        onStage(.confirmingShutdown)
        if !force {
            guard await deliverConfirmedShutdown() else {
                logger.warning("end sensor: could not confirm hardware shutdown within the timeout")
                throw EndSensorError.shutdownNotConfirmed
            }
        } else if let monitor = await MainActor.run(body: { self.monitor }) {
            // One more opportunistic try even when forcing through: cheap, and
            // still better than skipping it outright if the link happens to be
            // back up.
            do {
                try await monitor.endSensor()
                logger.info("end sensor: hardware shutdown confirmed on forced attempt")
            } catch {
                logger.warning("end sensor: forcing the end without confirmed shutdown (\(error.localizedDescription))")
            }
        } else {
            logger.warning("end sensor: forcing the end without confirmed shutdown (no live link)")
        }

        onStage(.releasingAccount)
        // After the unbind these readings can never be sent; a failure only
        // changes the reason code below.
        let synced = await flushUploadsBeforeTeardown()
        // Attribution follows the sensor's state, not which button was pressed.
        let reason = SyaiUnbindReason.forLifecycle(sensorLifecycle, hasUnsyncedData: !synced)
        logger.info("end sensor: reason \(reason) (unbindType \(reason.rawValue))")

        if let binder = makeServerDeviceBinder() {
            let code = try await binder.unbind(mac: mac, reason: reason)
            guard code == "OK" || code == "SUCCESS" else {
                logger.error("end sensor: server refused the unbind (\(code))")
                throw EndSensorError.serverRejected(code)
            }
            logger.info("end sensor: account unbind accepted")
        } else {
            logger.info("end sensor: no account session; skipping the account unbind")
        }

        await MainActor.run {
            var cleared = self.state
            cleared.sensorFault = nil
            self.setState(cleared)
            self.discardSensor()
            self.updateStatusDetail(nil)
            self.evaluateAlerts()
        }
    }

    /// Actively waits for a live link and retries through drops rather than
    /// only checking whatever monitor happens to be up at the instant of the
    /// call. Reuses the existing reconnect loop instead of racing a second
    /// connection attempt.
    private func deliverConfirmedShutdown(timeout: TimeInterval = 45) async -> Bool {
        #if targetEnvironment(simulator)
            if await MainActor.run(body: { self.hasLiveLink }) { return true }
        #endif
        let deadline = Date().addingTimeInterval(timeout)
        await MainActor.run { if !self.hasLiveLink { self.scheduleReconnect() } }
        while Date() < deadline {
            if let monitor = await MainActor.run(body: { self.monitor }) {
                do {
                    try await monitor.endSensor()
                    logger.info("end sensor: hardware shutdown confirmed")
                    return true
                } catch {
                    logger
                        .warning(
                            "end sensor: shutdown write failed (\(error.localizedDescription)); waiting for the link to recover"
                        )
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func flushUploadsBeforeTeardown() async -> Bool {
        guard let service = telemetryService else { return true }
        let synced = await service.flushBeforeTeardown()
        await service.flushEvents()
        logger.info("end sensor: final sync \(synced ? "complete" : "incomplete, readings left unsent")")
        return synced
    }
}
