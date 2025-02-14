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
        VStack {
            Text("Email")
            TextField("", text: $viewModel.email)
                .padding()
                .frame(width: 200, height: 30)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.bottom)
            Text("Password")
            TextField("", text: $viewModel.password)
                .padding()
                .frame(width: 200, height: 30)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.bottom)
            Button("Sign in") {
                signInWithEmail()
            }.padding(.bottom)
            if invalidCredentials {
                Text("Incorrect username or password")
                    .padding(.bottom)
            }
            Divider()
                .padding(.bottom)
            Button(action: signInWithGoogle) {
                Text("Sign in with Google")
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
    }
}
    
struct SignInView_Previews: PreviewProvider {
    static var previews: some View {
        SignInView()
            .environmentObject(AuthenticationViewModel())
    }
}
