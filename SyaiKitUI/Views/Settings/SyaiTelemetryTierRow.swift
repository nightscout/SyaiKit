//
//  SyaiTelemetryTierRow.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import SyaiKit

struct SyaiTelemetryTierRow: View {
    let tier: SyaiTelemetryTier
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(selected ? .accentColor : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    SyaiTelemetryTierDetail.title(tier).foregroundColor(.primary)
                    if tier == .full {
                        Text("Recommended", comment: "recommended tier badge")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                    }
                }
                SyaiTelemetryTierDetail.description(tier)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

enum SyaiTelemetryTierDetail {
    static func title(_ tier: SyaiTelemetryTier) -> Text {
        switch tier {
        case .minimal: return Text("Minimal", comment: "tier: minimal")
        case .standard: return Text("Standard", comment: "tier: standard")
        case .full: return Text("Full", comment: "tier: full")
        }
    }

    static func description(_ tier: SyaiTelemetryTier) -> Text {
        switch tier {
        case .minimal:
            return Text(
                "Only what pairing a sensor requires.",
                comment: "tier detail: minimal"
            )
        case .standard:
            return Text(
                "Also tells Syai when your sensor connects, disconnects, or reports a problem.",
                comment: "tier detail: standard"
            )
        case .full:
            return Text(
                "Also uploads your glucose readings, exactly as the official app does. Allows your doctor/caregivers to keep following your treatment.",
                comment: "tier detail: full"
            )
        }
    }
}
