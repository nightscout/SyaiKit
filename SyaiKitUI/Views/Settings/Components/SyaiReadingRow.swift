//
//  SyaiReadingRow.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import HealthKit
import LoopKitUI
import SwiftUI
import SyaiKit

struct SyaiReadingRow: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    let sample: GlucoseSample

    var body: some View {
        HStack {
            Text(sample.date, style: .time)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 72, alignment: .leading)
            Text(displayGlucosePreference.format(
                HKQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
                includeUnit: false
            ))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(sample.wasForwarded ? .primary : .secondary)
                .frame(width: 48, alignment: .trailing)
            if let rate = sample.rateOfChangeMgDLPerMinute {
                Text(displayGlucosePreference.formatMinuteRate(
                    HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: rate),
                    includeUnit: false
                ))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            } else {
                Spacer().frame(width: 56)
            }
            Spacer()
            Image(systemName: trendSymbol)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .font(.subheadline)
        .foregroundColor(.primary)
        .opacity(sample.wasForwarded ? 1.0 : 0.7)
    }

    private var trendSymbol: String {
        switch sample.trend {
        case .notDetermined: return "minus"
        case .risingQuickly: return "arrow.up"
        case .rising: return "arrow.up.right"
        case .stable: return "arrow.right"
        case .falling: return "arrow.down.right"
        case .fallingQuickly: return "arrow.down"
        }
    }
}

struct SyaiReadingRowHeader: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    var body: some View {
        HStack {
            Text("Time", comment: "recent readings column header: time")
                .frame(width: 72, alignment: .leading)
            Text(displayGlucosePreference.unit.shortLocalizedUnitString())
                .frame(width: 48, alignment: .trailing)
            Text("\(displayGlucosePreference.unit.shortLocalizedUnitString())/min")
                .frame(width: 56, alignment: .trailing)
            Spacer()
            Text("Trend", comment: "recent readings column header: trend")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
