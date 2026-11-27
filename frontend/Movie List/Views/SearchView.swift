//
//  SearchView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-11-26.
//

import Foundation
import SwiftUI
import Combine

/// Searching for a film or TV show by title, from the search field in Discover. Each search waits for a short pause in typing, and a
/// newer one cancels the one before it. Recent searches are kept on this device only, and cleared with the rest of
/// Discover's data when the account signs out
@MainActor
final class FilmSearchModel: ObservableObject {
    // The results on screen and the search they're for
    @Published private(set) var results: [Movie] = []
    @Published private(set) var resultsQuery = ""
    // The search being waited on, while it loads
    @Published private(set) var loadingQuery: String? = nil
    // The search that couldn't be done, so it can be tried again
    @Published private(set) var failedQuery: String? = nil
    @Published private(set) var recent: [String] = []
    // Shown before anything is typed: films in theatres now
    @Published private(set) var suggestions: [Movie] = []
    @Published private(set) var suggestionsLoading = false
    @Published private(set) var suggestionsFailed = false

    /// Kept on this device, newest first. In DiscoverReactions.deviceKeys, so it goes when the account signs out
    nonisolated static let recentKey = "search.recentQueries"
    private static let recentLimit = 10
    // Long enough to skip the keystrokes of one word, short enough to feel live
    private static let debounce: UInt64 = 350_000_000

    private var task: Task<Void, Never>? = nil
    private var subscriptions = Set<AnyCancellable>()

    init() {
        recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        DiscoverReactions.shared.cleared
            .sink { [weak self] in self?.recent = [] }
            .store(in: &subscriptions)
    }

