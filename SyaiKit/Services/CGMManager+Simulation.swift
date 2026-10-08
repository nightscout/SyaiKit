//
//  CGMManager+Simulation.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//
//  Simulator-only stand-in for the sensor and the Syai account, so onboarding,
//  takeover and settings can be exercised without hardware or a server.
//  CoreBluetooth can't reach anything in the simulator, and a real session
//  would talk to Syai's servers, so both are replaced here:
//
//  - Empty credentials skip login. Pairing then finds a fake sensor, which
//    "activates" near the end of warmup.
//  - Any other credentials fake a login (no session, nothing is sent). The
//    account then has a fake sensor started three days ago; taking it over
//    fails the first connection attempts, as if the official app held the
//    GATT link, before it connects.
//
//  Either way the sensor streams a gentle sine wave once connected. The whole
//  file is compiled out on device; there is no runtime switch.
//

#if targetEnvironment(simulator)

    import Foundation

    extension SyaiCGMManager {
        /// Time the simulated sensor takes to "connect".
        static let simulatedConnectDelay: TimeInterval = 5
        /// Failed attempts before a taken-over sensor connects, long enough
        /// for the "Close the Syai App" prompt to show.
        static let simulatedTakeoverFailures = 3
        /// Warmup left on a freshly "activated" sensor, so the countdown shows.
        static let simulatedWarmupRemaining: TimeInterval = 60

        /// A fake login: remembered in memory only, never a real session.
        public func startSimulatedAccount() {
            simulatedAccount = true
            logger.info("simulator: fake login")
        }

        func simulatedBoundSensor() -> SyaiBoundSensor? {
            guard simulatedAccount else { return nil }
            if simulatedBound == nil {
                simulatedBound = SyaiBoundSensor(
                    deviceInfo: Self.simulatedDeviceInfo(),
                    keyGroup: SyaiKeyGroup(raw: Data(repeating: 0, count: 96)),
                    activatedAt: Date().addingTimeInterval(-3 * 86400)
                )
            }
            return simulatedBound
        }

        func simulatedCandidates() async -> [SyaiSensorCandidate] {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return [SyaiSensorCandidate(mac: Self.randomSimulatedMAC(), rssi: -58)]
        }

        /// Runs the pairing stages without BLE and adopts a fresh sensor.
        @MainActor func simulateActivation(
            mac: String?,
            onStage: @Sendable @escaping (SyaiPairingService.Stage) -> Void
        ) async throws {
            let mac = mac ?? Self.randomSimulatedMAC()
            for stage: SyaiPairingService.Stage in [.bleConnecting, .handshaking, .resolvingCalibration, .activating, .binding] {
                onStage(stage)
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            let deviceInfo = Self.simulatedDeviceInfo(mac: mac)
            configureForSimulationIfNeeded()
            var newState = state
            newState.resetSensorSession()
            newState.sensors.adopt(
                deviceInfo, keyGroup: SyaiKeyGroup(raw: Data(repeating: 0, count: 96)),
                peripheralID: UUID(),
                activatedAt: Date().addingTimeInterval(-(deviceInfo.preheatDuration - Self.simulatedWarmupRemaining))
            )
            setState(newState)
            emitSensorStartEvent(for: newState)
            connectSimulatedLink()
        }

        /// Wires a sensor kit so the reconnect/adopt guards pass; nothing is
        /// ever sent through it here.
        func configureForSimulationIfNeeded() {
            if sensorKit == nil || calibrationProvider == nil {
                configure(sensorKit: SyaiBLE(), calibrationProvider: SyaiSimulatedCalibrationProvider())
            }
        }

        /// The reconnect loop's stand-in. A sensor the host app never connected to
        /// fails a few attempts first, like one the official app still holds.
        @MainActor func runSimulatedReconnect() async {
            var failures = 0
            while !Task.isCancelled, !isDeleted, !hasLiveLink, state.sensors.current() != nil {
                updateStatusDetail(Self.statusText(for: .bleSearching))
                try? await Task.sleep(nanoseconds: UInt64(Self.simulatedConnectDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if hasNeverConnected, failures < Self.simulatedTakeoverFailures {
                    failures += 1
                    logger.info("simulator: connection attempt \(failures) refused (official app holds the link)")
                    noteConnectionFailure()
                    continue
                }
                connectSimulatedLink()
            }
        }

        @MainActor private func connectSimulatedLink() {
            simulatedLinkUp = true
            connectedAt = Date()
            firstConnectionFailed = false
            var newState = state
            if newState.sensors.current()?.peripheralID == nil {
                newState.sensors.setPeripheralID(UUID())
            }
            setState(newState)
            updateStatusDetail(nil)
            logger.info("simulator: connected")
            startSimulatedReadings()
        }

        @MainActor private func startSimulatedReadings() {
            simulationTimer?.invalidate()
            // Real time, one record a minute: sample dates come from the
            // sensor's elapsed seconds, so a faster clock would date readings
            // in the future.
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.emitSimulatedReading() }
            }
            RunLoop.main.add(timer, forMode: .common)
            simulationTimer = timer
            emitSimulatedReading()
        }

        @MainActor func stopSimulation() {
            simulationTimer?.invalidate()
            simulationTimer = nil
            simulatedLinkUp = false
        }

        @MainActor private func emitSimulatedReading() {
            guard let activatedAt = state.activatedAt else { return }
            let now = Date()
            let elapsed = now.timeIntervalSince(activatedAt)
            let sequence = UInt16(clamping: max(0, Int(elapsed / 60) - 1))
            // Gentle wander around 120 mg/dL so trend arrows and the chart move.
            let phase = now.timeIntervalSince1970 / 600
            let value = (120 + 35 * sin(phase)).rounded()
            let rate = ((35 * cos(phase) / 10) * 10).rounded() / 10
            let trend: GlucoseSample.Trend = rate <= -2 ? .falling : rate >= 2 ? .rising : .stable
            ingest(GlucoseSample(
                date: now,
                valueMgDL: value,
                trend: trend,
                rateOfChangeMgDLPerMinute: rate,
                sequence: sequence,
                rawBaseMgDL: value,
                rawCurrent: 30000,
                elapsedSeconds: elapsed,
                source: .realtime
            ))
        }

        private static func simulatedDeviceInfo(mac: String = randomSimulatedMAC()) -> DeviceInfo {
            DeviceInfo(
                mac: mac,
                serialNo: mac,
                batchNo: "SIMULATED",
                deviceType: "X1",
                deviceVersion: "E2.0.3(V1.7.SIMULATED)",
                coefficients: Array(repeating: 1, count: 14),
                k: 1, b: 1,
                produceTime: Date().addingTimeInterval(-60 * 86400),
                activeDuration: 14 * 86400,
                preheatDuration: 30 * 60
            )
        }

        /// What a scanned applicator yields in the simulator.
        public static func simulatedApplicatorMAC() -> String { randomSimulatedMAC() }

        /// A fresh MAC each time, so an ended simulated sensor never blocks the
        /// next one as "previously used".
        private static func randomSimulatedMAC() -> String {
            "5A1A" + (0 ..< 4).map { _ in String(format: "%02X", UInt8.random(in: 0 ... 255)) }.joined()
        }
    }

    private struct SyaiSimulatedCalibrationProvider: CalibrationProvider {
        func validate(mac _: String) async throws -> SyaiSensorValidation {
            throw SyaiCGMManager.AccountError.notLoggedIn
        }

        func authorizeActivation(mac _: String, authDev _: Data, authFlag _: Data) async throws -> SyaiRemoteActivation {
            throw SyaiCGMManager.AccountError.notLoggedIn
        }
    }

#endif
