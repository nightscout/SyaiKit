//
//  SyaiExistingSensorViewModel.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Combine
import SwiftUI
import SyaiKit

/// Checks the account for a sensor that is already activated and bound (for
/// instance by the official app) before offering to pair a new one.
@MainActor final class SyaiExistingSensorViewModel: ObservableObject {
    enum Phase: Equatable {
        case checking
        case found(SyaiBoundSensor)
        /// Bound, but not usable (ended before, past its wear, or unsupported firmware).
        case unusable(SyaiBoundSensor, reason: String)
        case adopting(SyaiBoundSensor)
        case failed(String)
    }

    @Published var phase: Phase = .checking

    private let cgmManager: SyaiCGMManager
    private let onNoneBound: () -> Void
    private let onAdopted: () -> Void
    private var task: Task<Void, Never>?

    init(cgmManager: SyaiCGMManager, onNoneBound: @escaping () -> Void, onAdopted: @escaping () -> Void) {
        self.cgmManager = cgmManager
        self.onNoneBound = onNoneBound
        self.onAdopted = onAdopted
        check()
    }

    func check() {
        phase = .checking
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let sensor = try await self.cgmManager.lookUpBoundSensor() else {
                    guard !Task.isCancelled else { return }
                    self.onNoneBound()
                    return
                }
                guard !Task.isCancelled else { return }
                if let blocker = self.cgmManager.adoptionBlocker(for: sensor) {
                    self.phase = .unusable(sensor, reason: blocker.description)
                } else {
                    self.phase = .found(sensor)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func useSensor() {
        guard case let .found(sensor) = phase else { return }
        phase = .adopting(sensor)
        do {
            try cgmManager.adoptBoundSensor(sensor)
            onAdopted()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func pairNewSensor() {
        task?.cancel()
        onNoneBound()
    }
}
