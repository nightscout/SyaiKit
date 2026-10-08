//
//  SyaiOnboardingView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKitUI
import SwiftUI

struct SyaiOnboardingView: View {
    @Environment(\.dismissAction) private var dismiss
    let onContinue: () -> Void
    let onShowPlacement: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Image(imageName: "sensor")
                                .resizable()
                                .scaledToFit()
                                .frame(height: 150)
                                .padding(.bottom, 10)
                            Spacer()
                        }
                        Text("Before you begin", comment: "onboarding header")
                            .font(.title3).bold()
                        Text(
                            "Apply the sensor and sign in to your Syai account. Then, you can activate the sensor and read from it directly in the app.",
                            comment: "onboarding BYOA explanation"
                        )
                    }
                }
            }

            Spacer()
            VStack(spacing: 10) {
                Button(action: onShowPlacement) {
                    Text("Placement Guide", comment: "placement guide button")
                }
                .buttonStyle(ActionButtonStyle(.secondary))

                Button(action: onContinue) {
                    Text("Continue", comment: "continue button")
                }
                .buttonStyle(ActionButtonStyle())
            }
            .padding(.horizontal)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: dismiss) { Text("Cancel", comment: "cancel") }
            }
        }
    }
}
