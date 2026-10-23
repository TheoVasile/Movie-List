//
//  DiscoverReactionsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-22.
//

import Foundation
import SwiftUI
import Combine

/// Films the user liked with the heart or marked "Not for me" in Discover, newest first. Kept on this device,
/// like the rest of what Discover learns
final class DiscoverReactions: ObservableObject {
    static let shared = DiscoverReactions()

    struct Entry: Codable, Identifiable {
        let movie: Movie
        let date: Date
        var id: Int64 { movie.id }
    }

    @Published private(set) var liked: [Entry]
    @Published private(set) var disliked: [Entry]
    // Sent when a like or "not for me" is taken back here, so Discover can let the film come back
    let changed = PassthroughSubject<Void, Never>()

    private static let likedKey = "discover.likedFilms"
    private static let dislikedKey = "discover.dislikedFilms"

    private init() {
        liked = Self.load(Self.likedKey)
        disliked = Self.load(Self.dislikedKey)
    }

    func add(_ movie: Movie, liked isLiked: Bool) {
        remove(movie.id)
        let entry = Entry(movie: movie, date: Date())
        if isLiked { liked.insert(entry, at: 0) } else { disliked.insert(entry, at: 0) }
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

    /// Takes back a like or "not for me": Discover forgets what it learned from it and may show the film again
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

/// The films liked or marked "Not for me" in Discover. Tapping one shows its info, where it can be added to lists;
/// swiping one away takes the like or "not for me" back
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
                     ? "Tap the heart on a Discover card to like a film without adding it to a list. Discover will recommend more like it."
                     : "Films you mark \"Not for me\" in Discover show up here, and Discover shows fewer like them.")
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
                                Button(role: .destructive) {
                                    Haptics.tap()
                                    withAnimation(Theme.spring) { reactions.forget(entry, liked: showingLiked) }
                                } label: {
                                    Label(showingLiked ? "Unlike" : "Remove", systemImage: showingLiked ? "heart.slash" : "arrow.uturn.backward")
                                }
                            }
                    }
                } footer: {
                    Text(showingLiked
                         ? "Discover recommends more films like these. Swipe left on one to unlike it."
                         : "Discover shows fewer films like these. Swipe left on one to let it come back.")
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
        .sheet(item: $adding) { movie in
            ListPickerSheet(title: movie.title, posterPath: movie.poster_path) { lists in
                for chosen in lists {
                    chosen.addMovie(movie, context: context) { _ in }
                }
                if !lists.isEmpty { Haptics.success() }
            }
            .environmentObject(authViewModel)
            .environment(\.managedObjectContext, context)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func row(_ entry: DiscoverReactions.Entry) -> some View {
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
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}
