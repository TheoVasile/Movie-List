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

    static func posterURL(_ path: String?, size: PosterSize = .large) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)" + path)
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

/// TMDb poster widths. Ask for the smallest one that stays sharp at the size it's drawn,
/// since every extra pixel has to be downloaded and decoded
enum PosterSize: String {
    case small = "w185"   // list rows, thumbnails, blurred backdrops
    case medium = "w342"  // grids and cards around a third of the screen wide
    case large = "w500"   // half-screen posters
    case xlarge = "w780"  // full-width posters
}

/// Downloads each poster once and keeps the decoded image in memory, so a row that scrolls
/// back into view shows its poster immediately instead of loading it again
actor PosterLoader {
    static let shared = PosterLoader()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()
    // Rows showing the same poster share one download
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    // NSCache is thread-safe, so views can check it synchronously while rendering
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cachedImage(for: url) {
            return image
        }
        if let task = inFlight[url] {
            return await task.value
        }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return nil }
            // Decode now, off the main thread, rather than on the first frame it's drawn
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image, let cgImage = image.cgImage {
            cache.setObject(image, forKey: url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
        }
        return image
    }
}

/// Fills whatever frame it is given with a poster, fading it in once loaded.
struct PosterImage: View {
    let path: String?
    var cornerRadius: CGFloat = 12
    var size: PosterSize = .large

    // Remembers which URL the image belongs to, so a reused view never shows another film's poster
    @State private var loaded: (url: URL, image: UIImage)? = nil
    @State private var failedURL: URL? = nil

    private var url: URL? { Theme.posterURL(path, size: size) }

    private var image: UIImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return PosterLoader.shared.cachedImage(for: url)
    }

    var body: some View {
        Rectangle()
            .fill(Theme.surfaceRaised)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if url == nil || failedURL == url {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundColor(Theme.textTertiary)
                } else {
                    Shimmer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .task(id: url) {
                guard let url, PosterLoader.shared.cachedImage(for: url) == nil else { return }
                let image = await PosterLoader.shared.image(for: url)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    if let image {
                        loaded = (url, image)
                    } else {
                        failedURL = url
                    }
                }
            }
    }
}

/// A heavily blurred poster used as an ambient backdrop behind headers.
struct PosterBackdrop: View {
    let path: String?

    var body: some View {
        GeometryReader { proxy in
            // Blurred this heavily, the smallest poster looks the same and is far cheaper to draw
            PosterImage(path: path, cornerRadius: 0, size: .small)
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
