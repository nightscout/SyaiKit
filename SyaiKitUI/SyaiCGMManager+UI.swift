//
//  SyaiCGMManager+UI.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import SwiftUI
import SyaiKit

extension SyaiCGMManager: @retroactive CGMManagerUI {
    public static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction _: Bool = false
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        let vc = SyaiUIController(
            colorPalette: colorPalette,
            displayGlucosePreference: displayGlucosePreference,
            allowDebugFeatures: allowDebugFeatures
        )
        return .userInteractionRequired(vc)
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> CGMManagerViewController {
        SyaiUIController(
            cgmManager: self,
            colorPalette: colorPalette,
            displayGlucosePreference: displayGlucosePreference,
            allowDebugFeatures: allowDebugFeatures
        )
    }

    public static var onboardingImage: UIImage? {
        UIImage(named: "sensor", in: Bundle(for: SyaiUIController.self), compatibleWith: nil)
    }

    public var smallImage: UIImage? {
        UIImage(named: "sensor", in: Bundle(for: SyaiUIController.self), compatibleWith: nil)
    }

    public var cgmStatusHighlight: DeviceStatusHighlight? {
        if needsOfficialAppClosed {
            return SyaiDeviceStatusHighlight(
                localizedMessage: String(
                    localized: "Close\nSyai App",
                    comment: "CGM status highlight: the official app still holds the sensor's connection"
                ),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        }
        switch sensorLifecycle {
        case .warmup:
            return SyaiDeviceStatusHighlight(
                localizedMessage: String(localized: "Sensor\nWarmup", comment: "CGM status highlight: sensor warming up"),
                imageName: "clock",
                state: .normalCGM
            )
        case .expired:
            return SyaiDeviceStatusHighlight(
                localizedMessage: String(localized: "Sensor\nExpired", comment: "CGM status highlight: sensor expired"),
                imageName: "clock",
                state: .normalCGM
            )
        case .signalLost:
            return SyaiDeviceStatusHighlight(
                localizedMessage: String(localized: "Signal\nLoss", comment: "CGM status highlight: signal loss"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        case .failed:
            return SyaiDeviceStatusHighlight(
                localizedMessage: String(
                    localized: "Replace\nSensor",
                    comment: "CGM status highlight: sensor failed, replace it"
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        case .unactivated:
            return SyaiDeviceStatusHighlight(
                localizedMessage: String(
                    localized: "Sensor\nNot Activated",
                    comment: "CGM status highlight: sensor reports itself not activated"
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        case .active,
             .noSensor:
            return nil
        }
    }

    public var cgmStatusBadge: DeviceStatusBadge? {
        switch sensorLifecycle {
        case let .active(remaining, _) where remaining < TimeInterval(2 * 3600):
            return SyaiDeviceStatusBadge(image: UIImage(systemName: "clock"), state: .critical)
        case .expired:
            return SyaiDeviceStatusBadge(image: UIImage(systemName: "exclamationmark.triangle.fill"), state: .critical)
        default:
            return nil
        }
    }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? {
        switch sensorLifecycle {
        case let .warmup(progress, _):
            return SyaiLifecycleProgress(percentComplete: progress, progressState: .warning)
        case let .active(remaining, total):
            guard remaining < TimeInterval(24 * 3600) else { return nil }
            let percent = 1 - (remaining / total)
            let state: DeviceLifecycleProgressState = remaining < TimeInterval(2 * 3600) ? .critical : .warning
            return SyaiLifecycleProgress(percentComplete: percent, progressState: state)
        case .expired:
            return SyaiLifecycleProgress(percentComplete: 1, progressState: .critical)
        default:
            return nil
        }
    }
}

private struct SyaiDeviceStatusBadge: DeviceStatusBadge {
    var image: UIImage? = UIImage(systemName: "exclamationmark.triangle")
    var state: DeviceStatusBadgeState = .critical
}

private struct SyaiLifecycleProgress: DeviceLifecycleProgress {
    fileprivate var percentComplete: Double
    fileprivate var progressState: DeviceLifecycleProgressState
}

private struct SyaiDeviceStatusHighlight: DeviceStatusHighlight {
    fileprivate var localizedMessage: String
    var imageName: String
    var state: DeviceStatusHighlightState
}
