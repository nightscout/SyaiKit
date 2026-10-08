//
//  SyaiSettingsView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import HealthKit
import LoopKitUI
import SwiftUI
import SyaiKit
import UniformTypeIdentifiers

struct SyaiSettingsView: View {
    @Environment(\.dismissAction) private var dismiss
    @Environment(\.guidanceColors) var guidanceColors
    @EnvironmentObject var displayGlucosePreference: DisplayGlucosePreference

    @ObservedObject var viewModel: SyaiSettingsViewModel

    var body: some View {
        List {
            statusSection

            recentReadingsSection

            sensorInformationSection

            managementSection

            accountSection

            Section {
                Button(action: { viewModel.activeAlert = .deleteConfirm }) {
                    Text("Delete CGM", comment: "delete")
                        .foregroundColor(guidanceColors.critical)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .alert(item: $viewModel.activeAlert) { alert in
            switch alert {
            case .deleteConfirm: return removeCGMAlert
            case .endSensorConfirm: return endSensorAlert
            case .endSensorForceConfirm: return forceEndSensorAlert
            case .endSensorError:
                return Alert(
                    title: Text("Could not end sensor", comment: "end sensor error title"),
                    message: Text(viewModel.endSensorError ?? ""),
                    dismissButton: .default(Text("OK", comment: "ok"))
                )
            }
        }
        .navigationBarItems(trailing: Button(action: dismiss) { Text("Done", comment: "done") })
    }

    @ViewBuilder private var recentReadingsSection: some View {
        if !viewModel.recentSamples.isEmpty {
            Section {
                SyaiReadingRowHeader()

                let visible = Array(viewModel.recentSamples.prefix(5))
                ForEach(visible.indices, id: \.self) { idx in
                    Button(action: { viewModel.showSampleDetail(visible[idx]) }) {
                        SyaiReadingRow(sample: visible[idx])
                    }
                }
                if viewModel.recentSamples.count > 5 {
                    Button(action: { viewModel.showAllReadings() }) {
                        HStack {
                            Text(String(
                                format: String(localized: "Show all %d", comment: "link to the full recent readings list"),
                                viewModel.recentSamples.count
                            ))
                                .foregroundColor(.accentColor)
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Recent Readings", comment: "recent readings section header")
            }
        }
    }

    @ViewBuilder private var sensorInformationSection: some View {
        if viewModel.hasSensor {
            Section {
                SectionItem(title: Text("Model", comment: "sensor model"), value: viewModel.sensorModel)
                SectionItem(title: Text("MAC", comment: "sensor mac"), value: viewModel.mac)
                SectionItem(title: Text("Started at", comment: "started"), value: viewModel.sensorStartedAt)
                SectionItem(title: Text("Ends at", comment: "ends"), value: viewModel.sensorEndsAt)
            } header: {
                Text("Sensor information", comment: "sensor info")
            }
        }
    }

    @ViewBuilder private var managementSection: some View {
        Section {
            Button(action: { viewModel.isSharePresented = true }) {
                Text("Share Syai logs", comment: "share logs")
            }
            .sheet(isPresented: $viewModel.isSharePresented, onDismiss: {}, content: {
                ActivityViewController(activityItems: viewModel.getLogs())
            })

            if viewModel.hasSensor, !viewModel.showingEndSensorButton {
                Button(action: { viewModel.activeAlert = .endSensorConfirm }) {
                    HStack {
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
                    .contentShape(Rectangle())
                }
                .disabled(viewModel.isEndingSensor)
            } else {
                Button(action: viewModel.pairNewSensor) {
                    Text("Pair New Sensor", comment: "pair new sensor")
                }
            }
        } header: {
            Text("Manage", comment: "manage")
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            Button(action: { viewModel.showSensorHistory() }) {
                HStack {
                    Text("Sensor History", comment: "sensor history link")
                        .foregroundColor(.accentColor)
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            if viewModel.accountLoggedIn {
                Button(action: { viewModel.showAccount() }) {
                    HStack {
                        Text("Account", comment: "account link")
                            .foregroundColor(.accentColor)
                        if viewModel.accountLockedOutElsewhere {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(guidanceColors.warning)
                                .font(.footnote)
                        }
                        Spacer()
                        Text(verbatim: viewModel.accountEmail)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Button(action: { viewModel.showLogin() }) {
                    Text("Login", comment: "login link")
                }
            }
        }
    }

    @ViewBuilder private func SectionItem(title: Text, value: String, font: Font = .body) -> some View {
        HStack {
            title.foregroundColor(.primary)
            Spacer()
            Text(value).font(font).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
