//
//  DiscoverReactionsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-22.
//

import Foundation
import SwiftUI
import Combine

/// What Discover keeps on this device about the user's likes and dislikes, and the news of changes to them. The likes
/// and dislikes themselves are the account's (see DiscoverReactionSync)
final class DiscoverReactions {
    static let shared = DiscoverReactions()

    // A like or dislike was changed outside the deck: the film's id, or nil when any of them may have been
    let changed = PassthroughSubject<Int64?, Never>()
    // The server turned down a rating for good
    let rejected = PassthroughSubject<Int64, Never>()
    // A rating couldn't be sent yet, so it's waiting on this device
    let delayed = PassthroughSubject<Void, Never>()
    // Everything here is about to be cleared, because its account signed out
    let cleared = PassthroughSubject<Void, Never>()

    // Whether the user has seen what swiping does, since earlier builds' swipes did something else
    static let gesturesSeenKey = "discoverGesturesSeen"
    // Earlier builds kept the liked and disliked films themselves here
    private static let oldHistoryKeys = ["discover.likedFilms", "discover.dislikedFilms"]
    /// Everything Discover keeps on this device for the account
    static let deviceKeys = [
        DiscoverViewModel.profileKey, DiscoverViewModel.likedKey, DiscoverViewModel.dislikedKey, DiscoverViewModel.deckKey,
        DiscoverViewModel.genreFilterKey, DiscoverViewModel.filtersKey, DiscoverViewModel.kindKey, "discover.passedMovieIDs",
        // Recent searches from Discover's search field, so the next account to sign in doesn't see them
        FilmSearchModel.recentKey,
    ] + oldHistoryKeys

    private init() {}

    static var savedProfile: TasteProfile {
        UserDefaults.standard.data(forKey: DiscoverViewModel.profileKey)
            .flatMap { try? JSONDecoder().decode(TasteProfile.self, from: $0) } ?? TasteProfile()
    }

