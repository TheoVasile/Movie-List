//
//  MovieDetailView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI

struct MovieDetailView: View {
    @ObservedObject var movie: CDMovie
    var listName: String? = nil
    // False for a film in an unranked list, which has no rank to show
    var ranked = true
    // Opens the list picker to add this film to other lists
    var onAddToLists: (() -> Void)? = nil
    var onCompare: (() -> Void)? = nil
    var onSetRank: (() -> Void)? = nil
    var onToggleWatched: (() -> Void)? = nil
    // Saves the user's note; calls back with whether it was saved. Notes are only offered when this is set
    var onSaveNote: ((String, @escaping (Bool) -> Void) -> Void)? = nil
    // Set while the film's spot was suggested by Smart Placement and not yet approved
    var onApprovePlacement: (() -> Void)? = nil
    @State private var placementApproved = false

    @State private var revealed = false
    @State private var overviewExpanded = false
    @State private var editingNote = false
    @State private var friendTakes: [FriendTake] = []
    @State private var imdbID: String? = nil
    @State private var info: MovieInfo? = nil
    @State private var providers: WatchProviders? = nil
    @State private var recommending = false
    @ObservedObject private var social = SocialStore.shared

    private static let imdbCacheKey = "imdbIDs"

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    details
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                revealed = true
            }
            loadIMDbID()
            loadInfo()
            if movie.tmdb_id != 0 {
                APIService.shared.fetchFriendTakes(tmdbID: Int64(movie.tmdb_id)) { result in
                    if case .success(let takes) = result {
                        withAnimation(Theme.spring) { friendTakes = takes }
                    }
                }
            }
            WatchProvidersStore.shared.load(tmdbID: Int64(movie.tmdb_id)) { loaded in
                withAnimation(Theme.spring) { providers = loaded }
            }
        }
    }

    // The film's IMDb page once its id is known, otherwise an IMDb search for its title and year
    private var imdbURL: URL? {
        if let imdbID {
            return URL(string: "https://www.imdb.com/title/\(imdbID)/")
        }
        var components = URLComponents(string: "https://www.imdb.com/find/")
        let year = Theme.year(from: movie.release_date)
        components?.queryItems = [
            URLQueryItem(name: "q", value: [movie.title ?? "", year].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "s", value: "tt"),
        ]
        return components?.url
    }

    private func loadInfo() {
        let tmdbID = Int64(movie.tmdb_id)
        info = MovieInfoCache.shared.info(for: tmdbID)
        // Fetches only if the film isn't cached or is out of date
        MovieInfoCache.shared.fetchMissing([tmdbID], onBatch: {}, completion: {
            withAnimation(Theme.spring) {
                info = MovieInfoCache.shared.info(for: tmdbID)
            }
        })
    }

    /// TMDb's average user score as a ring, like TMDb's own "User Score"
    private func userScore(_ info: MovieInfo) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Theme.textPrimary.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: revealed ? info.voteAverage / 10 : 0)
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.8).delay(0.3), value: revealed)
                Text(String(format: "%.1f", info.voteAverage))
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("TMDb User Score")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("\(info.voteCount.formatted()) \(info.voteCount == 1 ? "rating" : "ratings")")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            if !info.certification.isEmpty {
                VStack(spacing: 3) {
                    Text(info.certification)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Theme.textPrimary.opacity(0.6), lineWidth: 1.5)
                        )
                    Text("Rated")
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Rated \(info.certification)")
            }
        }
        .padding(14)
        .cardStyle()
    }

    // IMDb ids never change, so each one is looked up once and kept on this device
    private func loadIMDbID() {
        let key = String(movie.tmdb_id)
        let cache = UserDefaults.standard.dictionary(forKey: Self.imdbCacheKey) as? [String: String] ?? [:]
        if let cached = cache[key] {
            imdbID = cached
            return
        }
        guard movie.tmdb_id != 0 else { return }
        APIService.shared.fetchIMDbID(tmdbID: Int64(movie.tmdb_id)) { result in
            guard case .success(let id?) = result else { return }
            imdbID = id
            var cache = UserDefaults.standard.dictionary(forKey: Self.imdbCacheKey) as? [String: String] ?? [:]
            cache[key] = id
            UserDefaults.standard.set(cache, forKey: Self.imdbCacheKey)
        }
    }

    // The user's own words about the film, or a prompt to write some
    private var notesCard: some View {
        Button {
            Haptics.tap()
            editingNote = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Your Notes", systemImage: "note.text")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(movie.note == nil ? "Add" : "Edit")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.accent)
                }
                Text(movie.note ?? "What did you think? People who follow you can see your notes.")
                    .font(.subheadline)
                    .foregroundColor(movie.note == nil ? Theme.textTertiary : Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .cardStyle()
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .sheet(isPresented: $editingNote) {
            NoteEditor(title: movie.title ?? "Notes", initialText: movie.note ?? "") { text, done in
                onSaveNote?(text, done)
            }
        }
    }

    private var imdbLink: some View {
        Link(destination: imdbURL ?? URL(string: "https://www.imdb.com")!) {
            HStack(spacing: 10) {
                Text("IMDb")
                    .font(.system(size: 14, weight: .black))
                    .foregroundColor(Color.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.96, green: 0.77, blue: 0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(imdbID == nil ? "Search on IMDb" : "View on IMDb")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(14)
            .cardStyle()
        }
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            PosterBackdrop(path: movie.poster_path)
                .frame(height: 380)
            PosterImage(path: movie.poster_path, cornerRadius: 18, size: .xlarge)
                .frame(width: 170, height: 255)
                .shadow(color: Theme.shadow.opacity(0.6), radius: 30, y: 16)
                .scaleEffect(revealed ? 1 : 0.85)
                .opacity(revealed ? 1 : 0)
                .rotation3DEffect(.degrees(revealed ? 0 : 12), axis: (x: 1, y: 0, z: 0))
                .padding(.bottom, 10)
        }
        .frame(height: 380)
    }

    private func overviewSection(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(overview)
                .font(.body)
                .foregroundColor(Theme.textSecondary)
                .lineSpacing(4)
                .lineLimit(overviewExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            // Only offered when the overview is long enough to have been cut short
            if overview.count > 220 {
                Button(overviewExpanded ? "Less" : "More") {
                    Haptics.tap()
                    withAnimation(Theme.spring) { overviewExpanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.accent)
                .buttonStyle(.plain)
            }
        }
    }

    // Sends the film to friends, like the trailer button beside it
    private var recommendButton: some View {
        Button {
            Haptics.tap()
            recommending = true
        } label: {
            Label("Recommend", systemImage: "paperplane.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.surface).overlay(Capsule().stroke(Theme.stroke, lineWidth: 1)))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .accessibilityLabel("Recommend to Friends")
        .sheet(isPresented: $recommending) {
            RecommendFilmSheet(movie: Movie(movie))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var hasActions: Bool {
        onCompare != nil || onSetRank != nil || onToggleWatched != nil || onAddToLists != nil
    }

    // Compare, Set Rank, Watched and Add to Lists side by side, instead of a full-width button each
    private var actionTiles: some View {
        HStack(spacing: 10) {
            if let onCompare {
                actionTile("Compare", icon: "arrow.left.arrow.right", highlighted: true, action: onCompare)
            }
            if let onSetRank {
                actionTile("Set Rank", icon: "number", action: onSetRank)
            }
            if let onToggleWatched {
                actionTile(movie.watched ? "Watched" : "Unwatched", icon: movie.watched ? "eye.fill" : "eye",
                           highlighted: movie.watched, action: onToggleWatched)
                    .accessibilityLabel(movie.watched ? "Mark as Unwatched" : "Mark as Watched")
            }
            if let onAddToLists {
                actionTile("Add to Lists", icon: "text.badge.plus", action: onAddToLists)
            }
        }
    }

    private func actionTile(_ title: String, icon: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(highlighted ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.accentGradient))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(highlighted ? Theme.onAccent : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(highlighted ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(highlighted ? Color.clear : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if !ranked, let listName {
                        Text("IN \(listName.uppercased())")
                            .font(.caption.weight(.heavy))
                            .tracking(1.5)
                            .foregroundStyle(Theme.accentGradient)
                    } else if ranked && movie.rank > 0 {
                        Text(listName.map { "#\(movie.rank) IN \($0.uppercased())" } ?? "#\(movie.rank)")
                            .font(.caption.weight(.heavy))
                            .tracking(1.5)
                            .foregroundStyle(Theme.accentGradient)
                    }
                    if movie.watched {
                        WatchedTag()
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                Text(movie.title ?? "")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let onApprovePlacement, !placementApproved {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Placed by AI")
                        Text("·")
                        Button("Keep This Spot") {
                            Haptics.tap()
                            withAnimation(Theme.spring) { placementApproved = true }
                            onApprovePlacement()
                        }
                        .foregroundColor(Theme.accent)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                    .transition(.opacity)
                }
            }
            .appearAnimation(delay: 0.1)

            FlowLayout(spacing: 8) {
                if movie.isTV {
                    MetaChip(icon: "tv", text: "TV Series")
                }
                if let date = movie.release_date {
                    // A show's date is when it first aired
                    MetaChip(icon: movie.isTV ? "dot.radiowaves.left.and.right" : "calendar", text: date.formatted(.dateTime.year().month(.abbreviated).day()))
                        .accessibilityLabel(movie.isTV ? "First aired" : "Released")
                }
                if let length = info?.length {
                    MetaChip(icon: "clock", text: movie.isTV ? "\(length) episodes" : length)
                        .accessibilityLabel(movie.isTV ? "Episodes run \(length)" : "Runs \(length)")
                        .transition(.opacity)
                }
                if movie.isTV, let seasons = info?.seasons, seasons > 0 {
                    MetaChip(icon: "square.stack", text: "\(seasons) \(seasons == 1 ? "season" : "seasons")")
                        .transition(.opacity)
                }
                // Spelled out here ("Japanese"); everywhere else it's the code ("JA")
                if let language = movie.original_language, !language.isEmpty {
                    MetaChip(icon: "globe", text: DiscoverFilters.languageName(language))
                }
            }
            .appearAnimation(delay: 0.18)

            HStack(spacing: 8) {
                TrailerButton(tmdbID: Int64(movie.tmdb_id), title: movie.title ?? "")
                // Needs an @username, since that's how friends see who sent it
                if movie.tmdb_id != 0 && social.profile?.handle != nil {
                    recommendButton
                }
            }

            // The overview comes straight after the title, so it's readable without scrolling
            if let overview = movie.overview, !overview.isEmpty {
                overviewSection(overview)
                    .appearAnimation(delay: 0.22)
            }

            if let info, info.voteCount > 0 || !info.certification.isEmpty {
                userScore(info)
                    .transition(.opacity)
            }

            // Shows get episode tracking: progress, what's next, and every episode
            if movie.isTV && movie.tmdb_id != 0 {
                EpisodesCard(showID: Int64(movie.tmdb_id))
                    .appearAnimation(delay: 0.24)
            }

            if hasActions {
                actionTiles
                    .appearAnimation(delay: 0.26)
            }

            // Only for the user's own films, which are the ones that can be marked watched
            if onToggleWatched != nil {
                WatchHistoryCard(movie: movie)
                    .appearAnimation(delay: 0.28)
            }

            if onSaveNote != nil {
                notesCard
                    .appearAnimation(delay: 0.3)
            }

            if !friendTakes.isEmpty {
                FriendTakesSection(takes: friendTakes)
            }

            if let providers {
                WatchProvidersSection(providers: providers)
                    .transition(.opacity)
            }

            imdbLink
                .appearAnimation(delay: 0.32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Where to watch

/// Watch providers for the user's country, fetched once per film and kept for the rest of the session
final class WatchProvidersStore {
    static let shared = WatchProvidersStore()
    private var cache: [Int64: WatchProviders] = [:]

    /// The iPhone's country, which is where the user is most likely watching
    static var region: String {
        Locale.current.region?.identifier ?? "US"
    }

    /// Calls back on the main thread, straight away if cached; nothing happens when the lookup fails
    func load(tmdbID: Int64, completion: @escaping (WatchProviders) -> Void) {
        guard tmdbID != 0 else { return }
        if let cached = cache[tmdbID] {
            completion(cached)
            return
        }
        APIService.shared.fetchWatchProviders(tmdbID: tmdbID, region: Self.region) { result in
            guard case .success(let providers) = result else { return }
            self.cache[tmdbID] = providers
            completion(providers)
        }
    }
}

struct WatchProvidersSection: View {
    let providers: WatchProviders
    // Collapsed, the card shows a single row of services; expanding shows every way to watch
    @State private var expanded = false

    // Stream (including free), Rent and Buy, leaving out the empty ones
    private var groups: [(title: String, items: [WatchProvider])] {
        [("Stream", providers.stream + providers.free), ("Rent", providers.rent), ("Buy", providers.buy)]
            .filter { !$0.items.isEmpty }
    }

    private var countryName: String {
        Locale.current.localizedString(forRegionCode: providers.region) ?? providers.region
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where to Watch")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(countryName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            if providers.isEmpty {
                Text("Not available to stream, rent or buy in \(countryName) right now.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            } else {
                ForEach(Array((expanded ? groups : Array(groups.prefix(1))).enumerated()), id: \.element.title) { _, group in
                    self.group(group.title, group.items)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if groups.count > 1 {
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.spring) { expanded.toggle() }
                    } label: {
                        Label(expanded ? "Show less" : "Show " + groups.dropFirst().map { $0.title.lowercased() }.joined(separator: " & "),
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                // TMDb's terms ask apps to credit JustWatch for this data
                Text("Availability from JustWatch")
                    .font(.caption2)
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                if let link = providers.link.flatMap(URL.init(string:)), !providers.isEmpty {
                    Link(destination: link) {
                        Label("All options", systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.accent)
                    }
                    .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [WatchProvider]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(1.2)
                    .foregroundColor(Theme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(items) { provider in
                            ProviderLogo(provider: provider, size: 44)
                        }
                    }
                }
            }
        }
    }
}

/// A service's square logo, with its name for VoiceOver
struct ProviderLogo: View {
    let provider: WatchProvider
    let size: CGFloat

    var body: some View {
        AsyncImage(url: provider.logoURL) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Theme.surfaceRaised
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .accessibilityLabel(provider.name)
    }
}

// MARK: - Note editor

private struct NoteEditor: View {
    let title: String
    let initialText: String
    let onSave: (String, @escaping (Bool) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSaving = false
    @State private var saveFailed = false
    @FocusState private var focused: Bool

    private static let maxLength = 5000

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("What did you think? Who should you watch it with?")
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Text("People who follow you can see this.")
                    Spacer()
                    Text("\(text.count)/\(Self.maxLength)")
                        .monospacedDigit()
                        .foregroundColor(text.count > Self.maxLength ? Theme.accentSecondary : Theme.textTertiary)
                }
                .font(.caption)
                .foregroundColor(Theme.textTertiary)
            }
            .padding(16)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .bold()
                            .disabled(text == initialText || text.count > Self.maxLength)
                    }
                }
            }
            .alert("Couldn't save your note", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again. Your note is still here.")
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            text = initialText
            focused = true
        }
    }

    private func save() {
        isSaving = true
        onSave(text) { saved in
            isSaving = false
            if saved {
                Haptics.success()
                dismiss()
            } else {
                saveFailed = true
            }
        }
    }
}

struct MovieDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            MovieDetailView(movie: CDMovie.example, listName: "Christmas Movies", onCompare: {}, onSetRank: {})
        }
        .preferredColorScheme(.dark)
    }
}
