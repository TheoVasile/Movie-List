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
    
    private func signInWithGoogle() {
        Task {
          if await viewModel.signInWithGoogle() == true {
            dismiss()
          }
        }
      }
    var body: some View {
        VStack {
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
