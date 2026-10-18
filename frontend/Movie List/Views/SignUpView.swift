//
//  SignUpView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI

struct SignUpView: View {
    @State private var email: String = ""
    @State private var password1: String = ""
    @State private var password2: String = ""
    @State private var name: String = ""
    @EnvironmentObject var authenticationViewModel: AuthenticationViewModel
    @Environment(\.dismiss) var dismiss
    @State var invalidCredentials: Bool = false
    
    private func signUpWithEmail() {
        Task {
            if await authenticationViewModel.signUpWithEmailPassword() == true {
                dismiss()
            } else {
                invalidCredentials = true
            }
        }
    }
    
    var body: some View {
        ZStack{
            AuthBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Create account")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundColor(Theme.textPrimary)
                        Text("Start building your ranked film lists.")
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.bottom, 12)
                    .appearAnimation()

                    AuthField(icon: "person.fill", placeholder: "Name", text: $name)
                        .textContentType(.name)
                        .appearAnimation(delay: 0.05)
                    AuthField(icon: "envelope.fill", placeholder: "Email", text: $authenticationViewModel.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .appearAnimation(delay: 0.1)
                    AuthField(icon: "lock.fill", placeholder: "Password", text: $authenticationViewModel.password, isSecure: true)
                        .textContentType(.newPassword)
                        .appearAnimation(delay: 0.15)
                    AuthField(icon: "lock.rotation", placeholder: "Re-enter Password", text: $authenticationViewModel.confirmPassword, isSecure: true)
                        .textContentType(.newPassword)
                        .appearAnimation(delay: 0.2)

                    if invalidCredentials {
                        Label("Couldn't create your account. Check your details and try again.", systemImage: "exclamationmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Theme.accentSecondary)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Button("Create Account") {
                        signUpWithEmail()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
                    .appearAnimation(delay: 0.25)

                    HStack {
                        Text("Already have an account?")
                            .foregroundColor(Theme.textSecondary)
                        Button("Sign in") { dismiss() }
                            .foregroundColor(Theme.accent)
                            .bold()
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .padding(24)
                .padding(.top, 20)
                .animation(Theme.spring, value: invalidCredentials)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

struct SignUpView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SignUpView()
                .environmentObject(AuthenticationViewModel())
        }
    }
}
