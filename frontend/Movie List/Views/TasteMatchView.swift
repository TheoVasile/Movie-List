//
//  TasteMatchView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-28.
//

import Foundation
import SwiftUI
import UIKit

extension Notification.Name {
    /// Asks the app to switch to the Discover tab, e.g. from Taste Match's "rank a few more films"
    static let openDiscoverTab = Notification.Name("openDiscoverTab")
}

/// Taste Match: "You and @alex are 87% film-compatible". The score is worked out on the server from the user's ranked
/// lists and the ones the other person lets them see (GET /users/:handle/taste-match), then shown as a card that
/// reveals the percentage and can be shared as a story-sized or square image
struct TasteMatchView: View {
    let handle: String
    // A link to go with the shared card (their profile, or an invite), added after the image and text when there is one
    var shareURL: URL? = nil

    @State private var match: TasteMatch? = nil
    @State private var failed = false
    // Profile pictures and posters, downloaded before the card is shown so the shared image has them too
    @State private var avatars: TasteMatchCard.Avatars = .init()
    @State private var posters: [String: UIImage] = [:]
    @State private var format = TasteMatchCard.Format.story
    @State private var revealed = false
    @State private var rendering = false
    @State private var shareItem: ShareItem? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let match, match.enough {
                matchContent(match)
            } else if let match {
                notEnough(match)
            } else if failed {
                VStack(spacing: 14) {
                    Text("Couldn't load your Taste Match.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                    Button("Try Again", action: load)
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Nothing to tap until it's loaded
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Comparing your rankings…")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Taste Match")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in
            ShareSheet(item: item)
                .presentationDetents([.medium, .large])
        }
        .onAppear { if match == nil { load() } }
    }

    // MARK: States

