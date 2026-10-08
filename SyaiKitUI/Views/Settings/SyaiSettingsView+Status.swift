//
//  SyaiSettingsView+Status.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import SyaiKit

extension SyaiSettingsView {
    @ViewBuilder var statusSection: some View {
        Section {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Image(imageName: "sensor")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 150)
                    Spacer()
                }
                sensorLifecycleRow.padding(.bottom, 8)
            }

            sensorStatusRow

            if viewModel.needsOfficialAppClosed {
                officialAppConnectedRow
            }

            if viewModel.showingEndSensorButton {
                endSensorRow
            }

            if viewModel.accountLockedOutElsewhere {
                accountLockedOutRow
            }
        }
    }

    @ViewBuilder private var sensorLifecycleRow: some View {
        switch viewModel.cgmState {
        case .noSensor:
            HStack {
                Text("No sensor paired.", comment: "no sensor").foregroundColor(.secondary)
                Spacer()
            }
        case .connecting:
            HStack {
                SwiftUI.ProgressView()
                Text("Connecting to sensor…", comment: "connecting")
                    .foregroundColor(.secondary)
                    .padding(.leading, 6)
                Spacer()
            }
        case .warmingUp:
            HStack(alignment: .lastTextBaseline) {
                Text("Warming up:", comment: "warming up").foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f", viewModel.sensorWarmupMinutes))
                    .font(.system(size: 28)).fontWeight(.heavy)
                Text("min remaining", comment: "min remaining").foregroundColor(.secondary)
            }
            SwiftUI.ProgressView(value: viewModel.sensorWarmupProgress)
                .scaleEffect(x: 1, y: 4, anchor: .center).padding(.top, 7)
        case .active:
            HStack(alignment: .lastTextBaseline) {
                Text("Sensor expires in:", comment: "expires in").foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f", viewModel.sensorAgeDays))
                    .font(.system(size: 28)).fontWeight(.heavy)
                Text("days", comment: "days").foregroundColor(.secondary)
                Text(String(format: "%.0f", viewModel.sensorAgeHours))
                    .font(.system(size: 28)).fontWeight(.heavy)
                Text("hrs", comment: "hours").foregroundColor(.secondary)
            }
            SwiftUI.ProgressView(value: viewModel.sensorAgeProgress)
                .scaleEffect(x: 1, y: 4, anchor: .center).padding(.top, 7)
        case .expired:
            HStack {
                Text("Sensor expired!", comment: "expired").foregroundColor(guidanceColors.critical)
                Spacer()
            }
            SwiftUI.ProgressView(value: 1)
                .scaleEffect(x: 1, y: 4, anchor: .center).padding(.top, 7)
                .tint(guidanceColors.critical)
        }
    }

    @ViewBuilder private var sensorStatusRow: some View {
        let status = viewModel.sensorStatus
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.iconName)
                .foregroundStyle(status.iconColor(guidanceColors))
            VStack(alignment: .leading, spacing: 2) {
                status.title.fontWeight(.heavy).foregroundStyle(.primary)
                status.message.foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Exceptional cases

    @ViewBuilder private var endSensorRow: some View {
        Button(action: { viewModel.activeAlert = .endSensorConfirm }) {
            HStack {
                Spacer()
                if viewModel.isEndingSensor {
                    SwiftUI.ProgressView()
                    Text(verbatim: viewModel.endSensorStatusText)
                        .foregroundColor(.secondary)
                } else {
                    Text("End Sensor", comment: "end sensor")
                        .foregroundColor(guidanceColors.critical)
                }
                Spacer()
            }
            // .fontWeight(_:) on a View is iOS 16+; this target is 15.1.
            .font(.body.weight(.semibold))
            .contentShape(Rectangle())
        }
        .disabled(viewModel.isEndingSensor)
    }

    @ViewBuilder private var officialAppConnectedRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(guidanceColors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Close the Syai App", comment: "official app connected title")
                    .fontWeight(.heavy).foregroundStyle(.primary)
                Text(
                    "\(Bundle.main.syaiHostAppName) can't reach this sensor yet. It can only talk to one app at a time, so force-quit the official Syai app (swipe it away in the app switcher) to let \(Bundle.main.syaiHostAppName) connect.",
                    comment: "official app connected message (1: appName)"
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private var accountLockedOutRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(guidanceColors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Account Logged Out", comment: "account locked out title")
                    .fontWeight(.heavy).foregroundStyle(.primary)
                Text(
                    "Your Syai account has been forcibly logged out. Telemetry and glucose uploads are paused. Please ensure that you are not signed in elsewhere (e.g. the official Syai app)",
                    comment: "account locked out message"
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        Button(action: { viewModel.showLogin() }) {
            HStack {
                Spacer()
                Text("Sign In", comment: "account locked out sign in")
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
    }
}
