//
//  SyaiAccountView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import SyaiKit

/// Account-management screen. Shows the logged-in account, refresh-token
/// expiry, Data Sharing toggle, and a Log Out action. Logging out only clears
/// the Syai account session - it never touches the paired sensor or its
/// history, so a sensor already streaming keeps streaming.
struct SyaiAccountView: View {
    @Environment(\.guidanceColors) private var guidanceColors

    let email: String
    let sessionValid: Bool
    let refreshExpiry: Date?
    let accountLockedOutElsewhere: Bool
    /// Data sharing lives here (not in the main settings): it is account-bound,
    /// so it only makes sense while logged in, and the Account screen is only
    /// reachable when logged in. Seeded from `SyaiCGMManager.telemetryTier`.
    let telemetryTier: SyaiTelemetryTier
    let onSetTelemetryTier: (SyaiTelemetryTier) -> Void
    let onLogOut: () -> Void
    let onLoginAgain: () -> Void

    @State private var tier: SyaiTelemetryTier
    @State private var showingLogOutConfirmation = false

    init(
        email: String,
        sessionValid: Bool,
        refreshExpiry: Date?,
        accountLockedOutElsewhere: Bool = false,
        telemetryTier: SyaiTelemetryTier,
        onSetTelemetryTier: @escaping (SyaiTelemetryTier) -> Void,
        onLogOut: @escaping () -> Void,
        onLoginAgain: @escaping () -> Void = {}
    ) {
        self.email = email
        self.sessionValid = sessionValid
        self.refreshExpiry = refreshExpiry
        self.accountLockedOutElsewhere = accountLockedOutElsewhere
        self.telemetryTier = telemetryTier
        self.onSetTelemetryTier = onSetTelemetryTier
        self.onLogOut = onLogOut
        self.onLoginAgain = onLoginAgain
        _tier = State(initialValue: telemetryTier)
    }

    // `Alert`, not `ActionSheet`: ActionSheet renders as a broken popover
    // here since this screen is hosted inside Trio's `.sheet`-presented CGM flow.
    private var logOutAlert: Alert {
        Alert(
            title: Text("Log Out", comment: "log out title"),
            message: Text(
                "You'll need to sign in again to pair a new sensor or resume data sharing. Your current sensor keeps working.",
                comment: "log out message"
            ),
            primaryButton: .destructive(Text("Log Out", comment: "log out confirm")) { onLogOut() },
            secondaryButton: .cancel()
        )
    }

    var body: some View {
        List {
            Section {
                labelValueRow(Text("Email", comment: "account email"), Text(verbatim: email))
                // Show the concrete refresh-token expiry (the ~265-day window)
                // rather than a bare "Active", since the date is the useful fact.
                // Fall back to a status word only when no expiry is known.
                if sessionValid, let expiry = refreshExpiry {
                    labelValueRow(
                        Text("Signed in until", comment: "session expiry label"),
                        Text(verbatim: Self.dateFmt.string(from: expiry))
                    )
                } else {
                    labelValueRow(
                        Text("Session", comment: "session status"),
                        sessionValid
                            ? Text("Active", comment: "session active")
                            : Text("Expired", comment: "session expired")
                    )
                }
                if accountLockedOutElsewhere {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(guidanceColors.warning)
                        Text(
                            "Logged in elsewhere. Telemetry is paused until you sign in again.",
                            comment: "account locked out elsewhere message"
                        )
                        .foregroundStyle(.secondary)
                    }
                    Button(action: onLoginAgain) {
                        Text("Sign In Again", comment: "sign in again to clear the account lockout")
                    }
                }
            }

            Section {
                ForEach(SyaiTelemetryTier.allCases, id: \.self) { option in
                    Button(action: {
                        tier = option
                        onSetTelemetryTier(option)
                    }) {
                        SyaiTelemetryTierRow(tier: option, selected: option == tier)
                    }
                }
            } header: {
                Text("Data Sharing", comment: "data sharing section")
            } footer: {
                Text(
                    "Your sensor is registered to your Syai account and released again when you end it whichever option you pick, because that is how a sensor is paired at all. An account with no readings may look unusual to Syai if you ever need warranty or support.",
                    comment: "data sharing footer"
                )
            }

            Section {
                Button(action: { showingLogOutConfirmation = true }) {
                    Text("Log Out", comment: "log out")
                        .foregroundColor(guidanceColors.critical)
                }
                .alert(isPresented: $showingLogOutConfirmation) { logOutAlert }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    @ViewBuilder private func labelValueRow(_ title: Text, _ value: Text) -> some View {
        HStack {
            title.foregroundColor(.primary)
            Spacer()
            value.foregroundColor(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
