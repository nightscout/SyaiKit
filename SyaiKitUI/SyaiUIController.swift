//
//  SyaiUIController.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKit
import LoopKitUI
import SwiftUI
import SyaiKit

private enum SyaiScreen {
    case onboarding
    case placementGuide
    case login
    /// One-time data-sharing choice, shown before pairing (and before anything can be sent).
    /// `onContinue` runs after the user picks a tier; the choice itself is persisted separately.
    case telemetryDisclosure(onContinue: () -> Void)
    /// Offers a sensor already bound to the account before pairing a new one.
    case existingSensor
    case pairing
    case settings
    case account
    case sensorHistory
    case sensorDetail(DeviceInfo)
    case sampleDetail(GlucoseSample)
    case recentReadings
}

final class SyaiUIController: UINavigationController, CGMManagerOnboarding, CompletionNotifying, UINavigationControllerDelegate {
    var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?

    private var cgmManager: SyaiCGMManager
    private let displayGlucosePreference: DisplayGlucosePreference
    private let colorPalette: LoopUIColorPalette
    private let allowDebugFeatures: Bool
    /// True only for the first-time "Add CGM" flow (`setupViewController`,
    /// no existing manager passed in). `settingsViewController` always passes
    /// an existing manager and must land on `.settings` regardless of
    /// whether a sensor happens to be paired right now - a manager Trio
    /// already lists is never re-onboarded, even right after "End Sensor"
    /// clears its MAC.
    private let isInitialSetup: Bool
    private var screenStack = [SyaiScreen]()

