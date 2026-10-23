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
    // Dark: a cinema at night. Light: crisp white with blue accents. Pink (for a couple of accounts, see
    // ColorTheme): blush and hot pink by day, plum and neon pink by night
    static let background = Color(light: Color(red: 0.96, green: 0.97, blue: 1.0), dark: Color(red: 0.04, green: 0.04, blue: 0.07),
                                  pinkLight: Color(red: 1.0, green: 0.95, blue: 0.97), pinkDark: Color(red: 0.08, green: 0.03, blue: 0.07))
    static let surface = Color(light: .white, dark: Color(red: 0.10, green: 0.10, blue: 0.14),
                               pinkLight: .white, pinkDark: Color(red: 0.16, green: 0.08, blue: 0.14))
    static let surfaceRaised = Color(light: Color(red: 0.91, green: 0.94, blue: 0.99), dark: Color(red: 0.15, green: 0.15, blue: 0.20),
                                     pinkLight: Color(red: 0.99, green: 0.89, blue: 0.94), pinkDark: Color(red: 0.23, green: 0.11, blue: 0.20))
    static let stroke = Color(light: navy.opacity(0.10), dark: Color.white.opacity(0.08),
                              pinkLight: plum.opacity(0.10), pinkDark: Color.white.opacity(0.08))

    // Dark: marquee gold fading into a cinema-seat red. Light: royal blue fading into sky blue.
    // Pink: hot pink fading into bubblegum by day, neon pink fading into violet by night
    static let accent = Color(light: Color(red: 0.15, green: 0.39, blue: 0.92), dark: Color(red: 0.98, green: 0.76, blue: 0.27),
                              pinkLight: Color(red: 0.91, green: 0.18, blue: 0.53), pinkDark: Color(red: 1.0, green: 0.45, blue: 0.74))
    static let accentSecondary = Color(light: Color(red: 0.05, green: 0.65, blue: 0.91), dark: Color(red: 0.93, green: 0.29, blue: 0.36),
                                       pinkLight: Color(red: 0.98, green: 0.52, blue: 0.72), pinkDark: Color(red: 0.76, green: 0.36, blue: 0.96))
    static let textPrimary = Color(light: navy, dark: .white, pinkLight: plum, pinkDark: .white)
    static let textSecondary = Color(light: navy.opacity(0.62), dark: Color.white.opacity(0.62),
                                     pinkLight: plum.opacity(0.62), pinkDark: Color.white.opacity(0.62))
    static let textTertiary = Color(light: navy.opacity(0.40), dark: Color.white.opacity(0.38),
                                    pinkLight: plum.opacity(0.40), pinkDark: Color.white.opacity(0.38))
    // Text and icons drawn on top of the accent gradient
    static let onAccent = Color(light: .white, dark: .black)
    // Text drawn over a poster's dark gradient, which stays dark in both themes
    static let posterText = Color.white
    // Shadows are much softer on a light background
    static let shadow = Color(light: navy.opacity(0.35), dark: .black)
    // Dims the screen behind a pop-up
    static let scrim = Color(light: navy.opacity(0.35), dark: Color.black.opacity(0.6))

    private static let navy = Color(red: 0.04, green: 0.10, blue: 0.20)
    private static let plum = Color(red: 0.24, green: 0.05, blue: 0.17)

    // Whether the pink palette is in use. Read whenever a colour is drawn; set by AppearanceSettings
    nonisolated(unsafe) static var isPink = false

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

extension Color {
    /// A color that follows the current light or dark appearance
    init(light: Color, dark: Color) {
        self.init(UIColor { traits in
            UIColor(traits.userInterfaceStyle == .light ? light : dark)
        })
    }

    /// A colour that also has a version for the pink palette, chosen each time it's drawn
    init(light: Color, dark: Color, pinkLight: Color, pinkDark: Color) {
        self.init(UIColor { traits in
            let isLight = traits.userInterfaceStyle == .light
            return UIColor(Theme.isPink ? (isLight ? pinkLight : pinkDark) : (isLight ? light : dark))
        })
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
                colors: [.clear, Theme.textPrimary.opacity(0.08), .clear],
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
            .foregroundColor(Theme.onAccent)
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
            .foregroundColor(Theme.textPrimary)
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

/// Marks a TV show among films, wherever a title's year is shown
struct TVBadge: View {
    // On a poster it gets the same dark backing as MetaChip
    var onPoster = false

    var body: some View {
        Label("TV", systemImage: "tv")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.heavy))
            .foregroundColor(onPoster ? Theme.posterText : Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(onPoster ? Color.black.opacity(0.55) : Theme.accent.opacity(0.14))
            .clipShape(Capsule())
            .fixedSize()
            .accessibilityLabel("TV show")
    }
}

struct MetaChip: View {
    let icon: String
    let text: String
    // On a poster the chip can't rely on the theme's colours, since the poster behind it can be any
    // colour; it gets white text on a dark backing that reads over every poster in both themes
    var onPoster = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundColor(onPoster ? Theme.posterText : Theme.textPrimary.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(onPoster ? Color.black.opacity(0.55) : Theme.textPrimary.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(onPoster ? Color.white.opacity(0.18) : .clear, lineWidth: 1))
    }
}

/// Lays its views out in rows, left to right, starting a new row when the next one doesn't fit. Used for chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            // At most the row's width, so a view wider than that is cut off rather than spilling past the edge
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
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
                .foregroundColor(Theme.textPrimary)
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
