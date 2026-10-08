//
//  SyaiSensorPlacementView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKitUI
import SwiftUI
import UIKit

struct SyaiSensorPlacementView: View {
    var onDone: (() -> Void)?

    @State private var step = 0
    private let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                ForEach(0 ..< stepCount, id: \.self) { index in
                    ScrollView {
                        stepView(index)
                            .padding()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            footer
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
    }

    @ViewBuilder private func stepView(_ index: Int) -> some View {
        switch index {
        case 0:
            stepCard(1, Text("Step 1", comment: "placement step 1 label"), images: ["placement_step1"]) {
                Text(
                    "Choose the back of your upper arm as the application site. Avoid areas with scars, moles, stretch marks, or lumps.",
                    comment: "placement step 1 body"
                )
                callout(.note, Text("Note", comment: "placement note label")) {
                    Text(
                        "For optimal monitor performance, please select a site:",
                        comment: "placement step 1 note intro"
                    )
                    bullet(Text("Without scars, moles, stretch marks, or lumps.", comment: "placement step 1 note 1"))
                    bullet(Text("Avoid bony areas and irritated skin.", comment: "placement step 1 note 2"))
                    bullet(Text(
                        "Generally stays flat during your normal daily activities, avoiding any bending or folding.",
                        comment: "placement step 1 note 3"
                    ))
                    bullet(Text(
                        "At least 2.5 cm (1 inch) away from an insulin injection site.",
                        comment: "placement step 1 note 4"
                    ))
                    bullet(Text(
                        "Select a different site from the one most recently used to prevent discomfort or skin irritation.",
                        comment: "placement step 1 note 5"
                    ))
                    bullet(Text("Consider shaving the area to ensure a snug fit.", comment: "placement step 1 note 6"))
                }
            }

        case 1:
            stepCard(2, Text("Step 2", comment: "placement step 2 label"), images: ["placement_step2"]) {
                Text(
                    "Clean the application site and wait for the skin to dry before proceeding.",
                    comment: "placement step 2 body"
                )
                callout(.note, Text("Note", comment: "placement note label")) {
                    Text(
                        "The application site MUST be sufficiently clean and dry to make the Monitor adhere securely to the skin.",
                        comment: "placement step 2 note intro"
                    )
                    bullet(Text(
                        "Clean the skin using soap and wait to dry before sanitizing the application site with alcohol pads. Allow the site to air-dry before proceeding.",
                        comment: "placement step 2 note 1"
                    ))
                }
            }

        case 2:
            stepCard(3, Text("Step 3", comment: "placement step 3 label"), images: ["placement_step3"]) {
                Text(
                    "Rotate to open the bottom cover of the Applicator.",
                    comment: "placement step 3 body"
                )
                callout(.caution, Text("Caution", comment: "placement caution label")) {
                    bullet(Text(
                        "Do NOT use if the Applicator is opened or damaged before use. The needle is sterile unless the Applicator has been opened or damaged.",
                        comment: "placement step 3 caution 1"
                    ))
                    bullet(Text(
                        "Do NOT put the cover back on as it may damage the Monitor.",
                        comment: "placement step 3 caution 2"
                    ))
                    bullet(Text(
                        "Do NOT touch inside the Applicator as it contains a needle.",
                        comment: "placement step 3 caution 3"
                    ))
                    bullet(Text("Do NOT apply it if the expiry date has passed.", comment: "placement step 3 caution 4"))
                }
            }

        case 3:
            stepCard(4, Text("Step 4", comment: "placement step 4 label"), images: ["placement_step5", "placement_step6"]) {
                Text(
                    "Place the Applicator over your arm, press the launch button on the top, and gently pull away the Applicator. The Monitor should now be attached to the skin.",
                    comment: "placement step 4 body"
                )
                callout(.note, Text("Note", comment: "placement note label")) {
                    bullet(Text(
                        "Hold the Applicator flat against your arm and make sure the bottom edge is fully adhered to the skin, or application failure may occur.",
                        comment: "placement step 4 note 1"
                    ))
                    bullet(Text(
                        "Before removing the Applicator, keep holding the Applicator against your arm for a few seconds. This can help the adhesive stick to your skin.",
                        comment: "placement step 4 note 2"
                    ))
                    bullet(Text(
                        "Applying the Monitor may cause bleeding. If bleeding occurs,",
                        comment: "placement step 4 note 3"
                    ))
                    bullet(Text("Wipe away the blood with a cotton swab.", comment: "placement step 4 note 3a"), indented: true)
                    bullet(Text(
                        "If necessary, use a cotton swab to press on the small opening on the Monitor or apply ice packs to help stop the bleeding.",
                        comment: "placement step 4 note 3b"
                    ), indented: true)
                    bullet(Text(
                        "Remove the Monitor and apply a new one at a different site only if bleeding does not stop.",
                        comment: "placement step 4 note 3c"
                    ), indented: true)
                }
            }

        default:
            stepCard(5, Text("Step 5", comment: "placement step 5 label"), images: ["placement_step7"]) {
                Text(
                    "Gently press the tape around the edge of the Monitor to attach it firmly to the skin.",
                    comment: "placement step 5 body"
                )
                callout(.note, Text("Note", comment: "placement note label")) {
                    bullet(Text(
                        "Discard the used Applicator following local guidelines for disposal of blood and bodily fluid contact parts.",
                        comment: "placement step 5 note 1"
                    ))
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0 ..< stepCount, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            HStack(spacing: 12) {
                if step > 0 {
                    Button {
                        withAnimation { step -= 1 }
                    } label: {
                        Text("Back", comment: "placement stepper back button")
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                }

                if step < stepCount - 1 {
                    Button {
                        withAnimation { step += 1 }
                    } label: {
                        Text("Next", comment: "placement stepper next button")
                    }
                    .buttonStyle(ActionButtonStyle())
                } else if let onDone {
                    Button(action: onDone) {
                        Text("Done", comment: "placement stepper done button")
                    }
                    .buttonStyle(ActionButtonStyle())
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func stepCard<Content: View>(
        _ number: Int,
        _ title: Text,
        images: [String],
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(verbatim: "\(number)")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor))
                title.font(.headline)
            }
            illustration(images)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func illustration(_ names: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(names, id: \.self) { name in
                Image(imageName: name)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 180)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private enum CalloutKind {
        case note
        case caution
        var systemImage: String {
            switch self {
            case .note: return "info.circle.fill"
            case .caution: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .note: return .accentColor
            case .caution: return .orange
            }
        }
    }

    private func callout<Content: View>(
        _ kind: CalloutKind,
        _ title: Text,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                title.font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: kind.systemImage)
            }
            .foregroundColor(kind.color)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bullet(_ text: Text, indented: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•")
            text
            Spacer(minLength: 0)
        }
        .padding(.leading, indented ? 14 : 0)
    }
}
