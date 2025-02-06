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
                    TextField("Email", text: $email)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    SecureField("Password", text: $password1)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    SecureField("Re-enter Password", text: $password2)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    NavigationLink(destination: AccountView()) {
                        Text("Create Account")
                            .foregroundColor(.white)
                            .padding(10)
                    }
                    .background(.blue)
                    .cornerRadius(20)
                    .padding()
                    HStack {
                        Text("Already have an account?")
                            .foregroundColor(.gray)
                        NavigationLink(destination: SignInView()) {
                            Text("Sign In")
                                .foregroundColor(.blue)
                                .bold()
                        }
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

struct SignUpView_Previews: PreviewProvider {
    static var previews: some View {
        SignUpView()
    }
}