    init(
        cgmManager: SyaiCGMManager? = nil,
        colorPalette: LoopUIColorPalette,
        displayGlucosePreference: DisplayGlucosePreference,
        allowDebugFeatures: Bool
    ) {
        isInitialSetup = cgmManager == nil
        self.cgmManager = cgmManager ?? SyaiCGMManager()
        self.colorPalette = colorPalette
        self.displayGlucosePreference = displayGlucosePreference
        self.allowDebugFeatures = allowDebugFeatures
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        navigationBar.prefersLargeTitles = true
        if screenStack.isEmpty {
            // A brand-new "Add CGM" manager that resumed a still-alive sensor
            // from the file-backed history mirror (e.g. re-adding after a
            // swap) already has something to manage - skip the "Welcome"
            // onboarding screen, same as an existing manager would.
            let needsOnboarding = isInitialSetup && cgmManager.state.mac == nil
            if isInitialSetup, !needsOnboarding {
                cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: cgmManager)
                cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: cgmManager)
            }
            var screens: [SyaiScreen] = [needsOnboarding ? .onboarding : .settings]
            // A returning user (paired sensor, account restored) whose flag predates
            // telemetry gets the one-time consent choice on top of settings; picking
            // either option pops back to settings.
            if cgmManager.state.mac != nil, !cgmManager.state.telemetryDisclosureShown {
                screens.append(.telemetryDisclosure(onContinue: { [weak self] in
                    self?.popScreen()
                }))
            }
            screenStack = screens
            setViewControllers(screens.map { viewControllerForScreen($0) }, animated: false)
        }
    }

    private func hostingController(
        rootView: some View,
        title: String? = nil,
        largeTitleDisplayMode: UINavigationItem.LargeTitleDisplayMode = .automatic
    ) -> DismissibleHostingController<some View> {
        let host = DismissibleHostingController(
            content: rootView.environmentObject(displayGlucosePreference),
            colorPalette: colorPalette
        )
        host.navigationItem.title = title
        host.navigationItem.largeTitleDisplayMode = largeTitleDisplayMode
        return host
    }

    private func viewControllerForScreen(_ screen: SyaiScreen) -> UIViewController {
        switch screen {
        case .onboarding:
            let view = SyaiOnboardingView(
                onContinue: { [weak self] in self?.proceedToPairingOrLogin() },
                onShowPlacement: { [weak self] in self?.navigateTo(.placementGuide) }
            )
            return hostingController(rootView: view, title: String(localized: "Welcome!", comment: "welcome"))

        case .placementGuide:
            return hostingController(
                rootView: SyaiSensorPlacementView(onDone: { [weak self] in self?.popScreen() }),
                title: String(localized: "Placement Guide", comment: "placement guide")
            )

        case .login:
            let viewModel = SyaiLoginViewModel(
                cgmManager: cgmManager,
                allowDebugFeatures: allowDebugFeatures,
                onLoggedIn: { [weak self] in
                    guard let self else { return }
                    self.configureRealSensorKitIfNeeded()
                    if self.cgmManager.state.mac != nil {
                        // Reached from Settings' "Login" row with a sensor
                        // already paired (e.g. after an explicit Log Out):
                        // just return to Settings, there's nothing to pair.
                        self.popScreen()
                    } else {
                        self.navigateToPairingWithDisclosure()
                    }
                }
            )
            return hostingController(
                rootView: SyaiLoginView(viewModel: viewModel),
                title: String(localized: "Sign in", comment: "login title")
            )

        case let .telemetryDisclosure(onContinue):
            let view = SyaiTelemetryConsentView(onChoice: { [weak self] tier in
                Task { @MainActor in
                    guard let self else { return }
                    self.cgmManager.setTelemetryTier(tier)
                    self.cgmManager.markTelemetryDisclosureShown()
                    onContinue()
                }
            })
            return hostingController(
                rootView: view,
                title: String(localized: "Data Sharing", comment: "telemetry disclosure title")
            )

        case .existingSensor:
            let viewModel = SyaiExistingSensorViewModel(
                cgmManager: cgmManager,
                onNoneBound: { [weak self] in self?.replaceTopScreen(with: .pairing) },
                onAdopted: { [weak self] in self?.finishOnboarding() }
            )
            return hostingController(
                rootView: SyaiExistingSensorView(viewModel: viewModel),
                title: String(localized: "Your Sensor", comment: "existing sensor title")
            )

        case .pairing:
            let viewModel = SyaiPairingViewModel(
                cgmManager: cgmManager,
                onCreated: { [weak self] in self?.finishOnboarding() }
            )
            return hostingController(
                rootView: SyaiPairingView(viewModel: viewModel),
                title: String(localized: "Pairing with sensor", comment: "pairing title")
            )

        case .settings:
            let viewModel = SyaiSettingsViewModel(
                cgmManager,
                deleteCGM: { [weak self] in
                    guard let self else { return }
                    // Leaves the account session alone - only an explicit Log Out
                    // clears it - so re-adding a CGM under the same account needs
                    // no fresh sign-in. Uses delete(), not notifyDelegateOfDeletion:
                    // the latter only fires cgmManagerWantsDeletion, and Trio's
                    // deleteGlucoseSource just drops the manager without tearing
                    // down the BLE link. delete() does both the teardown and the
                    // notification.
                    self.cgmManager.delete {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.completionDelegate?.completionNotifyingDidComplete(self)
                        }
                    }
                },
                showSensorHistory: { [weak self] in self?.navigateTo(.sensorHistory) },
                showAccount: { [weak self] in self?.navigateTo(.account) },
                showLogin: { [weak self] in self?.navigateTo(.login) },
                showSampleDetail: { [weak self] sample in self?.navigateTo(.sampleDetail(sample)) },
                showAllReadings: { [weak self] in self?.navigateTo(.recentReadings) },
                pairNewSensor: { [weak self] in self?.proceedToPairingOrLogin() }
            )
            return hostingController(
                rootView: SyaiSettingsView(viewModel: viewModel),
                title: String(localized: "Syai Ultra", comment: "settings screen title"),
                largeTitleDisplayMode: .never
            )

        case .account:
            let account = cgmManager.account
            let view = SyaiAccountView(
                email: account?.email ?? "",
                sessionValid: account?.hasValidSession ?? false,
                refreshExpiry: account?.refreshTokenExpiry,
                accountLockedOutElsewhere: cgmManager.state.accountLockedOutElsewhere,
                telemetryTier: cgmManager.telemetryTier,
                onSetTelemetryTier: { [weak self] tier in
                    Task { @MainActor in self?.cgmManager.setTelemetryTier(tier) }
                },
                onLogOut: { [weak self] in
                    guard let self else { return }
                    self.cgmManager.logOut()
                    self.popScreen()
                },
                onLoginAgain: { [weak self] in self?.navigateTo(.login) }
            )
            return hostingController(
                rootView: view,
                title: String(localized: "Account", comment: "account title")
            )

        case .sensorHistory:
            let view = SyaiSensorHistoryView(
                records: cgmManager.state.sensors.history(),
                activeMAC: cgmManager.state.sensors.activeMAC,
                onSelect: { [weak self] deviceInfo in self?.navigateTo(.sensorDetail(deviceInfo)) }
            )
            return hostingController(
                rootView: view,
                title: String(localized: "Sensor History", comment: "sensor history title")
            )

        case let .sensorDetail(deviceInfo):
            let view = SyaiFactoryCalibrationsView(activeSensor: deviceInfo)
            return hostingController(
                rootView: view,
                title: deviceInfo.productName
            )

        case let .sampleDetail(sample):
            return hostingController(rootView: SyaiSampleDetailView(sample: sample))

        case .recentReadings:
            let view = SyaiRecentReadingsView(
                samples: cgmManager.recentSamples,
                onSelect: { [weak self] sample in self?.navigateTo(.sampleDetail(sample)) }
            )
            return hostingController(
                rootView: view,
                title: String(localized: "Recent Readings", comment: "recent readings screen title")
            )
        }
    }

    private func navigateTo(_ screen: SyaiScreen) {
        screenStack.append(screen)
        pushViewController(viewControllerForScreen(screen), animated: true)
    }

    /// Swaps the top screen so Back skips the one being replaced.
    private func replaceTopScreen(with screen: SyaiScreen) {
        if !screenStack.isEmpty { screenStack.removeLast() }
        screenStack.append(screen)
        var controllers = viewControllers
        if !controllers.isEmpty { controllers.removeLast() }
        controllers.append(viewControllerForScreen(screen))
        setViewControllers(controllers, animated: true)
    }

    private func finishOnboarding() {
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: cgmManager)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: cgmManager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func popScreen() {
        if !screenStack.isEmpty { screenStack.removeLast() }
        popViewController(animated: true)
    }

    /// Requires a live account session before pairing, routing to `.login` when
    /// absent. An expired/evicted session with a stored password ("keep me logged
    /// in") gets one silent re-login attempt first; only on failure does the user
    /// see the login screen.
    private func proceedToPairingOrLogin() {
        if cgmManager.account?.hasValidSession == true {
            configureRealSensorKitIfNeeded()
            navigateToPairingWithDisclosure()
        } else if cgmManager.account?.password != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.cgmManager.attemptSilentRelogin() != nil {
                    self.configureRealSensorKitIfNeeded()
                    self.navigateToPairingWithDisclosure()
                } else {
                    self.navigateTo(.login)
                }
            }
        } else {
            navigateTo(.login)
        }
    }

    /// Pairing (and with it the first live upload) routes through the one-time
    /// telemetry disclosure until it's been acknowledged.
    private func navigateToPairingWithDisclosure() {
        if cgmManager.state.telemetryDisclosureShown {
            navigateTo(.existingSensor)
        } else {
            navigateTo(.telemetryDisclosure(onContinue: { [weak self] in
                self?.navigateTo(.existingSensor)
            }))
        }
    }

    /// Wire real BLE kit unconditionally; the simulator has no BLE hardware,
    /// so discovery simply never resolves there.
    private func configureRealSensorKitIfNeeded() {
        do {
            try cgmManager.configureForAccount(sensorKit: SyaiBLE())
        } catch {
            // Not logged in yet; the login screen routes back through here.
        }
    }
}
