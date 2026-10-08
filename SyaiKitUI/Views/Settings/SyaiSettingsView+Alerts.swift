//
//  SyaiSettingsView+Alerts.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI

extension SyaiSettingsView {
    var removeCGMAlert: Alert {
        Alert(
            title: Text("Remove CGM", comment: "delete title"),
            message: Text(
                "Are you sure you want to stop using the Syai Ultra? Your Syai account stays signed in, and sensor history is kept.",
                comment: "delete message"
            ),
            primaryButton: .destructive(Text("Confirm", comment: "confirm")) { viewModel.deleteCGM() },
            secondaryButton: .cancel()
        )
    }

    var endSensorAlert: Alert {
        Alert(
            title: Text("End Sensor", comment: "end sensor title"),
            message: Text(
                "This shuts the sensor down and releases it from your Syai account. You cannot reverse this action or reuse the sensor. Remove it from your arm afterwards.",
                comment: "end sensor message"
            ),
            primaryButton: .destructive(Text("Confirm", comment: "confirm")) { viewModel.endSensor() },
            secondaryButton: .cancel()
        )
    }

    var forceEndSensorAlert: Alert {
        Alert(
            title: Text("Could Not Confirm Shutdown", comment: "force end sensor title"),
            message: Text(
                "Trio could not reach the sensor to confirm it powered down. It may still be transmitting nearby, or it may already be off the air for good. Ending the session now releases it from your account without that confirmation.",
                comment: "force end sensor message"
            ),
            primaryButton: .destructive(Text("End Anyway", comment: "force end confirm")) { viewModel.endSensor(force: true) },
            secondaryButton: .cancel()
        )
    }
}
