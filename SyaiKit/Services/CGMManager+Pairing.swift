//
//  CGMManager+Pairing.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
@preconcurrency import LoopKit

public extension SyaiCGMManager {
    func activateSensor(
        preselectedMAC: String? = nil,
        onStage: @Sendable @escaping (SyaiPairingService.Stage) -> Void = { _ in }
    ) async throws {
        #if targetEnvironment(simulator)
            try await simulateActivation(mac: preselectedMAC, onStage: onStage)
        #else
        guard let sensorKit, let calibrationProvider else { throw AttachError.notConfigured }

        let service = SyaiPairingService(
            sensorKit: sensorKit,
            calibrationProvider: calibrationProvider,
            binder: makeServerDeviceBinder(),
            boundSensorLookup: makeBoundSensorLookup()
        )
        do {
            let pendingBind = state.sensors.pendingBind
            let outcome = try await service.activate(
                preselectedIdentity: preselectedMAC.map { SyaiSensorIdentity(mac: $0) },
                pendingBind: { mac in pendingBind?.mac == mac ? pendingBind : nil },
                onActivated: { [weak self] pending in
                    Task { @MainActor in
                        guard let self else { return }
                        var updated = self.state
                        updated.sensors.setPendingBind(pending)
                        self.setState(updated)
                    }
                },
                onStage: onStage
            )
            await MainActor.run { self.applyAttachOutcome(outcome) }
        } catch let failure as SyaiPairingService.Failure {
            throw AttachError.service(failure.description)
        }
        #endif
    }

    @MainActor func applyAttachOutcome(_ outcome: SyaiPairingService.AttachOutcome) {
        logger.debug("attach outcome: mac=\(SyaiRedact.mac(outcome.mac)) peripheral=\(outcome.peripheralID.uuidString)")
        var newState = state
        newState.resetSensorSession()
        plausibilityGuard = SyaiPlausibilityGuard()
        newState.sensors.adopt(
            outcome.deviceInfo, keyGroup: outcome.keyGroup,
            peripheralID: outcome.peripheralID, activatedAt: outcome.activatedAt
        )

        if let methodBlob = outcome.methodBlob {
            newState.sensors.setMethodBlob(methodBlob)
        }

        setState(newState)

        emitSensorStartEvent(for: newState)

        adopt(monitor: outcome.monitor)
    }

    @MainActor func emitSensorStartEvent(for newState: CGMManagerState) {
        guard let mac = newState.mac,
              let activeDuration = newState.activeDuration,
              let preheatDuration = newState.preheatDuration
        else { return }
        let event = PersistedCgmEvent(
            date: newState.activatedAt ?? Date(),
            type: .sensorStart,
            deviceIdentifier: mac,
            expectedLifetime: activeDuration,
            warmupPeriod: preheatDuration
        )
        logger.debug("emitting CgmEvent .sensorStart deviceIdentifier=\(SyaiRedact.mac(mac))")
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: [event])
        }
    }
}
