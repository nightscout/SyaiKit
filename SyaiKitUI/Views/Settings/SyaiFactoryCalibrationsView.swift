//
//  SyaiFactoryCalibrationsView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import SyaiKit

struct SyaiFactoryCalibrationsView: View {
    let activeSensor: DeviceInfo?

    var body: some View {
        List {
            if let record = activeSensor, !record.mac.isEmpty {
                Section {
                    labelValueRow(Text("MAC", comment: "mac address"), Text(verbatim: record.mac))
                    labelValueRow(Text("Serial", comment: "serial"), Text(verbatim: record.serialNo))
                    labelValueRow(Text("Batch", comment: "batch"), Text(verbatim: record.batchNo))
                    labelValueRow(Text("Model", comment: "model"), Text(verbatim: record.deviceType))
                    labelValueRow(Text("Firmware", comment: "firmware"), Text(verbatim: record.deviceVersion))
                    labelValueRow(
                        Text("Production Date", comment: "production date"),
                        Text(verbatim: Self.produceDateFmt.string(from: record.produceTime))
                    )
                    if let expireTime = record.expireTime {
                        labelValueRow(
                            Text("Expires", comment: "expiration date"),
                            Text(verbatim: Self.produceDateFmt.string(from: expireTime))
                        )
                    }
                    coefficientTable(record.coefficients)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    @ViewBuilder private func coefficientTable(_ coefficients: [Double]) -> some View {
        ForEach(coefficients.indices, id: \.self) { i in
            HStack {
                Text(verbatim: "C\(i)")
                    .font(.body.monospaced())
                    .foregroundColor(.primary)
                Spacer()
                Text(verbatim: Self.fmt(coefficients[i]))
                    .font(.body.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func labelValueRow(_ title: Text, _ value: Text) -> some View {
        HStack {
            title.foregroundColor(.primary)
            Spacer()
            value.foregroundColor(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private static let produceDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func fmt(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1E15 {
            return String(format: "%.0f", value)
        }
        return String(describing: value)
    }
}
