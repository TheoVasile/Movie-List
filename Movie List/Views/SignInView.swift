//
//  SignInView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI

struct SignInView: View {
    @State private var email: String = ""
    @State private var password: String = ""
    var body: some View {
        NavigationStack {
            ZStack{
                Color(UIColor.systemGray6)
                    .edgesIgnoringSafeArea(.all)
                VStack {
                    Spacer()
                    Text("Sign In")
                    TextField("Email", text: $email)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    SecureField("Password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    NavigationLink(destination: AccountView()) {
                        Text("Log In")
                            .foregroundColor(.white)
                            .padding(10)
                    }
                    .background(.blue)
                    .cornerRadius(20)
                    .padding()
                    HStack {
                        Text("No account?")
                            .foregroundColor(.gray)
                        NavigationLink(destination: SignUpView()) {
                            Text("Sign Up")
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
    
struct SignInView_Previews: PreviewProvider {
    static var previews: some View {
        SignInView()
    }
}
