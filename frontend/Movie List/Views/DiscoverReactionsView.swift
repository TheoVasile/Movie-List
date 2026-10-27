//
//  DiscoverReactionsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-22.
//

import Foundation
import SwiftUI
import Combine

/// Films the user liked (added to a list from Discover, or liked with the heart in earlier builds) or disliked (Not
/// for Me) in Discover, newest first. Kept on this device, like the rest of what Discover learns
final class DiscoverReactions: ObservableObject {
    static let shared = DiscoverReactions()

    struct Entry: Codable, Identifiable {
        let movie: Movie
        let date: Date
        var id: Int64 { movie.id }
    }

    @Published private(set) var liked: [Entry]
    @Published private(set) var disliked: [Entry]
    // Sent when a like or dislike is taken back here, so Discover can let the film come back
    let changed = PassthroughSubject<Void, Never>()

    private static let likedKey = "discover.likedFilms"
    private static let dislikedKey = "discover.dislikedFilms"

    private init() {
        liked = Self.load(Self.likedKey)
        disliked = Self.load(Self.dislikedKey)
    }

    // The most recent of each kept, so the history stays a reasonable size
    private static let limit = 500

    func add(_ movie: Movie, liked isLiked: Bool) {
        remove(movie.id)
        let entry = Entry(movie: movie, date: Date())
        if isLiked {
            liked = Array(([entry] + liked).prefix(Self.limit))
        } else {
            disliked = Array(([entry] + disliked).prefix(Self.limit))
        }
        save()
    }

    /// Takes the film off either list, without changing what Discover learned
    func remove(_ id: Int64) {
        liked.removeAll { $0.id == id }
        disliked.removeAll { $0.id == id }
        save()
    }

    func clear() {
        liked = []
        disliked = []
        save()
    }

    /// Takes back a like or dislike: Discover forgets what it learned from it and may show the film again
    func forget(_ entry: Entry, liked isLiked: Bool) {
        remove(entry.id)
        let defaults = UserDefaults.standard
        let key = isLiked ? DiscoverViewModel.likedKey : DiscoverViewModel.dislikedKey
        let ids = (defaults.array(forKey: key) as? [Int] ?? []).filter { $0 != Int(entry.id) }
        defaults.set(ids, forKey: key)
        if var profile = defaults.data(forKey: DiscoverViewModel.profileKey).flatMap({ try? JSONDecoder().decode(TasteProfile.self, from: $0) }) {
            profile.forget(entry.movie, liked: isLiked)
            if let data = try? JSONEncoder().encode(profile) {
                defaults.set(data, forKey: DiscoverViewModel.profileKey)
            }
        }
        changed.send()
    }

    private static func load(_ key: String) -> [Entry] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(liked) { UserDefaults.standard.set(data, forKey: Self.likedKey) }
        if let data = try? JSONEncoder().encode(disliked) { UserDefaults.standard.set(data, forKey: Self.dislikedKey) }
    }
}

/// The films liked or disliked in Discover. Tapping one shows its info, where it can be added to lists;
/// swiping one away takes the like or dislike back
struct DiscoverReactionsView: View {
    @ObservedObject private var reactions = DiscoverReactions.shared
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @State private var showingLiked = true
    @State private var details: CDMovie? = nil
    @State private var detailsMovie: Movie? = nil
    @State private var adding: Movie? = nil

    private var entries: [DiscoverReactions.Entry] {
        showingLiked ? reactions.liked : reactions.disliked
    }

    var body: some View {
        List {
            Picker("Show", selection: $showingLiked) {
                Text("Liked (\(reactions.liked.count))").tag(true)
                Text("Not for Me (\(reactions.disliked.count))").tag(false)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if entries.isEmpty {
                Text(showingLiked
                     ? "Films you add to a list from Discover, by swiping right or tapping Add, show up here, and Discover recommends more like them."
                     : "Films you mark Not for Me in Discover show up here, and Discover shows fewer like them.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                            .swipeActions(edge: .trailing) {
                                forgetButton(entry)
                            }
                    }
                } footer: {
                    Text(showingLiked
                         ? "Discover recommends more films like these. Use ⋮ or swipe left on one to unlike it; it stays in your lists."
                         : "Discover shows fewer films like these. Use ⋮ or swipe left on one to let it come back.")
                        .font(.caption)
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Liked & Not for Me")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $details) { preview in
            // Add to Lists closes the info screen and asks which lists
            MovieDetailView(movie: preview, onAddToLists: {
                let movie = detailsMovie
                details = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { adding = movie }
            })
        }
        // The standard add flow: list picker, then Compare in each ranked list, with a spinner while it saves
        .addToListFlow(movie: $adding, source: .discover)
    }

    private func forgetButton(_ entry: DiscoverReactions.Entry) -> some View {
        Button(role: .destructive) {
            Haptics.tap()
            withAnimation(Theme.spring) { reactions.forget(entry, liked: showingLiked) }
        } label: {
            Label(showingLiked ? "Unlike" : "Remove", systemImage: showingLiked ? "heart.slash" : "arrow.uturn.backward")
        }
    }

    private func row(_ entry: DiscoverReactions.Entry) -> some View {
        HStack(spacing: 0) {
            filmButton(entry)
            Menu {
                forgetButton(entry)
            } label: {
                MoreActionsLabel()
            }
            .accessibilityLabel("\(entry.movie.title) Options")
        }
        .listRowBackground(Color.clear)
    }

    private func filmButton(_ entry: DiscoverReactions.Entry) -> some View {
        Button {
            Haptics.tap()
            detailsMovie = entry.movie
            details = PersistenceController.preview(of: entry.movie)
        } label: {
            HStack(spacing: 12) {
                PosterImage(path: entry.movie.poster_path, cornerRadius: 6, size: .small)
                    .frame(width: 44, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.movie.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if entry.movie.isTV {
                            TVBadge()
                        }
                        Text(Theme.year(from: entry.movie.release_date))
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    Text("\(showingLiked ? "Liked" : "Marked") \(entry.date.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: showingLiked ? "heart.fill" : "hand.thumbsdown.fill")
                    .foregroundStyle(showingLiked ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
            }
            .contentShape(Rectangle())
        }
        // Borderless, so tapping the ⋮ beside it doesn't also open the film
        .buttonStyle(.borderless)
    }
}
