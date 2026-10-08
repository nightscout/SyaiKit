//
//  CGMManager+Alerts.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

extension SyaiCGMManager {
    @MainActor func evaluateAlerts() {
        let shouldFire = SyaiAlertCondition.currentlyFiring(for: sensorLifecycle)
        guard shouldFire != firingAlertConditions else { return }
        let issuing = shouldFire.subtracting(firingAlertConditions)
        let retracting = firingAlertConditions.subtracting(shouldFire)
        firingAlertConditions = shouldFire
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            for condition in issuing {
                self.cgmManagerDelegate?.issueAlert(condition.alert(managerIdentifier: Self.pluginIdentifier))
            }
            for condition in retracting {
                self.cgmManagerDelegate?.retractAlert(identifier: condition.identifier(managerIdentifier: Self.pluginIdentifier))
            }
        }
    }
}
