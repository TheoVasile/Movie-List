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
        NavigationStack {
            ZStack{
                Color(UIColor.systemGray6)
                    .edgesIgnoringSafeArea(.all)
                VStack {
                    Spacer()
                    Text("Sign Up")
                    TextField("Name", text: $name)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    TextField("Email", text: $authenticationViewModel.email)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    SecureField("Password", text: $authenticationViewModel.password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    SecureField("Re-enter Password", text: $authenticationViewModel.confirmPassword)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    Button("Create Account") {
                        signUpWithEmail()
                    }
                    /*
                    NavigationLink(destination: AccountView()) {
                        Text("Create Account")
                            .foregroundColor(.white)
                            .padding(10)
                    }
                    .background(.blue)
                    .cornerRadius(20)
                    .padding()*/
                    HStack {
                        Text("Already have an account?")
                            .foregroundColor(.gray)
                        NavigationLink("Sign in", destination: SignInView()
                            .environmentObject(authenticationViewModel))
                            .foregroundColor(.blue)
                            .bold()
                    }
                    .padding()
                    Spacer()
                }
                .background(.white)
                .cornerRadius(20)
                .padding(20)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

struct SignUpView_Previews: PreviewProvider {
    static var previews: some View {
        SignUpView()
            .environmentObject(AuthenticationViewModel())
    }
}
