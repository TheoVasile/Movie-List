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
        NavigationStack{
            ZStack{
                Color(UIColor.systemGray6)
                    .edgesIgnoringSafeArea(.all)
                VStack {
                    Spacer()
                    Text("Sign into your account")
                        .padding()
                    TextField("Email", text: $viewModel.email)
                        .padding()
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .padding(.bottom)
                    TextField("Password", text: $viewModel.password)
                        .padding()
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .padding(.bottom)
                    Button("Sign in") {
                        signInWithEmail()
                    }.padding(.bottom)
                    HStack{
                        Text("Don't have an account?")
                            .foregroundColor(.gray)
                        NavigationLink("Sign Up", destination: SignUpView()
                            .environmentObject(viewModel))
                        .foregroundColor(.blue)
                        .bold()
                    }
                    .padding()
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
    
struct SignInView_Previews: PreviewProvider {
    static var previews: some View {
        SignInView()
            .environmentObject(AuthenticationViewModel())
    }
}
