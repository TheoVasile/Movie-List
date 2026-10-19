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
    var onCompare: (() -> Void)? = nil
    var onSetRank: (() -> Void)? = nil
    var onToggleWatched: (() -> Void)? = nil
    // Saves the user's note; calls back with whether it was saved. Notes are only offered when this is set
    var onSaveNote: ((String, @escaping (Bool) -> Void) -> Void)? = nil

    @State private var revealed = false
    @State private var editingNote = false
    @State private var friendTakes: [FriendTake] = []
    @State private var imdbID: String? = nil
    @State private var info: MovieInfo? = nil
    @State private var providers: WatchProviders? = nil

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
            if movie.tmdb_id > 0 {
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
        guard movie.tmdb_id > 0 else { return }
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
                .frame(height: 460)
            PosterImage(path: movie.poster_path, cornerRadius: 18, size: .xlarge)
                .frame(width: 200, height: 300)
                .shadow(color: Theme.shadow.opacity(0.6), radius: 30, y: 16)
                .scaleEffect(revealed ? 1 : 0.85)
                .opacity(revealed ? 1 : 0)
                .rotation3DEffect(.degrees(revealed ? 0 : 12), axis: (x: 1, y: 0, z: 0))
                .padding(.bottom, 10)
        }
        .frame(height: 460)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if movie.rank > 0 {
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
            }
            .appearAnimation(delay: 0.1)

            HStack(spacing: 8) {
                if let date = movie.release_date {
                    MetaChip(icon: "calendar", text: date.formatted(.dateTime.year().month(.abbreviated).day()))
                }
                if let language = movie.original_language, !language.isEmpty {
                    MetaChip(icon: "globe", text: language.uppercased())
                }
                if movie.popularity > 0 {
                    MetaChip(icon: "flame.fill", text: String(format: "%.0f", movie.popularity))
                }
            }
            .appearAnimation(delay: 0.18)

            if onCompare != nil || onSetRank != nil {
                HStack(spacing: 12) {
                    if let onCompare {
                        Button {
                            Haptics.tap()
                            onCompare()
                        } label: {
                            Label("Compare", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    if let onSetRank {
                        Button {
                            Haptics.tap()
                            onSetRank()
                        } label: {
                            Label("Set Rank", systemImage: "number")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .appearAnimation(delay: 0.26)
            }

            if let onToggleWatched {
                Button {
                    Haptics.tap()
                    onToggleWatched()
                } label: {
                    Label(movie.watched ? "Mark as Unwatched" : "Mark as Watched",
                          systemImage: movie.watched ? "eye.slash" : "eye")
                }
                .buttonStyle(SecondaryButtonStyle())
                .appearAnimation(delay: 0.3)
            }

            if onSaveNote != nil {
                notesCard
                    .appearAnimation(delay: 0.31)
            }

            if !friendTakes.isEmpty {
                FriendTakesSection(takes: friendTakes)
            }

            if let info, info.voteCount > 0 || !info.certification.isEmpty {
                userScore(info)
                    .transition(.opacity)
            }

            if let providers {
                WatchProvidersSection(providers: providers)
                    .transition(.opacity)
            }

            imdbLink
                .appearAnimation(delay: 0.32)

            if let overview = movie.overview, !overview.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Overview")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text(overview)
                        .font(.body)
                        .foregroundColor(Theme.textSecondary)
                        .lineSpacing(4)
                }
                .appearAnimation(delay: 0.34)
            }
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
        guard tmdbID > 0 else { return }
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
                group("Stream", providers.stream + providers.free)
                group("Rent", providers.rent)
                group("Buy", providers.buy)
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
