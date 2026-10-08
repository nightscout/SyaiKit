//
//  SyaiExistingSensorView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKitUI
import SwiftUI
import SyaiKit

struct SyaiExistingSensorView: View {
    @ObservedObject var viewModel: SyaiExistingSensorViewModel
    @Environment(\.guidanceColors) private var guidanceColors

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack {
            List {
                switch viewModel.phase {
                case .checking:
                    Section {
                        HStack {
                            ActivityIndicator(isAnimating: .constant(true), style: .medium)
                            Text("Checking your account for a sensor…", comment: "existing sensor: checking")
                                .foregroundColor(.secondary)
                        }
                    }
                case let .found(sensor), let .adopting(sensor):
                    sensorSection(sensor)
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(guidanceColors.warning)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Close the Syai app first", comment: "existing sensor: one connection title")
                                    .fontWeight(.heavy)
                                Text(
                                    "The sensor can only talk to one app at a time. Force-quit the official Syai app (swipe it away in the app switcher) before continuing, or \(Bundle.main.syaiHostAppName) won't be able to connect.",
                                    comment: "existing sensor: one connection message (1: appName)"
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                case let .unusable(sensor, reason):
                    sensorSection(sensor)
                    Section {
                        Text(reason).foregroundColor(guidanceColors.critical)
                    }
                case let .failed(message):
                    Section {
                        Text(message).foregroundColor(guidanceColors.critical)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())

            buttons
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    private func sensorSection(_ sensor: SyaiBoundSensor) -> some View {
        Section {
            HStack {
                Spacer()
                Image(imageName: "sensor")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 120)
                Spacer()
            }
            row(Text("MAC", comment: "sensor mac"), sensor.mac)
            if let activatedAt = sensor.activatedAt {
                row(Text("Started at", comment: "started"), Self.dateFormatter.string(from: activatedAt))
            }
        } header: {
            Text("Sensor on your account", comment: "existing sensor header")
        }
    }

    private func row(_ title: Text, _ value: String) -> some View {
        HStack {
            title
            Spacer()
            Text(verbatim: value).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch viewModel.phase {
        case .checking:
            EmptyView()
        case .found:
            VStack(spacing: 10) {
                Button(action: viewModel.useSensor) {
                    Text("Use This Sensor", comment: "adopt bound sensor button")
                }
                .buttonStyle(ActionButtonStyle())
                Button(action: viewModel.pairNewSensor) {
                    Text("Pair a New Sensor Instead", comment: "skip bound sensor button")
                }
                .buttonStyle(ActionButtonStyle(.secondary))
            }
        case .adopting:
            ActivityIndicator(isAnimating: .constant(true), style: .medium)
        case .unusable:
            Button(action: viewModel.pairNewSensor) {
                Text("Pair a New Sensor", comment: "pair new sensor button")
            }
            .buttonStyle(ActionButtonStyle())
        case .failed:
            VStack(spacing: 10) {
                Button(action: viewModel.check) {
                    Text("Try Again", comment: "retry button")
                }
                .buttonStyle(ActionButtonStyle())
                Button(action: viewModel.pairNewSensor) {
                    Text("Pair a New Sensor Instead", comment: "skip bound sensor button")
                }
                .buttonStyle(ActionButtonStyle(.secondary))
            }
        }
    }
}
