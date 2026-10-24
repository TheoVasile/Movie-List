//
//  SignInView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI

struct SignInView: View {
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @Environment(\.dismiss) var dismiss
    @State var invalidCredentials: Bool = false
    @State private var showPasswordReset = false
    
    private func signInWithGoogle() {
        Task {
            if await viewModel.signInWithGoogle() == true {
            dismiss()
            }
        }
    }
    private func signInWithEmail() {
        Task {
            if await viewModel.signInWithEmailPassword() == true {
                dismiss()
            } else {
                invalidCredentials = true
            }
        }
    }
    var body: some View {
        NavigationStack{
            ZStack{
                AuthBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Welcome back")
                                .font(.system(size: 32, weight: .heavy, design: .rounded))
                                .foregroundColor(Theme.textPrimary)
                            Text("Sign in to pick up where you left off.")
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.bottom, 12)
                        .appearAnimation()

                        AuthField(icon: "envelope.fill", placeholder: "Email", text: $viewModel.email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .appearAnimation(delay: 0.06)
                        AuthField(icon: "lock.fill", placeholder: "Password", text: $viewModel.password, isSecure: true)
                            .textContentType(.password)
                            .appearAnimation(delay: 0.12)

                        Button("Forgot password?") {
                            showPasswordReset = true
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .appearAnimation(delay: 0.14)

                        if invalidCredentials {
                            Label("Incorrect username or password", systemImage: "exclamationmark.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(Theme.accentSecondary)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        Button("Sign in") {
                            signInWithEmail()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 8)
                        .appearAnimation(delay: 0.18)

                        HStack {
                            Rectangle().fill(Theme.stroke).frame(height: 1)
                            Text("or")
                                .font(.footnote)
                                .foregroundColor(Theme.textTertiary)
                            Rectangle().fill(Theme.stroke).frame(height: 1)
                        }
                        .padding(.vertical, 6)

                        // Styled like the app's other buttons; Google's own button is square and
                        // clipping its corners cut into the logo
                        Button(action: signInWithGoogle) {
                            HStack(spacing: 10) {
                                Image("GoogleLogo")
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text("Sign in with Google")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .appearAnimation(delay: 0.24)

                        // Signing in with Google can create the account, so it's agreed to here too
                        TermsNotice()
                            .appearAnimation(delay: 0.26)

                        HStack{
                            Text("Don't have an account?")
                                .foregroundColor(Theme.textSecondary)
                            NavigationLink("Sign Up", destination: SignUpView()
                                .environmentObject(viewModel))
                            .foregroundColor(Theme.accent)
                            .bold()
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    }
                    .padding(24)
                    .padding(.top, 40)
                    .animation(Theme.spring, value: invalidCredentials)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showPasswordReset) {
            PasswordResetView(email: viewModel.email)
                .environmentObject(viewModel)
                .presentationDetents([.medium])
        }
    }
}

/// Sends a password reset link to the email the user enters, starting with whatever they typed on the
/// sign-in screen. Firebase emails a link to a page where they choose a new password
struct PasswordResetView: View {
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @Environment(\.dismiss) var dismiss
    @State var email: String
    @State private var isSending = false
    @State private var sentTo: String? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                if let sentTo {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accentGradient)
                    Text("Check your email")
                        .font(.title2.bold())
                        .foregroundColor(Theme.textPrimary)
                    Text("If an account exists for \(sentTo), we've sent it a link to choose a new password. It can take a minute to arrive, so check your spam folder too.")
                        .foregroundColor(Theme.textSecondary)
                    Button("Back to Sign In") {
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
                } else {
                    Text("Reset your password")
                        .font(.title2.bold())
                        .foregroundColor(Theme.textPrimary)
                    Text("Enter the email you signed up with and we'll send you a link to choose a new password.")
                        .foregroundColor(Theme.textSecondary)
                    AuthField(icon: "envelope.fill", placeholder: "Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .onSubmit(send)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Theme.accentSecondary)
                    }
                    Button(action: send) {
                        if isSending {
                            ProgressView().tint(Theme.onAccent)
                        } else {
                            Text("Send Reset Link")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isSending)
                    .padding(.top, 8)
                }
            }
            .padding(24)
            .animation(Theme.spring, value: sentTo)
            .animation(Theme.spring, value: errorMessage)
        }
    }

    private func send() {
        Haptics.tap()
        isSending = true
        errorMessage = nil
        Task {
            let error = await viewModel.sendPasswordReset(to: email)
            isSending = false
            if let error {
                errorMessage = error
            } else {
                sentTo = email.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

// MARK: - Shared auth components

struct AuthBackground: View {
    @State private var shift = false

    var body: some View {
        ZStack {
            Theme.background
            Circle()
                .fill(Theme.accent)
                .frame(width: 320, height: 320)
                .blur(radius: 120)
                .opacity(0.35)
                .offset(x: shift ? -120 : -60, y: shift ? -300 : -240)
            Circle()
                .fill(Theme.accentSecondary)
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .opacity(0.3)
                .offset(x: shift ? 140 : 80, y: shift ? 320 : 260)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                shift = true
            }
        }
    }
}

struct AuthField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(focused ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                .frame(width: 20)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .focused($focused)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .foregroundColor(Theme.textPrimary)
        }
        .padding(16)
        .background(Theme.surface.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(focused ? Theme.accent.opacity(0.7) : Theme.stroke, lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.2), value: focused)
    }
}
    
struct SignInView_Previews: PreviewProvider {
    static var previews: some View {
        SignInView()
            .environmentObject(AuthenticationViewModel())
    }
}
