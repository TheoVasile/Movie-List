//
//  SignUpView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI
import AuthenticationServices

struct SignUpView: View {
    @State private var email: String = ""
    @State private var password1: String = ""
    @State private var password2: String = ""
    @State private var name: String = ""
    @State private var handle: String = ""
    // nil while unchecked or checking; false when someone else has it
    @State private var handleAvailable: Bool? = nil
    @State private var isCreating = false
    @EnvironmentObject var authenticationViewModel: AuthenticationViewModel
    @Environment(\.dismiss) var dismiss
    @State var invalidCredentials: Bool = false
    @State private var signingInWithApple = false
    // Why Apple sign-in failed; nothing when they closed Apple's sheet
    @State private var appleError: String? = nil

    private var cleanedHandle: String {
        handle.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
    }

    // Same rule as the server: 3-20 of a-z, 0-9, _ and ., no leading, trailing or doubled dots
    private var handleIsValid: Bool {
        cleanedHandle.range(of: #"^(?!\.)(?!.*\.\.)(?!.*\.$)[a-z0-9_.]{3,20}$"#, options: .regularExpression) != nil
    }

    private var handleNote: (text: String, isProblem: Bool) {
        if cleanedHandle.isEmpty { return ("How people find you. 3 to 20 letters, numbers, underscores or dots.", false) }
        if !handleIsValid { return ("3 to 20 letters, numbers, underscores or dots.", true) }
        switch handleAvailable {
        case .some(false): return ("@\(cleanedHandle) is taken.", true)
        case .some(true): return ("@\(cleanedHandle) is yours if you want it.", false)
        case .none: return ("Checking…", false)
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && handleIsValid && handleAvailable != false && !isCreating
    }

    /// Checks the username shortly after typing stops
    private func checkHandle() {
        handleAvailable = nil
        let wanted = cleanedHandle
        guard handleIsValid else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard wanted == cleanedHandle else { return }
            APIService.shared.isHandleAvailable(wanted) { available in
                // Couldn't check: let them try, and they'll be asked again if it was taken
                if wanted == cleanedHandle { handleAvailable = available ?? true }
            }
        }
    }

    private func signUpWithEmail() {
        isCreating = true
        Task {
            defer { isCreating = false }
            if await authenticationViewModel.signUpWithEmailPassword(name: name, handle: cleanedHandle) == true {
                dismiss()
            } else {
                invalidCredentials = true
            }
        }
    }
    
    private func signUpWithApple(_ result: Result<ASAuthorization, Error>) {
        signingInWithApple = true
        appleError = nil
        Task {
            defer { signingInWithApple = false }
            if await authenticationViewModel.signInWithApple(result) {
                dismiss()
            } else if !authenticationViewModel.errorMessage.isEmpty {
                appleError = authenticationViewModel.errorMessage
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
                    VStack(alignment: .leading, spacing: 6) {
                        AuthField(icon: "at", placeholder: "Username", text: $handle)
                            .textContentType(.username)
                            .onChange(of: handle) { _ in checkHandle() }
                        Text(handleNote.text)
                            .font(.caption)
                            .foregroundColor(handleNote.isProblem ? Theme.accentSecondary : Theme.textTertiary)
                            .padding(.leading, 4)
                    }
                    .appearAnimation(delay: 0.08)
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
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.5)
                    .padding(.top, 8)
                    .appearAnimation(delay: 0.25)

                    HStack {
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                        Text("or")
                            .font(.footnote)
                            .foregroundColor(Theme.textTertiary)
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                    }
                    .padding(.vertical, 6)

                    if let appleError {
                        Label(appleError, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Theme.accentSecondary)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Apple gives the name; the username is asked for once the account is made
                    AppleSignInButton(label: .signUp, isWorking: signingInWithApple, onCompletion: signUpWithApple)
                        .appearAnimation(delay: 0.26)

                    TermsNotice(confirmsAge: true)
                        .appearAnimation(delay: 0.27)

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
                // Nothing else can be tapped while Apple sign-in finishes
                .disabled(signingInWithApple)
                .animation(Theme.spring, value: invalidCredentials)
                .animation(Theme.spring, value: appleError)
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
