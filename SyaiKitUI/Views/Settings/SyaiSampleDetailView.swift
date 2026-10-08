//
//  SyaiSampleDetailView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import HealthKit
import LoopKitUI
import SwiftUI
import SyaiKit

/// All the diagnostic data on one glucose sample, pushed when the user taps
/// a row in Recent Readings.
struct SyaiSampleDetailView: View {
    let sample: GlucoseSample
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    var body: some View {
        List {
            Section {
                row(String(localized: "Value", comment: "sample detail: glucose value"), value: displayGlucosePreference.format(
                    HKQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL)
                ))
                row(
                    String(localized: "Time", comment: "sample detail: time"),
                    value: sample.date.formatted(date: .abbreviated, time: .standard)
                )
                row(String(localized: "Time (relative)", comment: "sample detail: relative time")) {
                    Text(sample.date, style: .relative)
                        .foregroundStyle(.secondary)
                }
                row(String(localized: "Trend", comment: "sample detail: trend"), value: trendLabel)
                if let rate = sample.rateOfChangeMgDLPerMinute {
                    row(
                        String(localized: "Rate of change", comment: "sample detail: rate of change"),
                        value: displayGlucosePreference.formatMinuteRate(
                            HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: rate)
                        )
                    )
                } else {
                    row(String(localized: "Rate of change", comment: "sample detail: rate of change"), value: "—")
                }
            } header: {
                Text("Reading", comment: "sample detail section: reading")
            }

            if sample.condition != nil || sample.hasBlockingIssue {
                Section {
                    if let condition = sample.condition {
                        row(String(localized: "Range", comment: "sample detail: range condition")) {
                            Text(
                                condition == .belowRange
                                    ? String(localized: "Below display range (LO)", comment: "sample detail: below range")
                                    : String(localized: "Above display range (HI)", comment: "sample detail: above range")
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    if sample.hasBlockingIssue {
                        row(String(localized: "Issue", comment: "sample detail: quality issue")) {
                            Text("Sensor reported fault", comment: "sample detail: sensor fault")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Quality", comment: "sample detail section: quality")
                }
            }

            Section {
                row(String(localized: "Sent", comment: "sample detail: sent to Trio")) {
                    HStack(spacing: 6) {
                        Image(systemName: sentIcon)
                            .foregroundStyle(sentColor)
                        Text(sentLabel)
                    }
                }
                if let reason = sample.forwardSkipReason, !sample.wasForwarded {
                    row(String(localized: "Reason", comment: "sample detail: not-forwarded reason")) {
                        Text(reason)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Forwarding to Trio", comment: "sample detail section: forwarding")
            }

            Section {
                row(String(localized: "Path", comment: "sample detail: source path"), value: sourceLabel)
                row("Sequence", value: "\(sample.sequence)")
                    .monospacedDigit()
                if abs(sample.rawBaseMgDL - sample.valueMgDL) > 0.5 {
                    row(
                        String(localized: "Raw base", comment: "sample detail: raw base before range clamp"),
                        value: displayGlucosePreference.format(
                            HKQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.rawBaseMgDL)
                        )
                    )
                }
            } header: {
                Text("Source", comment: "sample detail section: source")
            }
        }
        .navigationTitle(Text("Sample detail", comment: "sample detail screen title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// `LabeledContent` is iOS 16+; this project's floor is 15.1, so a plain
    /// title/value row does the same job.
    @ViewBuilder private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    /// Every paired sensor carries real calibration, so a forwarded sample
    /// is always dosing-grade here — no separate "display only" state.
    private var sentIcon: String {
        sample.wasForwarded ? "checkmark.circle.fill" : "minus.circle"
    }

    private var sentColor: Color {
        sample.wasForwarded ? .green : .secondary
    }

    private var sentLabel: String {
        sample.wasForwarded
            ? String(localized: "Yes", comment: "sample detail: sent to Trio")
            : String(localized: "No", comment: "sample detail: not sent to Trio")
    }

    private var trendLabel: String {
        switch sample.trend {
        case .notDetermined: return "—"
        case .risingQuickly: return String(localized: "Rising quickly ⇈", comment: "trend: rising quickly")
        case .rising: return String(localized: "Rising ↗", comment: "trend: rising")
        case .stable: return String(localized: "Stable →", comment: "trend: stable")
        case .falling: return String(localized: "Falling ↘", comment: "trend: falling")
        case .fallingQuickly: return String(localized: "Falling quickly ⇊", comment: "trend: falling quickly")
        }
    }

    private var sourceLabel: String {
        switch sample.source {
        case .realtime: return String(localized: "Realtime (live BLE)", comment: "sample source: realtime")
        case .historicalBackfill: return String(localized: "Historical backfill", comment: "sample source: historical backfill")
        }
    }
}
