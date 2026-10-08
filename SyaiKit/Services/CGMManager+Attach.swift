//
//  CGMManager+Attach.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public extension SyaiCGMManager {
    enum AttachError: Error, CustomStringConvertible {
        case notConfigured
        case service(String)
        public var description: String {
            switch self {
            case .notConfigured: return "Sensor stack not configured (no sensor kit / calibration provider)."
            case let .service(m): return m
            }
        }
    }

    func configure(sensorKit: SyaiBLE, calibrationProvider: CalibrationProvider) {
        self.sensorKit = sensorKit
        self.calibrationProvider = calibrationProvider
        if state.mac != nil, !hasLiveLink {
            Task { @MainActor in self.scheduleReconnect() }
        }
    }

    internal func wireStackForRestoreIfNeeded() {
        guard sensorKit == nil else { return }
        if (try? configureForAccount(sensorKit: SyaiBLE())) != nil { return }
        if state.sensors.current() != nil {
            configure(sensorKit: SyaiBLE(), calibrationProvider: SyaiUnavailableCalibrationProvider())
        }
    }

    func discoverSensorCandidates() async throws -> [SyaiSensorCandidate] {
        #if targetEnvironment(simulator)
            return await simulatedCandidates()
        #else
            guard let sensorKit else { throw AttachError.notConfigured }
            return try await sensorKit.discoverSensorCandidates()
        #endif
    }
}

private struct SyaiUnavailableCalibrationProvider: CalibrationProvider {
    func validate(mac _: String) async throws -> SyaiSensorValidation {
        throw SyaiCGMManager.AccountError.notLoggedIn
    }

    func authorizeActivation(mac _: String, authDev _: Data, authFlag _: Data) async throws -> SyaiRemoteActivation {
        throw SyaiCGMManager.AccountError.notLoggedIn
    }
}
