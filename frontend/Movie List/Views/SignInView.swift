//
//  SignInView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI
import GoogleSignInSwift

struct SignInView: View {
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @Environment(\.dismiss) var dismiss
    @State var invalidCredentials: Bool = false
    
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
                                .foregroundColor(.white)
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

                        GoogleSignInButton(scheme: .dark, style: .wide, action: signInWithGoogle)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .appearAnimation(delay: 0.24)

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
            .foregroundColor(.white)
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
