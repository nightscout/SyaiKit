//
//  CGMManager+Session.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

actor SyaiSessionRecovery {
    private var inFlight: Task<SyaiBackend?, Never>?
    func run(_ work: @Sendable @escaping () async -> SyaiBackend?) async -> SyaiBackend? {
        if let inFlight { return await inFlight.value }
        let task = Task { await work() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}

extension SyaiCGMManager {
    public enum AccountError: Error, CustomStringConvertible {
        case notLoggedIn
        public var description: String {
            switch self {
            case .notLoggedIn: return "No Syai account is logged in."
            }
        }
    }

    public func login(email: String, password: String, keepLoggedIn: Bool = true) async throws {
        let provider = SyaiLoginCredentialProvider(email: email, password: password, template: .syaiTemplate)
        let backend = try await provider.backend()
        let session = SyaiAccountSession(
            email: email,
            backend: backend,
            password: keepLoggedIn ? password : nil
        )
        await MainActor.run { self.installSession(session) }
    }

    @MainActor private func installSession(_ session: SyaiAccountSession) {
        SyaiKeychain.saveAccount(session)
        account = session
        calibrationProvider = makeServerCalibrationProvider()
        telemetryService = makeTelemetryService()
        if state.accountLockedOutElsewhere {
            var updated = state
            updated.accountLockedOutElsewhere = false
            setState(updated)
        }
    }

    @discardableResult public func attemptSilentRelogin() async -> SyaiBackend? {
        guard let account, let password = account.password, !password.isEmpty else { return nil }
        let email = account.email
        return await sessionRecovery.run {
            do {
                let provider = SyaiLoginCredentialProvider(
                    email: email,
                    password: password,
                    template: .syaiTemplate
                )
                let backend = try await provider.backend()
                let session = SyaiAccountSession(email: email, backend: backend, password: password)
                await MainActor.run { self.installSession(session) }
                self.logger.info("silent re-login succeeded for \(SyaiRedact.email(email))")
                return backend
            } catch {
                self.logger.error("silent re-login failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    public func logOut() {
        SyaiKeychain.deleteAccount()
        account = nil
        if calibrationProvider is SyaiServerCalibrationProvider {
            calibrationProvider = nil
        }
        telemetryService = nil
    }

    public func configureForAccount(sensorKit: SyaiBLE) throws {
        guard let provider = makeServerCalibrationProvider() else { throw AccountError.notLoggedIn }
        configure(sensorKit: sensorKit, calibrationProvider: provider)
        telemetryService = makeTelemetryService()
    }

    func makeSessionRotationHandler() -> @Sendable(SyaiCredentials, String?) -> Void {
        { [weak self] rotated, gsk in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let current = self.account else { return }
                let updated = current.withRotatedCredentials(rotated, glucoseSecretKey: gsk)
                guard updated != current else { return }
                SyaiKeychain.saveAccount(updated)
                self.account = updated
            }
        }
    }

    func makeAccountLockoutHandler() -> @Sendable(Bool) -> Void {
        { [weak self] lockedOut in
            Task { @MainActor in
                guard let self, self.state.accountLockedOutElsewhere != lockedOut else { return }
                var updated = self.state
                updated.accountLockedOutElsewhere = lockedOut
                self.setState(updated)
            }
        }
    }

    func makeSessionRecoveryHandler() -> @Sendable() async -> SyaiBackend? {
        { [weak self] in
            guard let self else { return nil }
            return await self.attemptSilentRelogin()
        }
    }

    private func makeServerCalibrationProvider() -> SyaiServerCalibrationProvider? {
        guard let account else { return nil }
        return SyaiServerCalibrationProvider(
            backend: account.backend(),
            onSessionRotated: makeSessionRotationHandler(),
            recoverSession: makeSessionRecoveryHandler(),
            onAccountLockoutChanged: makeAccountLockoutHandler()
        )
    }

    func makeServerDeviceBinder() -> SyaiServerDeviceBinder? {
        guard let account else { return nil }
        return SyaiServerDeviceBinder(
            backend: account.backend(),
            onSessionRotated: makeSessionRotationHandler(),
            recoverSession: makeSessionRecoveryHandler(),
            onAccountLockoutChanged: makeAccountLockoutHandler()
        )
    }

    private func makeTelemetryService() -> SyaiTelemetryService? {
        guard let account else { return nil }
        return SyaiTelemetryService(
            client: SyaiEnvelopedClient(backend: account.backend()),
            restoredQueue: state.telemetryQueue,
            tier: { [weak self] in self?.state.telemetryTier ?? .minimal },
            persistQueue: { [weak self] records in
                Task { @MainActor in
                    guard let self else { return }
                    var updated = self.state
                    updated.telemetryQueue = records
                    self.setState(updated)
                }
            },
            sensorContext: { [weak self] in
                guard let self, let record = self.state.sensors.current(),
                      let activatedAt = record.activatedAt else { return nil }
                return SyaiTelemetryService.SensorContext(
                    serverDeviceId: record.serverDeviceId,
                    embeddedSoftVersion: record.deviceInfo.deviceVersion,
                    activatedAtMs: Int64(activatedAt.timeIntervalSince1970 * 1000),
                    mac: record.mac
                )
            },

            accountContext: { [weak self] in
                guard let self, let account = self.account else { return nil }
                let backend = account.backend()
                guard let userId = account.userId ?? backend.userId else { return nil }
                return SyaiTelemetryService.AccountContext(userId: userId, appName: backend.appName)
            },
            onSessionRotated: makeSessionRotationHandler(),
            persistServerDeviceId: { [weak self] id in
                Task { @MainActor in
                    guard let self else { return }
                    var updated = self.state
                    updated.sensors.setServerDeviceId(id)
                    self.setState(updated)
                }
            },
            onAccountLockoutChanged: makeAccountLockoutHandler()
        )
    }
}