    private func matchContent(_ match: TasteMatch) -> some View {
        VStack(spacing: 16) {
            Picker("Card size", selection: $format) {
                Text("Story").tag(TasteMatchCard.Format.story)
                Text("Square").tag(TasteMatchCard.Format.square)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            GeometryReader { proxy in
                let size = format.size
                let scale = min(proxy.size.width / size.width, proxy.size.height / size.height, 1.2)
                card(match, progress: revealed ? 1 : 0)
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .shadow(color: Theme.shadow.opacity(0.25), radius: 18, y: 8)
            }
            .padding(.horizontal, 16)

            Button(action: { share(match) }) {
                HStack(spacing: 8) {
                    if rendering {
                        ProgressView().tint(Theme.onAccent)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text("Share")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(rendering)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .padding(.top, 8)
        .onAppear {
            // Counts the percentage up and fills the ring once the card is on screen
            guard !revealed else { return }
            withAnimation(.easeOut(duration: 1.6).delay(0.25)) { revealed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) { Haptics.success() }
        }
    }

    private func notEnough(_ match: TasteMatch) -> some View {
        let theirName = "@\(match.them.handle ?? handle)"
        let theyNeedMore = match.needs == "them"
        return VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Theme.textPrimary.opacity(0.12), lineWidth: 8)
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.accentGradient)
            }
            .frame(width: 110, height: 110)
            .accessibilityHidden(true)
            Text(theyNeedMore ? "\(theirName) hasn't ranked enough films yet" : "Rank a few more films to unlock your Taste Match")
                .font(.title3.weight(.heavy))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(theyNeedMore
                 ? "Taste Match only uses lists \(theirName) lets you see. Once they've ranked a few more, check back."
                 : "Taste Match compares how you and \(theirName) rank films. Add a few more films to a ranked list and come back.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if !theyNeedMore {
                Button {
                    Haptics.tap()
                    NotificationCenter.default.post(name: .openDiscoverTab, object: nil)
                    dismiss()
                } label: {
                    Label("Find Films to Rank", systemImage: "rectangle.on.rectangle.angled")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ match: TasteMatch, progress: Double) -> TasteMatchCard {
        TasteMatchCard(match: match, format: format, avatars: avatars, posters: posters, progress: progress)
    }

    // MARK: Loading

    private func load() {
        failed = false
        APIService.shared.fetchTasteMatch(handle) { result in
            switch result {
            case .success(let loaded):
                Task { @MainActor in
                    await loadImages(loaded)
                    match = loaded
                    AppAnalytics.log(.tasteMatchViewed(band: Self.band(loaded)))
                }
            case .failure:
                failed = true
            }
        }
    }

    /// The images the card shows, since a rendered image can't wait for them to download
    @MainActor
    private func loadImages(_ match: TasteMatch) async {
        if let version = match.me.avatar_version {
            avatars.me = await AvatarStore.shared.image(handle: nil, version: version)
        }
        if let version = match.them.avatar_version {
            avatars.them = await AvatarStore.shared.image(handle: match.them.handle ?? handle, version: version)
        }
        let paths = ((match.both_love ?? []) + (match.fight_over ?? [])).compactMap(\.poster_path)
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for path in Set(paths) {
                group.addTask {
                    guard let url = Theme.posterURL(path, size: .medium) else { return (path, nil) }
                    return (path, await PosterLoader.shared.image(for: url))
                }
            }
            for await (path, image) in group {
                if let image { posters[path] = image }
            }
        }
    }

    // A band rather than the score, for analytics
    private static func band(_ match: TasteMatch) -> String {
        guard match.enough, let score = match.score else { return "not_enough" }
        switch score {
        case 90...: return "90+"
        case 75..<90: return "75-89"
        case 50..<75: return "50-74"
        default: return "0-49"
        }
    }

    // MARK: Sharing

    private func share(_ match: TasteMatch) {
        guard !rendering else { return }
        Haptics.tap()
        rendering = true
        let format = format
        Task { @MainActor in
            let renderer = ImageRenderer(content: card(match, progress: 1)
                .environment(\.colorScheme, colorScheme))
            renderer.scale = 3
            rendering = false
            guard let image = renderer.uiImage else { return }
            var items: [Any] = [image, Self.shareText(match)]
            if let shareURL { items.append(shareURL) }
            AppAnalytics.log(.tasteMatchShared(format: format.rawValue))
            shareItem = ShareItem(items: items, kind: .tasteMatch)
        }
    }

    static func shareText(_ match: TasteMatch) -> String {
        let theirName = match.them.handle.map { "@\($0)" } ?? match.them.display_name
        let score = match.score ?? 0
        return "\(theirName) and I are \(score)% film-compatible on Marquee (\(match.tier ?? TasteMatchCard.tier(score))). Find your taste match!"
    }
}

// MARK: - The card

/// The shareable Taste Match card, in Marquee's style. progress (0...1) is how far the percentage has counted up and
/// the ring filled, for the reveal; it's 1 when the card is rendered for sharing
struct TasteMatchCard: View {
    enum Format: String {
        case story, square

        var size: CGSize {
            switch self {
            case .story: return CGSize(width: 360, height: 640)
            case .square: return CGSize(width: 360, height: 360)
            }
        }
    }

    struct Avatars {
        var me: UIImage? = nil
        var them: UIImage? = nil
    }

    let match: TasteMatch
    let format: Format
    let avatars: Avatars
    let posters: [String: UIImage]
    var progress: Double = 1

    private var score: Int { match.score ?? 0 }
    private var myName: String { match.me.handle.map { "@\($0)" } ?? match.me.display_name }
    private var theirName: String { match.them.handle.map { "@\($0)" } ?? match.them.display_name }
    private var isStory: Bool { format == .story }

    /// The label for a score, as the server words it
    static func tier(_ score: Int) -> String {
        switch score {
        case 90...: return "Cinematic soulmates"
        case 75..<90: return "Same wavelength"
        case 50..<75: return "Friendly rivals"
        default: return "Opposites attract"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("TASTE MATCH")
                .font(.caption.weight(.heavy))
                .tracking(2)
                .foregroundStyle(Theme.accentGradient)
            people
            ring
            VStack(spacing: 4) {
                Text(match.tier ?? Self.tier(score))
                    .font(.system(size: isStory ? 26 : 20, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if isStory, let genre = match.top_genre {
                    Label("You both go for \(genre)", systemImage: "theatermasks.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            if isStory {
                bothLove
                fightOver
            }
            Spacer(minLength: 0)
            ShareCardFooter()
        }
        .padding(isStory ? 20 : 16)
        .frame(width: format.size.width, height: format.size.height)
        .background(
            ZStack {
                Theme.surface
                LinearGradient(colors: [Theme.accent.opacity(0.30), .clear], startPoint: .top, endPoint: .center)
                LinearGradient(colors: [.clear, Theme.accentSecondary.opacity(0.16)], startPoint: .center, endPoint: .bottom)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TasteMatchView.shareText(match))
    }

    private var people: some View {
        VStack(spacing: 6) {
            HStack(spacing: -12) {
                avatar(avatars.me, name: match.me.display_name)
                avatar(avatars.them, name: match.them.display_name)
            }
            Text("\(myName) & \(theirName)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func avatar(_ image: UIImage?, name: String) -> some View {
        let size: CGFloat = isStory ? 48 : 40
        return Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(name.first ?? "?").uppercased())
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.accentGradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.surface, lineWidth: 3))
    }

    private var ring: some View {
        let size: CGFloat = isStory ? 136 : 116
        let fraction = Double(score) / 100 * progress
        return ZStack {
            Circle()
                .stroke(Theme.textPrimary.opacity(0.10), lineWidth: isStory ? 12 : 10)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: isStory ? 12 : 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                CountingPercent(value: Double(score) * progress)
                    .font(.system(size: isStory ? 44 : 36, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                Text("film-compatible")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var bothLove: some View {
        if let films = match.both_love, !films.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("You both love", icon: "heart.fill")
                HStack(alignment: .top, spacing: 10) {
                    ForEach(films) { film in
                        VStack(spacing: 4) {
                            poster(film.poster_path, width: 54)
                            Text(film.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        .frame(width: 92)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var fightOver: some View {
        if let films = match.fight_over, !films.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("You fight over", icon: "bolt.fill")
                ForEach(films) { film in
                    HStack(spacing: 10) {
                        poster(film.poster_path, width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(film.title)
                                .font(.caption.weight(.bold))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            Text("#\(film.my_rank) for \(myName) · #\(film.their_rank) for \(theirName)")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title.uppercased(), systemImage: icon)
            .font(.caption2.weight(.heavy))
            .tracking(1)
            .foregroundStyle(Theme.accentGradient)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func poster(_ path: String?, width: CGFloat) -> some View {
        ZStack {
            Theme.surfaceRaised
            if let path, let image = posters[path] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width > 40 ? 8 : 5, style: .continuous))
    }
}

/// A percentage that counts up as it animates
private struct CountingPercent: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))%")
            .monospacedDigit()
    }
}
