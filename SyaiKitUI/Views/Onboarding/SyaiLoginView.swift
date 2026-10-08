//
//  SyaiLoginView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKitUI
import SwiftUI
import SyaiKit

struct SyaiLoginView: View {
    @Environment(\.dismissAction) private var dismiss
    @ObservedObject var viewModel: SyaiLoginViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(spacing: 0) {
                    fieldRow(icon: "envelope.fill") {
                        TextField(
                            String(localized: "Email", comment: "email field placeholder"),
                            text: $viewModel.email
                        )
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    }
                    Divider().padding(.leading, 54)
                    fieldRow(icon: "lock.fill") {
                        SecureField(
                            String(localized: "Password", comment: "password field placeholder"),
                            text: $viewModel.password
                        )
                        .textContentType(.password)
                        .onSubmit(viewModel.submit)
                    }
                }
                .cardBackground()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $viewModel.keepLoggedIn) {
                        Label {
                            Text("Keep me logged in", comment: "keep logged in toggle")
                        } icon: {
                            Image(systemName: "key.fill").foregroundColor(.accentColor)
                        }
                    }
                    Text(
                        viewModel.keepLoggedIn
                            ?
                            "Your session stays signed in for months. Your password is kept in the iOS Keychain so Trio can sign you back in if the session expires."
                            :
                            "Your password is used only to sign in and is never stored. If the session expires you'll be asked to sign in again.",
                        comment: "login password footer"
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .cardBackground()

                if let error = viewModel.errorMessage {
                    Label {
                        Text("Failed to login: \(error)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button(action: viewModel.submit) {
                HStack {
                    if viewModel.isBusy {
                        ActivityIndicator(isAnimating: .constant(true), style: .medium)
                    }
                    Text("Log In", comment: "log in button")
                }
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(!viewModel.canSubmit)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: dismiss) { Text("Cancel", comment: "cancel") }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)
            }
            Text("Sign in to Syai", comment: "login header")
                .font(.title2).bold()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func fieldRow<Content: View>(
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private extension View {
    func cardBackground() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