    static func save(_ profile: TasteProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: DiscoverViewModel.profileKey)
        }
    }

    /// Changes what this device knows of a film's rating, and what was learned from it, after the account's changed.
    /// Taking a rating back (nil) lets the film come back in Discover. movie is nil when its details aren't known
    func apply(_ id: Int64, movie: Movie?, from old: DiscoverReaction?, to new: DiscoverReaction?) {
        let defaults = UserDefaults.standard
        for (key, reaction, limit) in [(DiscoverViewModel.likedKey, DiscoverReaction.liked, DiscoverViewModel.likedLimit),
                                       (DiscoverViewModel.dislikedKey, .disliked, DiscoverViewModel.dislikedLimit)] {
            var ids = RecentIDs(defaults.array(forKey: key) as? [Int] ?? [], limit: limit)
            ids.remove(id)
            if new == reaction { ids.insert(id) }
            defaults.set(ids.stored, forKey: key)
        }
        if let movie {
            var profile = Self.savedProfile
            if let old { profile.forget(movie, old) }
            if let new { profile.record(movie, new) }
            Self.save(profile)
        }
        changed.send(id)
    }

    // MARK: Earlier builds

    private struct OldEntry: Decodable {
        let movie: Movie
        let date: Date
    }

    /// When films were liked or disliked, as earlier builds kept it, for uploading them to the account
    static func oldHistoryDates() -> [Int64: Date] {
        var dates: [Int64: Date] = [:]
        for key in oldHistoryKeys {
            let entries = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([OldEntry].self, from: $0) } ?? []
            for entry in entries { dates[entry.movie.id] = entry.date }
        }
        return dates
    }

    /// Once they're with the account, the films earlier builds kept aren't needed
    static func forgetOldHistory() {
        for key in oldHistoryKeys { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// The account's likes and dislikes, loaded from the server a page at a time
private final class DiscoverHistory: ObservableObject {
    struct Entry: Identifiable {
        let id: Int64
        // nil when the film's details couldn't be loaded; it can still be removed
        let movie: Movie?
        let date: Date?
    }

    struct Segment {
        var entries: [Entry] = []
        var cursor: String? = nil
        var isLoaded = false
        var isLoading = false
        var failed = false
    }

    @Published private(set) var liked = Segment()
    @Published private(set) var disliked = Segment()
    @Published private(set) var counts: (liked: Int, disliked: Int)? = nil
    // Films whose change is being saved
    @Published private(set) var changing: Set<Int64> = []
    // Some recent ratings are still on their way to the account, so they're missing here
    @Published private(set) var isBehind = false
    // Bumped when a segment starts over, so an older answer is ignored
    private var generations: [DiscoverReaction: Int] = [:]

    subscript(reaction: DiscoverReaction) -> Segment {
        reaction == .liked ? liked : disliked
    }

    private func update(_ reaction: DiscoverReaction, _ change: (inout Segment) -> Void) {
        if reaction == .liked { change(&liked) } else { change(&disliked) }
    }

    /// Loads the first page, or tries it again
    func load(_ reaction: DiscoverReaction) {
        guard !self[reaction].isLoading else { return }
        update(reaction) {
            $0 = Segment()
            $0.isLoading = true
        }
        // Ratings still waiting go first, so they're included
        DiscoverReactionSync.shared.flush { allSent in
            self.isBehind = !allSent && DiscoverReactionSync.shared.hasPending
            self.fetch(reaction)
        }
    }

    func loadMore(_ reaction: DiscoverReaction) {
        let segment = self[reaction]
        guard segment.isLoaded, !segment.isLoading, segment.cursor != nil else { return }
        update(reaction) {
            $0.isLoading = true
            $0.failed = false
        }
        fetch(reaction)
    }

    private func fetch(_ reaction: DiscoverReaction) {
        let generation = (generations[reaction] ?? 0) + 1
        generations[reaction] = generation
        APIService.shared.fetchDiscoverHistory(reaction: DiscoverReactionSync.name(reaction), cursor: self[reaction].cursor) { result in
            guard self.generations[reaction] == generation else { return }
            switch result {
            case .success(let page):
                self.counts = (page.counts.like, page.counts.dislike)
                self.update(reaction) { segment in
                    segment.isLoading = false
                    segment.isLoaded = true
                    segment.cursor = page.next_cursor
                    let known = Set(segment.entries.map(\.id))
                    segment.entries += page.items.filter { !known.contains($0.tmdb_id) }.map {
                        Entry(id: $0.tmdb_id, movie: $0.movie, date: Self.date($0.reacted_at))
                    }
                }
            case .failure:
                self.update(reaction) {
                    $0.isLoading = false
                    $0.failed = true
                }
            }
        }
    }

    /// Changes a film's rating, or takes it back when nil. Its row stays, marked as saving, until that's saved; calls
    /// back with whether it was
    func change(_ entry: Entry, from old: DiscoverReaction, to new: DiscoverReaction?, completion: @escaping (Bool) -> Void) {
        guard !changing.contains(entry.id) else { return }
        changing.insert(entry.id)
        DiscoverReactionSync.shared.change(entry.id, to: new) { saved in
            withAnimation(Theme.spring) {
                self.changing.remove(entry.id)
                if saved { self.move(entry, from: old, to: new) }
            }
            if saved { DiscoverReactions.shared.apply(entry.id, movie: entry.movie, from: old, to: new) }
            completion(saved)
        }
    }

    private func move(_ entry: Entry, from old: DiscoverReaction, to new: DiscoverReaction?) {
        update(old) { $0.entries.removeAll { $0.id == entry.id } }
        if let new {
            update(new) {
                if $0.isLoaded { $0.entries.insert(Entry(id: entry.id, movie: entry.movie, date: Date()), at: 0) }
            }
        }
        guard var counts else { return }
        if old == .liked { counts.liked = max(counts.liked - 1, 0) } else { counts.disliked = max(counts.disliked - 1, 0) }
        if new == .liked { counts.liked += 1 } else if new == .disliked { counts.disliked += 1 }
        self.counts = counts
        // The rest may be on pages that haven't been loaded
        if self[old].entries.isEmpty { loadMore(old) }
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ string: String) -> Date? {
        formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// The films the user liked or marked Not for Me in Discover, newest first, which only they can see. Tapping one
/// shows its info, where it can be added to lists; its ⋮ changes or takes back the rating
struct DiscoverReactionsView: View {
    @StateObject private var history = DiscoverHistory()
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @State private var showing = DiscoverReaction.liked
    @State private var details: CDMovie? = nil
    @State private var detailsMovie: Movie? = nil
    @State private var adding: Movie? = nil
    @State private var toast: String? = nil

    private var segment: DiscoverHistory.Segment { history[showing] }

    private var isFirstLoad: Bool { !segment.isLoaded && !segment.failed }

    var body: some View {
        List {
            Picker("Show", selection: $showing) {
                Text(title("Liked", history.counts?.liked)).tag(DiscoverReaction.liked)
                Text(title("Not for Me", history.counts?.disliked)).tag(DiscoverReaction.disliked)
            }
            .pickerStyle(.segmented)
            .disabled(isFirstLoad)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if history.isBehind {
                Label("Some recent ratings haven't synced yet", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) { toastView }
        .navigationTitle("Liked & Not for Me")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !segment.isLoaded { history.load(showing) }
        }
        .onChange(of: showing) { reaction in
            if !history[reaction].isLoaded { history.load(reaction) }
        }
        .sheet(item: $details) { preview in
            // Add to Lists closes the info screen and asks which lists
            MovieDetailView(movie: preview, onAddToLists: {
                let movie = detailsMovie
                details = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { adding = movie }
            })
        }
        // The standard add flow: list picker, then Compare in each ranked list, with a spinner while it saves. Adding
        // doesn't change the rating
        .addToListFlow(movie: $adding, source: .discover)
    }

    private func title(_ name: String, _ count: Int?) -> String {
        count.map { "\(name) (\($0))" } ?? name
    }

    @ViewBuilder
    private var content: some View {
        if isFirstLoad {
            ForEach(0..<6, id: \.self) { _ in placeholderRow }
        } else if !segment.isLoaded {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "Couldn't load your films",
                message: "Check your connection and try again.",
                actionTitle: "Try Again"
            ) {
                history.load(showing)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if segment.entries.isEmpty && segment.cursor == nil {
            Text(showing == .liked
                 ? "Films you like in Discover, by swiping right or tapping Like, show up here, and Discover recommends more like them."
                 : "Films you mark Not for Me in Discover, by swiping left or tapping Not for Me, show up here, and Discover shows fewer like them.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(segment.entries) { entry in
                    row(entry)
                        .swipeActions(edge: .trailing) {
                            if !history.changing.contains(entry.id) { removeButton(entry) }
                        }
                }
                moreRow
            } footer: {
                Text("Only you can see these. They shape what Discover recommends and where new films start in your lists. Removing one lets it come back in Discover; films stay in your lists either way.")
                    .font(.caption)
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    // Loads the next page when it comes on screen
    @ViewBuilder
    private var moreRow: some View {
        if segment.cursor != nil {
            Group {
                if segment.failed {
                    Button("Couldn't load more. Try Again") {
                        Haptics.tap()
                        history.loadMore(showing)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(Theme.accent)
                } else {
                    ProgressView()
                        .tint(Theme.accent)
                        // A new one for each page, so it appears again if it never left the screen
                        .id(segment.cursor)
                        .onAppear { history.loadMore(showing) }
                        .accessibilityLabel("Loading more films")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var placeholderRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.surface)
                .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 6)))
                .frame(width: 44, height: 66)
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.surface)
                .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 6)))
                .frame(height: 16)
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    private func change(_ entry: DiscoverHistory.Entry, to reaction: DiscoverReaction?) {
        Haptics.tap()
        history.change(entry, from: showing, to: reaction) { saved in
            if !saved { showToast("Couldn't save that. Check your connection.") }
        }
    }

    private func removeButton(_ entry: DiscoverHistory.Entry) -> some View {
        Button(role: .destructive) {
            change(entry, to: nil)
        } label: {
            Label("Remove", systemImage: "arrow.uturn.backward")
        }
    }

    private func row(_ entry: DiscoverHistory.Entry) -> some View {
        let isChanging = history.changing.contains(entry.id)
        return HStack(spacing: 0) {
            filmButton(entry)
            if isChanging {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(width: 36, height: 44)
                    .accessibilityLabel("Saving")
            } else {
                Menu {
                    Button {
                        change(entry, to: showing == .liked ? .disliked : .liked)
                    } label: {
                        if showing == .liked {
                            Label("Change to Not for Me", systemImage: "hand.thumbsdown")
                        } else {
                            Label("Change to Like", systemImage: "heart")
                        }
                    }
                    if let movie = entry.movie {
                        Button {
                            Haptics.tap()
                            adding = movie
                        } label: {
                            Label("Add to Lists", systemImage: "text.badge.plus")
                        }
                    }
                    removeButton(entry)
                } label: {
                    MoreActionsLabel()
                }
                .accessibilityLabel("\(entry.movie?.title ?? "Film") Options")
            }
        }
        .disabled(isChanging)
        .opacity(isChanging ? 0.5 : 1)
        .listRowBackground(Color.clear)
    }

    private func filmButton(_ entry: DiscoverHistory.Entry) -> some View {
        Button {
            guard let movie = entry.movie else { return }
            Haptics.tap()
            detailsMovie = movie
            details = PersistenceController.preview(of: movie)
        } label: {
            HStack(spacing: 12) {
                PosterImage(path: entry.movie?.poster_path, cornerRadius: 6, size: .small)
                    .frame(width: 44, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.movie?.title ?? "Couldn't load film")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(entry.movie == nil ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(2)
                    if let movie = entry.movie {
                        HStack(spacing: 4) {
                            if movie.isTV {
                                TVBadge()
                            }
                            Text(Theme.year(from: movie.release_date))
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    if let date = entry.date {
                        Text("\(showing == .liked ? "Liked" : "Marked") \(date.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: showing == .liked ? "heart.fill" : "hand.thumbsdown.fill")
                    .foregroundStyle(showing == .liked ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        // Borderless, so tapping the ⋮ beside it doesn't also open the film
        .buttonStyle(.borderless)
        .disabled(entry.movie == nil)
    }

    private func showToast(_ message: String) {
        withAnimation(Theme.spring) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(Theme.spring) {
                if toast == message { toast = nil }
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: Theme.shadow.opacity(0.4), radius: 16, y: 8)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
