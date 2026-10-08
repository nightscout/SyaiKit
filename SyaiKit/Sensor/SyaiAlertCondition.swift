//
//  SyaiAlertCondition.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import LoopKit

public enum SyaiAlertCondition: String, CaseIterable, Sendable {
    case signalLost
    case expired
    case failed
    case unactivated

    public static func currentlyFiring(for lifecycle: SyaiSensorLifecycle) -> Set<SyaiAlertCondition> {
        switch lifecycle {
        case .signalLost: return [.signalLost]
        case .expired: return [.expired]
        case .failed: return [.failed]
        case .unactivated: return [.unactivated]
        case .active,
             .noSensor,
             .warmup: return []
        }
    }

    public func identifier(managerIdentifier: String) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: "syai.\(rawValue)")
    }

    public func alert(managerIdentifier: String) -> Alert {
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledge button")
        )
        return Alert(
            identifier: identifier(managerIdentifier: managerIdentifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: interruptionLevel
        )
    }

    private var title: String {
        switch self {
        case .signalLost: return LocalizedString("Signal Loss", comment: "Alert title: signal loss")
        case .expired: return LocalizedString("Sensor Expired", comment: "Alert title: sensor expired")
        case .failed: return LocalizedString("Sensor Malfunction", comment: "Alert title: sensor malfunction")
        case .unactivated: return LocalizedString(
                "Sensor Not Activated",
                comment: "Alert title: sensor reports itself not activated"
            )
        }
    }

    private var body: String {
        switch self {
        case .signalLost:
            return LocalizedString(
                "Signal lost. Check that your sensor is nearby and Bluetooth is on.",
                comment: "Alert body: signal loss"
            )
        case .expired:
            return LocalizedString(
                "Sensor expired. Replace your sensor now.",
                comment: "Alert body: sensor expired"
            )
        case .failed:
            return LocalizedString(
                "Sensor malfunction. Replace your sensor now.",
                comment: "Alert body: sensor malfunction"
            )
        case .unactivated:
            return LocalizedString(
                "Sensor reports as not activated. If this continues, remove and re-pair it.",
                comment: "Alert body: sensor reports itself not activated"
            )
        }
    }

    private var interruptionLevel: Alert.InterruptionLevel {
        switch self {
        case .failed,
             .unactivated: return .critical
        case .expired,
             .signalLost: return .timeSensitive
        }
    }
}
