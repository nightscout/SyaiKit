//
//  SyaiPairingViewModel.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Combine
import SwiftUI
import SyaiKit

@MainActor final class SyaiPairingViewModel: ObservableObject {
    enum Phase {
        case choosingMethod
        case scanning
        case confirming
        case picking
        case pairing
    }

    @Published var phase: Phase = .scanning
    @Published var candidates: [SyaiSensorCandidate] = []
    @Published var selectedMAC: String?
    /// Set when the MAC came from the applicator's QR code rather than from
    /// BLE discovery; the confirmation card shows it instead of a candidate.
    @Published var scannedMAC: String?
    @Published var statusText = String(localized: "Starting…", comment: "pairing initial status")
    @Published var errorMessage: String?
    @Published var isFinished = false

    let retiredMACs: Set<String>

    var bestCandidate: SyaiSensorCandidate? {
        candidates.first { !retiredMACs.contains($0.mac) }
    }

    private let cgmManager: SyaiCGMManager
    private let onCreated: () -> Void
    private var task: Task<Void, Never>?

    init(cgmManager: SyaiCGMManager, onCreated: @escaping () -> Void) {
        self.cgmManager = cgmManager
        self.onCreated = onCreated
        retiredMACs = Set(cgmManager.state.sensors.history().compactMap { $0.retiredAt != nil ? $0.mac : nil })
        // Without a usable camera there's nothing to choose between.
        if canScanApplicator {
            phase = .choosingMethod
        } else {
            scan()
        }
    }

    var canScanApplicator: Bool { SyaiApplicatorScannerView.isAvailable }

    /// The scanned MAC is the user's own sensor by construction, so it goes
    /// straight to confirmation: no discovery, no RSSI guess.
    func didScanApplicator(mac: String) {
        task?.cancel()
        candidates = []
        guard !retiredMACs.contains(mac) else {
            scannedMAC = nil
            selectedMAC = nil
            errorMessage = String(
                localized: "This sensor was used before and can't be paired again. Scan the applicator of a new sensor.",
                comment: "error after scanning a retired sensor"
            )
            phase = .choosingMethod
            return
        }
        errorMessage = nil
        scannedMAC = mac
        selectedMAC = mac
        phase = .confirming
    }

    func scan() {
        phase = .scanning
        errorMessage = nil
        candidates = []
        selectedMAC = nil
        scannedMAC = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.cgmManager.discoverSensorCandidates()
                guard !Task.isCancelled else { return }
                self.candidates = found
                // Auto-present only a fresh (unknown-MAC) advertiser. If the
                // only sensors heard are ones we already retired, drop to the
                // list so the user sees the badges instead of a dead auto-pick.
                if let best = found.first(where: { !self.retiredMACs.contains($0.mac) }) {
                    self.selectedMAC = best.mac
                    self.phase = .confirming
                } else {
                    self.phase = .picking
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = (error as CustomStringConvertible).description
                self.phase = .picking
            }
        }
    }

    func pair() {
        guard let mac = selectedMAC else { return }
        phase = .pairing
        errorMessage = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cgmManager.activateSensor(preselectedMAC: mac, onStage: { [weak self] stage in
                    Task { @MainActor in
                        self?.statusText = Self.text(for: stage)
                    }
                })
                guard !Task.isCancelled else { return }
                self.isFinished = true
                self.onCreated()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = (error as CustomStringConvertible).description
            }
        }
    }

    func retry() { pair() }

    func showAllSensors() {
        phase = .picking
    }

    func backToConfirmation() {
        task?.cancel()
        errorMessage = nil
        if scannedMAC != nil {
            phase = .confirming
        } else {
            phase = bestCandidate == nil ? .picking : .confirming
        }
    }

    private static func text(for stage: SyaiPairingService.Stage) -> String {
        switch stage {
        case .discoveringSensor: return String(localized: "Searching for nearby sensors…", comment: "stage discovery")
        case let .sensorFound(mac): return String(
                format: String(localized: "Found sensor %@", comment: "stage sensor found"),
                mac
            )
        case .bleSearching: return String(localized: "Searching for sensor", comment: "stage searching")
        case .bleConnecting: return String(localized: "Connecting", comment: "stage connecting")
        case .handshaking: return String(localized: "Authenticating", comment: "stage handshaking")
        case .resolvingCalibration: return String(localized: "Loading calibration", comment: "stage calibration")
        case .binding: return String(localized: "Registering sensor", comment: "stage binding")
        case .activating: return String(localized: "Activating sensor", comment: "stage activating")
        }
    }
}