    static func clean(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Call whenever the search text changes. An empty search clears the results
    func update(_ text: String, immediately: Bool = false) {
        let query = Self.clean(text)
        task?.cancel()
        failedQuery = nil
        guard !query.isEmpty else {
            task = nil
            loadingQuery = nil
            results = []
            resultsQuery = ""
            return
        }
        // The same search is already showing
        if query == resultsQuery && !immediately {
            loadingQuery = nil
            return
        }
        loadingQuery = query
        task = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: Self.debounce)
            }
            guard !Task.isCancelled else { return }
            do {
                let movies = try await APIService.shared.searchTitles(query)
                guard !Task.isCancelled, let self else { return }
                self.results = movies
                self.resultsQuery = query
                self.loadingQuery = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.loadingQuery = nil
                self.failedQuery = query
            }
        }
    }

    func retry() {
        guard let failedQuery else { return }
        update(failedQuery, immediately: true)
    }

    /// Keeps a search the user went with (pressed Search, or acted on one of its results) at the top of the recent ones
    func remember(_ text: String) {
        let query = Self.clean(text)
        guard !query.isEmpty else { return }
        recent.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recent.insert(query, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    func forget(_ query: String) {
        recent.removeAll { $0 == query }
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    func loadSuggestions() {
        guard suggestions.isEmpty, !suggestionsLoading else { return }
        suggestionsLoading = true
        suggestionsFailed = false
        APIService.shared.fetchNowPlaying(region: Locale.current.region?.identifier ?? "US") { [weak self] result in
            guard let self else { return }
            self.suggestionsLoading = false
            switch result {
            case .success(let movies): self.suggestions = Array(movies.prefix(10))
            case .failure: self.suggestionsFailed = true
            }
        }
    }
}

/// Search results and the search start page, shown in place of Discover's deck while its search field is in use.
/// The search field itself, and the text, belong to Discover; this shows what goes with them
struct FilmSearchResults: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @FetchRequest(fetchRequest: CDMovieList.fetch()) private var movieLists: FetchedResults<CDMovieList>
    @Binding var text: String
    @ObservedObject var model: FilmSearchModel

    // The film being added, while the user picks its lists
    @State private var adding: Movie? = nil
    @State private var isAdding = false
    // The film whose info screen is open, as a temporary copy that isn't saved anywhere
    @State private var details: (movie: Movie, preview: CDMovie)? = nil
    // Liked and Not for Me films, as Discover keeps them on this device
    @State private var liked: Set<Int64> = []
    @State private var disliked: Set<Int64> = []
    @State private var toast: String? = nil

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .overlay(alignment: .top) { toastView }
        .addToListFlow(movie: $adding, source: .search, isBusy: $isAdding)
        .sheet(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
            if let details {
                // Add to Lists closes the info screen and asks which lists
                MovieDetailView(movie: details.preview, onAddToLists: {
                    let movie = details.movie
                    self.details = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { adding = movie }
                })
            }
        }
        .onAppear {
            loadReactions()
            model.loadSuggestions()
        }
        // Liked or Not for Me changed elsewhere: Discover, Liked & Not for Me, or brought in from the account
        .onReceive(DiscoverReactions.shared.changed.receive(on: RunLoop.main)) { _ in loadReactions() }
        .onReceive(DiscoverReactions.shared.cleared.receive(on: RunLoop.main)) { _ in
            liked = []
            disliked = []
        }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        let query = FilmSearchModel.clean(text)
        if query.isEmpty {
            startPage
        } else if let failed = model.failedQuery, failed == query {
            errorState(query)
        } else if model.resultsQuery == query && model.loadingQuery == nil {
            if model.results.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No results for “\(query)”",
                               message: "Check the spelling, or try the original title or fewer words.")
                    .padding(.horizontal, 24)
                    .frame(maxHeight: .infinity)
            } else {
                resultList(model.results, query: query)
            }
        } else if !model.results.isEmpty {
            // Earlier results stay in place, dimmed and out of reach, until the new ones arrive
            resultList(model.results, query: model.resultsQuery)
                .disabled(true)
                .opacity(0.4)
                .overlay { searchingIndicator }
        } else {
            searchingIndicator
                .frame(maxHeight: .infinity)
        }
    }

    private var searchingIndicator: some View {
        ProgressView("Searching…")
            .tint(Theme.accent)
            .foregroundColor(Theme.textPrimary)
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("Searching")
    }

    private func errorState(_ query: String) -> some View {
        EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't search",
                       message: "Check your connection and try again.", actionTitle: "Retry") {
            Haptics.tap()
            model.retry()
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
    }

    // Before anything is typed: recent searches, then films in theatres now
    private var startPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !model.recent.isEmpty {
                    recentSection
                }
                sectionHeader("In Theatres Now")
                if model.suggestionsLoading {
                    HStack {
                        Spacer()
                        ProgressView().tint(Theme.accent)
                        Spacer()
                    }
                    .padding(.vertical, 24)
                    .accessibilityLabel("Loading films in theatres")
                } else if model.suggestionsFailed {
                    Button {
                        Haptics.tap()
                        model.loadSuggestions()
                    } label: {
                        Label("Couldn't load films in theatres · Retry", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if model.suggestions.isEmpty {
                    Text("Search for any film or TV show by its title.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                } else {
                    ForEach(model.suggestions) { movie in
                        row(movie, query: nil)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionHeader("Recent Searches")
                Spacer()
                Button("Clear") {
                    Haptics.tap()
                    withAnimation(Theme.spring) { model.clearRecent() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.accent)
                .accessibilityLabel("Clear Recent Searches")
            }
            ForEach(model.recent, id: \.self) { query in
                HStack(spacing: 12) {
                    Button {
                        Haptics.tap()
                        text = query
                        model.remember(query)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(Theme.textSecondary)
                                .accessibilityHidden(true)
                            Text(query)
                                .foregroundColor(Theme.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search for \(query)")
                    Button {
                        withAnimation(Theme.spring) { model.forget(query) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Theme.textTertiary)
                            .frame(minWidth: 32, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(query) from Recent Searches")
                }
                Divider().overlay(Theme.stroke)
            }
        }
        .padding(.bottom, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundColor(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func resultList(_ movies: [Movie], query: String) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(movies) { movie in
                    row(movie, query: query)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: Rows

    // The lists each film is in, by TMDb id
    private var listsByFilm: [Int64: [String]] {
        var names: [Int64: [String]] = [:]
        for list in movieLists {
            for movie in list.movies where movie.tmdb_id != 0 {
                names[Int64(movie.tmdb_id), default: []].append(list.name ?? "a list")
            }
        }
        return names
    }

    private func reaction(of movie: Movie) -> DiscoverReaction? {
        liked.contains(movie.id) ? .liked : disliked.contains(movie.id) ? .disliked : nil
    }

    private func row(_ movie: Movie, query: String?) -> some View {
        let lists = listsByFilm[movie.id] ?? []
        let current = reaction(of: movie)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                Haptics.tap()
                if let query { model.remember(query) }
                details = (movie, PersistenceController.preview(of: movie))
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    PosterImage(path: movie.poster_path, cornerRadius: 8, size: .small)
                        .frame(width: 64, height: 96)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(movie.title)
                            .font(.headline)
                            .foregroundColor(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if movie.isTV { TVBadge() }
                            Text(subtitle(movie))
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        }
                        GenreLine(genres: movie.genre_ids ?? [], isTV: movie.isTV, limit: 3, lineLimit: 2)
                        status(lists: lists, reaction: current)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityValue(current == .liked ? "Liked" : current == .disliked ? "Not for Me" : "")
            .accessibilityHint("Opens film info")
            actions(movie, query: query, reaction: current, inLists: !lists.isEmpty)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private func subtitle(_ movie: Movie) -> String {
        let year = Theme.year(from: movie.release_date)
        let kind = movie.isTV ? "" : "Film"
        return [year, kind].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // The lists it's in. Its rating shows as a filled Like or Not for Me button
    private func statusParts(lists: [String], reaction: DiscoverReaction?) -> [(icon: String, text: String)] {
        var parts: [(icon: String, text: String)] = []
        if !lists.isEmpty {
            parts.append((icon: "checkmark.circle.fill", text: lists.count == 1 ? "In \(lists[0])" : "In \(lists.count) lists"))
        }
        return parts
    }

    @ViewBuilder
    private func status(lists: [String], reaction: DiscoverReaction?) -> some View {
        let parts = statusParts(lists: lists, reaction: reaction)
        if !parts.isEmpty {
            HStack(spacing: 10) {
                ForEach(parts, id: \.text) { part in
                    Label(part.text, systemImage: part.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.accent)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)
        }
    }

    // In a row when they fit, otherwise (e.g. large Dynamic Type) one under another
    private func actions(_ movie: Movie, query: String?, reaction: DiscoverReaction?, inLists: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons(movie, query: query, reaction: reaction, inLists: inLists) }
            VStack(alignment: .leading, spacing: 8) { actionButtons(movie, query: query, reaction: reaction, inLists: inLists) }
        }
        .disabled(isAdding)
    }

    @ViewBuilder
    private func actionButtons(_ movie: Movie, query: String?, reaction: DiscoverReaction?, inLists: Bool) -> some View {
            actionButton(reaction == .liked ? "Liked" : "Like", icon: reaction == .liked ? "heart.fill" : "heart",
                         selected: reaction == .liked) {
                if let query { model.remember(query) }
                rate(movie, .liked)
            }
            .accessibilityLabel("Like")
            .accessibilityValue(reaction == .liked ? "Selected" : "")
            .accessibilityHint(reaction == .liked ? "Takes back your like" : "Shows more films like this in Discover")
            actionButton("Not for Me", icon: reaction == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                         selected: reaction == .disliked) {
                if let query { model.remember(query) }
                rate(movie, .disliked)
            }
            .accessibilityLabel("Not for Me")
            .accessibilityValue(reaction == .disliked ? "Selected" : "")
            .accessibilityHint(reaction == .disliked ? "Takes back Not for Me" : "Shows fewer films like this in Discover")
            actionButton("Add", icon: inLists ? "checkmark" : "plus", selected: false) {
                if let query { model.remember(query) }
                adding = movie
            }
            .accessibilityLabel(inLists ? "Add to Another List" : "Add to a List")
            .accessibilityHint("Choose lists for this film. Adding doesn't rate it")
    }

    private func actionButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(selected ? Theme.onAccent : Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceRaised), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: Actions

    private func loadReactions() {
        let defaults = UserDefaults.standard
        liked = Set((defaults.array(forKey: DiscoverViewModel.likedKey) as? [Int] ?? []).map(Int64.init))
        disliked = Set((defaults.array(forKey: DiscoverViewModel.dislikedKey) as? [Int] ?? []).map(Int64.init))
    }

    /// Like or Not for Me, the same as in Discover: it's sent with the account in the background (waiting on this
    /// device when offline), teaches Discover, and takes the film out of the Discover stack. Tapping the chosen one
    /// again takes it back
    private func rate(_ movie: Movie, _ new: DiscoverReaction) {
        let old = reaction(of: movie)
        if old == new {
            DiscoverReactionSync.shared.remove(movie.id)
            DiscoverReactions.shared.apply(movie.id, movie: movie, from: old, to: nil)
            showToast(new == .liked ? "Like taken back" : "Not for Me taken back")
        } else {
            var rated = movie
            rated.source = "search"
            DiscoverReactionSync.shared.record(rated, new)
            DiscoverReactions.shared.apply(movie.id, movie: movie, from: old, to: new)
            showToast(new == .liked ? "Liked \(movie.title)" : "\(movie.title): Not for Me")
        }
        // apply() reloads these too, through DiscoverReactions.changed; done now so the button changes at once
        loadReactions()
    }

    private func showToast(_ message: String) {
        withAnimation(Theme.spring) { toast = message }
        UIAccessibility.post(notification: .announcement, argument: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(Theme.spring) {
                if toast == message { toast = nil }
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityHidden(true)
        }
    }
}
