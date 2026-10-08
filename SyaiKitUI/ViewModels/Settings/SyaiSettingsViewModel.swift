//
//  SyaiSettingsViewModel.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Combine
import SwiftUI
import SyaiKit

/// One `Identifiable` alert state for the whole screen: stacking several
/// `.actionSheet`/`.alert` modifiers on one view means only the first ever
/// presents, and `ActionSheet` renders as a broken popover here since this
/// screen is hosted inside Trio's `.sheet`-presented CGM flow.
enum SyaiSettingsAlert: Identifiable {
    case deleteConfirm
    case endSensorConfirm
    case endSensorForceConfirm
    case endSensorError
    var id: Self { self }
}

@MainActor final class SyaiSettingsViewModel: ObservableObject, SyaiStateObserver {
    @Published var cgmState: SyaiCGMState = .warmingUp
    @Published var connected = false
    @Published var mac = ""
    var sensorModel: String { "X1" }
    @Published var recentSamples: [GlucoseSample] = []
    @Published var sensorStartedAt = ""
    @Published var sensorEndsAt = ""
    @Published var sensorWarmupProgress: Double = 0
    @Published var sensorWarmupMinutes: Double = 0
    @Published var sensorAgeProgress: Double = 0
    @Published var sensorAgeDays: Double = 0
    @Published var sensorAgeHours: Double = 0

    @Published var isSharePresented = false
    @Published var activeAlert: SyaiSettingsAlert?

    @Published var showingEndSensorButton = false
    @Published var isEndingSensor = false
    @Published var endSensorStatusText = ""
    @Published var endSensorError: String?

    @Published var accountEmail = ""
    @Published var accountLoggedIn = false
    @Published var accountLockedOutElsewhere = false
    @Published var needsOfficialAppClosed = false

    private let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private let logger = SyaiLogger(category: "SettingsViewModel")
    private let cgmManager: SyaiCGMManager
    let deleteCGM: () -> Void
    let showSensorHistory: () -> Void
    let showAccount: () -> Void
    let showLogin: () -> Void
    let showSampleDetail: (GlucoseSample) -> Void
    let showAllReadings: () -> Void
    let pairNewSensor: () -> Void

    init(
        _ cgmManager: SyaiCGMManager,
        deleteCGM: @escaping () -> Void,
        showSensorHistory: @escaping () -> Void,
        showAccount: @escaping () -> Void,
        showLogin: @escaping () -> Void,
        showSampleDetail: @escaping (GlucoseSample) -> Void,
        showAllReadings: @escaping () -> Void,
        pairNewSensor: @escaping () -> Void
    ) {
        self.cgmManager = cgmManager
        self.deleteCGM = deleteCGM
        self.showSensorHistory = showSensorHistory
        self.showAccount = showAccount
        self.showLogin = showLogin
        self.showSampleDetail = showSampleDetail
        self.showAllReadings = showAllReadings
        self.pairNewSensor = pairNewSensor
        refresh(state: cgmManager.state)
        cgmManager.addStateObserver(self)
    }

    var sensorStatus: SyaiSensorStatusDisplay {
        guard cgmManager.sensorLifecycle != .noSensor else { return .noSensor }
        if !connected { return .connecting }
        switch cgmManager.sensorLifecycle {
        case .expired: return .expired
        case .warmup: return .warmingUp
        case .signalLost:
            // Right after a (re)connect the newest reading is almost always
            // >6 min stale: that's the backfill catch-up window, not signal
            // loss. Keep showing "Connecting" while the link is young; only
            // raise Signal Lost once a sustained link still brings nothing.
            if let connectedAt = cgmManager.connectedAt,
               Date().timeIntervalSince(connectedAt) < Self.signalLostGracePeriod
            {
                return .connecting
            }
            return .signalLost
        case .failed: return .malfunction
        case .unactivated: return .notActivated
        case .noSensor: return .noSensor
        case .active: return .ok
        }
    }

    var hasSensor: Bool { cgmManager.sensorLifecycle != .noSensor }

    private static let signalLostGracePeriod: TimeInterval = 3 * 60

    func endSensor(force: Bool = false) {
        guard !isEndingSensor else { return }
        isEndingSensor = true
        endSensorError = nil
        endSensorStatusText = Self.text(for: .confirmingShutdown)
        Task { @MainActor in
            do {
                try await cgmManager.endSensor(force: force, onStage: { [weak self] stage in
                    Task { @MainActor in self?.endSensorStatusText = Self.text(for: stage) }
                })
                isEndingSensor = false
            } catch SyaiCGMManager.EndSensorError.shutdownNotConfirmed {
                isEndingSensor = false
                activeAlert = .endSensorForceConfirm
            } catch {
                logger.error("end sensor failed: \(error.localizedDescription)")
                endSensorError = error.localizedDescription
                activeAlert = .endSensorError
                isEndingSensor = false
            }
        }
    }

    private static func text(for stage: SyaiCGMManager.EndSensorStage) -> String {
        switch stage {
        case .confirmingShutdown:
            return String(localized: "Confirming sensor shutdown…", comment: "end sensor stage: confirming shutdown")
        case .releasingAccount:
            return String(localized: "Releasing from your account…", comment: "end sensor stage: releasing account")
        }
    }

    func getLogs() -> [URL] {
        logger.info(cgmManager.state.debugDescription)
        return logger.getDebugLogs()
    }

    nonisolated func syaiCGMManager(_: SyaiCGMManager, didUpdate state: CGMManagerState, latestSample _: GlucoseSample?) {
        Task { @MainActor in self.refresh(state: state) }
    }

    private func refresh(state: CGMManagerState) {
        connected = cgmManager.connectionStatus == .connected
        mac = state.mac ?? ""
        accountEmail = cgmManager.account?.email ?? ""
        accountLoggedIn = cgmManager.account != nil
        accountLockedOutElsewhere = state.accountLockedOutElsewhere
        recentSamples = cgmManager.recentSamples
        showingEndSensorButton = cgmManager.canEndSensor
        needsOfficialAppClosed = cgmManager.needsOfficialAppClosed

        guard let activatedAt = state.activatedAt,
              let duration = state.activeDuration,
              let preheatDuration = state.preheatDuration,
              let age = cgmManager.sensorAge
        else {
            cgmState = .noSensor
            return
        }

        // Every decision below is made from `age`, which comes from the
        // sensor's own clock. The two formatted dates are the anchor and the
        // anchor plus the wear window — display only, and self-consistent.
        sensorStartedAt = dateTimeFormatter.string(from: activatedAt)
        sensorEndsAt = dateTimeFormatter.string(from: activatedAt.addingTimeInterval(duration))

        if age >= duration {
            cgmState = .expired
        } else if age < preheatDuration {
            cgmState = .warmingUp
            sensorWarmupProgress = min(age / preheatDuration, 1)
            sensorWarmupMinutes = max((preheatDuration - age) / 60, 0)
        } else {
            cgmState = .active
            sensorAgeProgress = min(age / duration, 1)
            let remaining = duration - age
            sensorAgeDays = max(floor(remaining / 86400), 0)
            sensorAgeHours = max(remaining.truncatingRemainder(dividingBy: 86400) / 3600, 0)
        }
    }
}
