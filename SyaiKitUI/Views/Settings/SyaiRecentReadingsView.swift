//
//  SyaiRecentReadingsView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import SyaiKit

struct SyaiRecentReadingsView: View {
    let samples: [GlucoseSample]
    let onSelect: (GlucoseSample) -> Void

    var body: some View {
        List {
            if samples.isEmpty {
                Section {
                    Text("No readings yet.", comment: "empty recent readings")
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    SyaiReadingRowHeader()
                    ForEach(samples.indices, id: \.self) { idx in
                        Button(action: { onSelect(samples[idx]) }) {
                            SyaiReadingRow(sample: samples[idx])
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
}
