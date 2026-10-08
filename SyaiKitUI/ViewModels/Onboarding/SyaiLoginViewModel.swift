//
//  SyaiLoginViewModel.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Combine
import SwiftUI
import SyaiKit

@MainActor final class SyaiLoginViewModel: ObservableObject {
    @Published var email: String
    @Published var password: String = ""
    @Published var keepLoggedIn: Bool = true
    @Published var isBusy = false
    @Published var errorMessage: String?

    private let cgmManager: SyaiCGMManager
    private let onLoggedIn: () -> Void
    private let logger = SyaiLogger(category: "LoginViewModel")
    private var task: Task<Void, Never>?

    init(cgmManager: SyaiCGMManager, allowDebugFeatures _: Bool = false, onLoggedIn: @escaping () -> Void) {
        self.cgmManager = cgmManager
        self.onLoggedIn = onLoggedIn
        email = cgmManager.account?.email ?? ""
    }

    var canSubmit: Bool {
        #if targetEnvironment(simulator)
            // Simulator builds may submit with empty fields to skip login entirely.
            return !isBusy
        #else
            return !isBusy && email.contains("@") && !password.isEmpty
        #endif
    }

    func submit() {
        guard canSubmit else { return }
        errorMessage = nil
        #if targetEnvironment(simulator)
            // Empty fields on the simulator = skip login and proceed with no
            // session; anything else is a fake login (see CGMManager+Simulation).
            if email.isEmpty, password.isEmpty {
                logger.info("simulator skip-login")
            } else {
                cgmManager.startSimulatedAccount()
            }
            onLoggedIn()
        #else
            logIn()
        #endif
    }

    private func logIn() {
        isBusy = true
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let password = self.password
            do {
                try await self.cgmManager.login(
                    email: email,
                    password: password,
                    keepLoggedIn: self.keepLoggedIn
                )
                self.isBusy = false
                self.password = "" // don't keep the password in memory past use
                self.onLoggedIn()
            } catch {
                self.isBusy = false
                self.logger.error("login failed: \(error)")

                // The login flow either throws LoginError or a transport error
                self.errorMessage = (error as? SyaiEnvelopedClient.LoginError)?.description
                    ?? String(
                        localized: "please check your connection and try again.",
                        comment: "login error: unexpected failure"
                    )
            }
        }
    }
}
