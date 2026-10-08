//
//  SyaiSensorHistoryView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import SyaiKit

/// Diagnostic list of every sensor this install has activated. The MAC (not
/// the internal serial number) is shown because it is printed on the box; the
/// serial number is surfaced only in the factory calibration detail.
struct SyaiSensorHistoryView: View {
    let records: [SyaiSensorRecord]
    let activeMAC: String?
    let onSelect: (DeviceInfo) -> Void

    var body: some View {
        List {
            if records.isEmpty {
                Section {
                    Text("No sensors have been paired yet.", comment: "empty sensor history")
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(records) { record in
                        Button(action: { onSelect(record.deviceInfo) }) {
                            row(for: record)
                        }
                    }
                } footer: {
                    Text(
                        "Tap a sensor to see its calibration and device details.",
                        comment: "sensor history footer"
                    )
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    @ViewBuilder private func row(for record: SyaiSensorRecord) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(record.deviceInfo.deviceType) - \(record.deviceInfo.mac)")
                    .foregroundColor(.primary)
                Text(verbatim: subtitle(for: record))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if record.mac == activeMAC {
                currentPill
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        }
    }

    private var currentPill: some View {
        Text("current", comment: "current sensor pill")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor))
    }

    /// The lifecycle date most relevant to this row.
    private func subtitle(for record: SyaiSensorRecord) -> String {
        if let retired = record.retiredAt {
            return String(
                format: String(localized: "Retired %@", comment: "retired date"),
                Self.dateFormatter.string(from: retired)
            )
        }
        if let activated = record.activatedAt {
            return String(
                format: String(localized: "Active since %@", comment: "active since date"),
                Self.dateFormatter.string(from: activated)
            )
        }
        return String(localized: "Active", comment: "active sensor fallback subtitle")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
