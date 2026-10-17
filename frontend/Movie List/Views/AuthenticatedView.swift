//
//  AuthenticatedView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI

extension AuthenticatedView where Unauthenticated == EmptyView {
  init(@ViewBuilder content: @escaping () -> Content) {
    self.unauthenticated = nil
    self.content = content
  }
}

struct AuthenticatedView<Content, Unauthenticated>: View where Content: View, Unauthenticated: View {
    @StateObject private var viewModel = AuthenticationViewModel()
    @State private var presentingLoginScreen = false
    @State private var presentingProfileScreen = false
    @State private var isVisible = false

    var unauthenticated: Unauthenticated?
    @ViewBuilder var content: () -> Content

    public init(unauthenticated: Unauthenticated?, @ViewBuilder content: @escaping () -> Content) {
    self.unauthenticated = unauthenticated
    self.content = content
    }

    public init(@ViewBuilder unauthenticated: @escaping () -> Unauthenticated, @ViewBuilder content: @escaping () -> Content) {
    self.unauthenticated = unauthenticated()
    self.content = content
    }


    var body: some View {
        ZStack {
            switch viewModel.authenticationState {
            case .unauthenticated, .authenticating:
                unauthenticatedScreen
                    .transition(.opacity)
            case .authenticated:
                authenticatedScreen
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .animation(.easeInOut(duration: 0.45), value: viewModel.authenticationState)
    }

    private var unauthenticatedScreen: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            // Overlay keeps the extra-wide wall from stretching the layout
            Color.clear
                .overlay(alignment: .topLeading) { PosterWall() }
                .clipped()
                .ignoresSafeArea()
            LinearGradient(
                colors: [Theme.background.opacity(0.35), Theme.background.opacity(0.85), Theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                if let unauthenticated {
                    unauthenticated
                } else {
                    Text("Oops! You're not logged in.")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                }
                Spacer()
                Button("Get Started") {
                    Haptics.tap()
                    viewModel.reset()
                    presentingLoginScreen.toggle()
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
                .appearAnimation(delay: 0.35)
            }
        }
        .sheet(isPresented: $presentingLoginScreen) {
            SignInView()
                .environmentObject(viewModel)
        }
    }

    private var authenticatedScreen: some View {
        content()
            .environmentObject(viewModel)
            .overlay(alignment: .bottom) {
                if isVisible {
                    Button {
                        presentingProfileScreen.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Theme.accentGradient)
                            Text("Signed in as \(viewModel.displayName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                withAnimation(Theme.spring.delay(0.4)) {
                    isVisible = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    withAnimation(Theme.spring) {
                        isVisible = false
                    }
                }
            }
            .sheet(isPresented: $presentingProfileScreen) {
                UserProfileView()
                    .environmentObject(viewModel)
            }
    }
}

// MARK: - Poster wall

/// Rows of posters drifting slowly across the welcome screen.
private struct PosterWall: View {
    private let posters = [
        "/wjOHjWCUE0YzDiEzKv8AfqHj3ir.jpg",
        "/7sfbEnaARXDDhKm0CZ7D7uc2sbo.jpg",
        "/oOleziEempUPu96jkGs0Pj6tKxj.jpg",
    ]
    private let posterWidth: CGFloat = 110
    private let spacing: CGFloat = 12

    @State private var drift = false

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<5, id: \.self) { row in
                posterRow(offsetBy: row)
            }
        }
        .rotationEffect(.degrees(-8))
        .scaleEffect(1.25)
        .opacity(0.55)
        .onAppear {
            withAnimation(.linear(duration: 40).repeatForever(autoreverses: false)) {
                drift = true
            }
        }
    }

    private func posterRow(offsetBy row: Int) -> some View {
        // Each row holds the poster set twice so the loop is seamless
        let order = (0..<posters.count * 4).map { posters[($0 + row) % posters.count] }
        let loopWidth = CGFloat(posters.count * 2) * (posterWidth + spacing)
        let direction: CGFloat = row.isMultiple(of: 2) ? -1 : 1
        return HStack(spacing: spacing) {
            ForEach(Array(order.enumerated()), id: \.offset) { _, path in
                PosterImage(path: path, cornerRadius: 10)
                    .frame(width: posterWidth, height: posterWidth * 1.5)
            }
        }
        .offset(x: (drift ? loopWidth * direction : 0) - (direction > 0 ? loopWidth : 0))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AuthenticatedView_Previews: PreviewProvider {
  static var previews: some View {
    AuthenticatedView {
      Text("You're signed in.")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(.yellow)
    }
  }
}
