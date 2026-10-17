//
//  Theme.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Palette

enum Theme {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.07)
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.14)
    static let surfaceRaised = Color(red: 0.15, green: 0.15, blue: 0.20)
    static let stroke = Color.white.opacity(0.08)

    // Marquee gold fading into a cinema-seat red
    static let accent = Color(red: 0.98, green: 0.76, blue: 0.27)
    static let accentSecondary = Color(red: 0.93, green: 0.29, blue: 0.36)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    static let accentGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)

    static func posterURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://media.themoviedb.org/t/p/w600_and_h900_bestv2" + path)
    }

    static func year(from date: Date?) -> String {
        guard let date else { return "" }
        return String(Calendar.current.component(.year, from: date))
    }

    // TMDb search results return release dates as "yyyy-MM-dd"
    static func year(from releaseDate: String) -> String {
        String(releaseDate.prefix(4))
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func select() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Posters

/// Fills whatever frame it is given with a poster, fading it in once loaded.
struct PosterImage: View {
    let path: String?
    var cornerRadius: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(Theme.surfaceRaised)
            .overlay {
                AsyncImage(url: Theme.posterURL(path), transaction: Transaction(animation: .easeOut(duration: 0.4))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    case .failure:
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundColor(Theme.textTertiary)
                    default:
                        if path?.isEmpty == false {
                            Shimmer()
                        } else {
                            Image(systemName: "film")
                                .font(.title2)
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

/// A heavily blurred poster used as an ambient backdrop behind headers.
struct PosterBackdrop: View {
    let path: String?

    var body: some View {
        GeometryReader { proxy in
            PosterImage(path: path, cornerRadius: 0)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .blur(radius: 40)
                .saturation(1.3)
                .opacity(0.7)
                .overlay(
                    LinearGradient(
                        colors: [Theme.background.opacity(0.1), Theme.background.opacity(0.75), Theme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .clipped()
    }
}

struct Shimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.08), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.8)
            .offset(x: phase * proxy.size.width * 1.4)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Buttons

/// Gives any button a soft spring "press" without changing how it looks.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.accentGradient)
            .clipShape(Capsule())
            .shadow(color: Theme.accentSecondary.opacity(0.35), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.surfaceRaised)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Building blocks

struct MetaChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @State private var float = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 96, height: 96)
                    .blur(radius: 30)
                    .opacity(0.5)
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
            }
            .offset(y: float ? -6 : 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    float = true
                }
            }
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 240)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Appear animation

private struct AppearModifier: ViewModifier {
    let delay: Double
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 18)
            .onAppear {
                withAnimation(Theme.spring.delay(delay)) {
                    visible = true
                }
            }
    }
}

extension View {
    /// Fades and lifts a view into place the first time it appears.
    func appearAnimation(delay: Double = 0) -> some View {
        modifier(AppearModifier(delay: delay))
    }

    func cardStyle(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}
