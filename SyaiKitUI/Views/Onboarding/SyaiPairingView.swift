//
//  SyaiPairingView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import AVFoundation
import LoopKitUI
import SwiftUI
import SyaiKit
import UniformTypeIdentifiers

struct SyaiPairingView: View {
    @ObservedObject var viewModel: SyaiPairingViewModel

    @State private var showingScanner = false
    @State private var showingCameraDenied = false

    var body: some View {
        VStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Image(imageName: "sensor")
                                .resizable()
                                .scaledToFit()
                                .frame(height: 150)
                                .padding(.bottom, 20)
                            Spacer()
                        }
                        if viewModel.phase == .choosingMethod {
                            Text("Find your sensor", comment: "pairing method header")
                                .font(.title3).bold()
                            Text(
                                "Scan the QR code on the sensor applicator, or search for sensors nearby.",
                                comment: "pairing method body"
                            )
                        } else {
                            Text("Please be patient", comment: "pairing header")
                                .font(.title3).bold()
                            Text(
                                "Keep your phone near the sensor. This can take up to a minute.",
                                comment: "pairing body"
                            )
                        }
                    }
                }

                if viewModel.phase == .confirming, let mac = viewModel.scannedMAC {
                    Section {
                        Text(mac)
                    } header: {
                        Text("Scanned sensor", comment: "scanned applicator header")
                    }
                } else if viewModel.phase == .confirming, let candidate = viewModel.bestCandidate {
                    Section {
                        // bestCandidate is always a fresh (unknown) MAC. A
                        // known/retired advertiser is never auto-presented, so
                        // no retired badge is possible on this card.
                        HStack {
                            Text(candidate.mac)
                            Spacer()
                            if let rssi = candidate.rssi {
                                Text("\(rssi) dBm")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Is this your sensor?", comment: "confirm candidate header")
                    }
                }

                if viewModel.phase == .picking {
                    Section {
                        if viewModel.candidates.isEmpty {
                            Text(
                                "No sensors heard. The sensor advertises in bursts. Try scanning again.",
                                comment: "no candidates text"
                            )
                            .foregroundColor(.secondary)
                        }
                        ForEach(viewModel.candidates) { candidate in
                            let isKnown = viewModel.retiredMACs.contains(candidate.mac)
                            Button(action: { viewModel.selectedMAC = candidate.mac }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.mac)
                                        if isKnown {
                                            Text("Previously used, can't be re-paired", comment: "retired sensor badge")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                    Spacer()
                                    if let rssi = candidate.rssi {
                                        Text("\(rssi) dBm")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if viewModel.selectedMAC == candidate.mac {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                            // A known MAC is a bound/retired sensor that can't
                            // be re-paired: badged but not selectable.
                            .disabled(isKnown)
                        }
                    } header: {
                        Text("Select your sensor", comment: "candidate list header")
                    }
                }

                if viewModel.phase == .pairing, let mac = viewModel.selectedMAC {
                    Section {
                        // The MAC stays on screen for the whole flow: if it
                        // isn't the user's sensor, they bail out instead of
                        // activating the wrong one.
                        HStack {
                            Text("Found sensor", comment: "discovered sensor label")
                            Spacer()
                            Text(mac).foregroundColor(.secondary)
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error).foregroundColor(.red)
                        if viewModel.phase == .pairing {
                            Button(action: viewModel.retry) {
                                Text("Try Again", comment: "retry button")
                            }
                            Button(action: viewModel.backToConfirmation) {
                                Text("Change Sensor", comment: "back to sensor confirmation button")
                            }
                        }
                    }
                }
            }
            Spacer()

            switch viewModel.phase {
            case .choosingMethod:
                VStack(spacing: 10) {
                    Button(action: scanApplicatorTapped) {
                        Label(
                            String(localized: "Scan Applicator", comment: "scan applicator button"),
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(ActionButtonStyle())
                    Button(action: viewModel.scan) {
                        Text("Search Nearby", comment: "search nearby sensors button")
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                }
                .padding(.horizontal)
                .padding(.bottom)
            case .scanning:
                VStack(spacing: 5) {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                    Text("Searching for nearby sensors…", comment: "scanning status").font(.footnote)
                }
                .padding(.bottom)
            case .confirming:
                VStack(spacing: 10) {
                    Button(action: viewModel.pair) {
                        Text("Pair", comment: "pair button")
                    }
                    .buttonStyle(ActionButtonStyle())
                    if viewModel.scannedMAC != nil {
                        Button(action: scanApplicatorTapped) {
                            Text("Scan Again", comment: "rescan applicator button")
                        }
                        .buttonStyle(ActionButtonStyle(.secondary))
                    }
                    // Only offer the list escape when there's actually another
                    // advertiser to choose: a single heard sensor has no
                    // alternative to pick.
                    if viewModel.candidates.count > 1 {
                        Button(action: viewModel.showAllSensors) {
                            Text("My sensor isn't listed", comment: "show all sensors fallback button")
                        }
                        .buttonStyle(ActionButtonStyle(.secondary))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            case .picking:
                VStack(spacing: 10) {
                    Button(action: viewModel.pair) {
                        Text("Pair", comment: "pair button")
                    }
                    .buttonStyle(ActionButtonStyle())
                    .disabled(viewModel.selectedMAC == nil)
                    Button(action: viewModel.scan) {
                        Text("Scan Again", comment: "rescan button")
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                    if viewModel.canScanApplicator {
                        Button(action: scanApplicatorTapped) {
                            Text("Scan Applicator Instead", comment: "switch to applicator scan button")
                        }
                        .buttonStyle(ActionButtonStyle(.secondary))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            case .pairing:
                if viewModel.errorMessage == nil {
                    VStack(spacing: 5) {
                        ActivityIndicator(isAnimating: .constant(true), style: .medium)
                        Text(viewModel.statusText).font(.footnote)
                    }
                    .padding(.bottom)
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            NavigationView {
                SyaiApplicatorScannerView { mac in
                    showingScanner = false
                    viewModel.didScanApplicator(mac: mac)
                }
                .ignoresSafeArea()
                .navigationBarTitle(Text("Scan Applicator", comment: "applicator scanner title"), displayMode: .inline)
                .navigationBarItems(trailing: Button(String(localized: "Cancel", comment: "cancel applicator scan")) {
                    showingScanner = false
                })
            }
        }
        .alert(
            String(localized: "Camera Access Is Off", comment: "camera denied alert title"),
            isPresented: $showingCameraDenied
        ) {
            Button(String(localized: "Open Settings", comment: "open iOS settings button")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(String(localized: "Cancel", comment: "cancel camera alert"), role: .cancel) {}
        } message: {
            Text(
                "Allow camera access in Settings to scan the applicator, or search for sensors nearby instead.",
                comment: "camera denied alert message"
            )
        }
    }

    /// The scanner shows a blank view without camera access, so ask first.
    private func scanApplicatorTapped() {
        #if targetEnvironment(simulator)
            viewModel.didScanApplicator(mac: SyaiCGMManager.simulatedApplicatorMAC())
        #else
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                showingScanner = true
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            showingScanner = true
                        } else {
                            showingCameraDenied = true
                        }
                    }
                }
            default:
                showingCameraDenied = true
            }
        #endif
    }
}
