//
//  GoogleSignInButton.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import SwiftUI
import GoogleSignIn

struct GoogleSignInButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GIDSignInButton {
        return GIDSignInButton()
    }

    func updateUIView(_ uiView: GIDSignInButton, context: Context) {}
}
