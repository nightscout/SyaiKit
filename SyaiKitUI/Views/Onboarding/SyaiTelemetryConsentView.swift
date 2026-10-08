//
//  SyaiTelemetryConsentView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKitUI
import SwiftUI
import SyaiKit

struct SyaiTelemetryConsentView: View {
    /// Called once, with the tier the user picked.
    let onChoice: (SyaiTelemetryTier) -> Void

    @State private var selected: SyaiTelemetryTier = .full

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(alignment: .leading, spacing: 14) {
                    Text(
                        "Your sensor is registered to your Syai account when you pair it, and released when you end it, whichever you choose below. That is how pairing works and cannot be turned off. Everything beyond it is up to you.",
                        comment: "telemetry consent explanation"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(SyaiTelemetryTier.allCases, id: \.self) { tier in
                        Button(action: { selected = tier }) {
                            SyaiTelemetryTierRow(tier: tier, selected: tier == selected)
                        }
                        .buttonStyle(.plain)
                    }

                    row(
                        icon: "arrow.uturn.backward",
                        Text(
                            "You can change this at any time in Account settings.",
                            comment: "telemetry consent reversible point"
                        )
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button(action: { onChoice(selected) }) {
                Text("Continue", comment: "telemetry consent confirm button")
            }
            .buttonStyle(ActionButtonStyle())
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
            }
            Text("What do you share with Syai?", comment: "telemetry consent header")
                .font(.title2).bold()
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func row(icon: String, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            text
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
