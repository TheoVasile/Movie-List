//
//  CollectionsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI

/// Every released film in a franchise (TMDb collection) or by a director, oldest first
struct Filmography: Codable {
    enum Kind: String, Codable {
        case collection, director
    }

    let name: String
    let films: [Movie]
}

/// Filmographies fetched for Directors & Franchises, kept on this device for a week, since they rarely change
final class FilmographyStore: ObservableObject {
    static let shared = FilmographyStore()

    private struct Entry: Codable {
        let filmography: Filmography
        let fetched: Date
    }

    @Published private(set) var version = 0
    private var entries: [String: Entry]
    private var loading: Set<String> = []
    private var queue: [(kind: Filmography.Kind, id: Int)] = []
    private var running = 0

    private static let storageKey = "filmographies"
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let concurrency = 4

    private init() {
        entries = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private static func key(_ kind: Filmography.Kind, _ id: Int) -> String { "\(kind.rawValue):\(id)" }

    func filmography(_ kind: Filmography.Kind, id: Int) -> Filmography? {
        entries[Self.key(kind, id)]?.filmography
    }

    /// Fetches the ones not fetched in the last week, a few at a time
    func load(_ wanted: [(kind: Filmography.Kind, id: Int)]) {
        let now = Date()
        for item in wanted {
            let key = Self.key(item.kind, item.id)
            let fresh = entries[key].map { now.timeIntervalSince($0.fetched) < Self.maxAge } ?? false
            if !fresh && !loading.contains(key) {
                loading.insert(key)
                queue.append(item)
            }
        }
        while running < Self.concurrency, !queue.isEmpty { startNext() }
    }

    private func startNext() {
        guard !queue.isEmpty else { return }
        let item = queue.removeFirst()
        running += 1
        APIService.shared.fetchFilmography(item.kind, id: item.id) { result in
            let key = Self.key(item.kind, item.id)
            self.loading.remove(key)
            self.running -= 1
            if case .success(let filmography) = result {
                self.entries[key] = Entry(filmography: filmography, fetched: Date())
                self.version += 1
                if let data = try? JSONEncoder().encode(self.entries) {
                    UserDefaults.standard.set(data, forKey: Self.storageKey)
                }
            }
            self.startNext()
        }
    }
}

/// A director or franchise the user has seen films from, and how far through it they are
struct FilmCollection: Identifiable {
    let kind: Filmography.Kind
    let id: Int
    let name: String
    // TMDb ids of the user's films in it that they've watched, and of all their films in it
    let watched: Set<Int64>
    let inLists: Set<Int64>
    let filmography: Filmography?

    var key: String { "\(kind.rawValue):\(id)" }
    // Films in it so far; until the filmography loads, at least what the user has
    var total: Int? { filmography.map { max($0.films.count, watched.count) } }
    var progress: Double { total.map { $0 > 0 ? Double(watched.count) / Double($0) : 0 } ?? 0 }
    var isComplete: Bool { total.map { watched.count >= $0 } ?? false }
}

/// Directors & Franchises: for each director and franchise the user has watched films from, how many of their
/// films they've seen, and the ones still to see. Worked out from the user's lists and TMDb
struct CollectionsView: View {
    @FetchRequest(fetchRequest: CDMovieList.fetch()) private var movieLists: FetchedResults<CDMovieList>
    @ObservedObject private var filmographies = FilmographyStore.shared
    @State private var showingDirectors = true
    @State private var infoVersion = 0
    @State private var loadingInfo = false

    // Enough to cover anyone's favourites without asking TMDb about hundreds of people
    private static let shownLimit = 30

    private var collections: (directors: [FilmCollection], franchises: [FilmCollection]) {
        _ = infoVersion
        _ = filmographies.version
        var films: [Int64: Bool] = [:]
        for list in movieLists {
            for movie in list.movies {
                films[Int64(movie.tmdb_id), default: false] = films[Int64(movie.tmdb_id), default: false] || movie.watched
            }
        }
        var directors: [Int: (name: String, watched: Set<Int64>, inLists: Set<Int64>)] = [:]
        var franchises: [Int: (name: String, watched: Set<Int64>, inLists: Set<Int64>)] = [:]
        for (id, watched) in films where id > 0 {
            guard let info = MovieInfoCache.shared.info(for: id) else { continue }
            for director in info.directors ?? [] {
                var entry = directors[director.id] ?? (director.name, [], [])
                entry.inLists.insert(id)
                if watched { entry.watched.insert(id) }
                directors[director.id] = entry
            }
            if let franchise = info.collection {
                var entry = franchises[franchise.id] ?? (franchise.name, [], [])
                entry.inLists.insert(id)
                if watched { entry.watched.insert(id) }
                franchises[franchise.id] = entry
            }
        }
        let make = { (kind: Filmography.Kind, groups: [Int: (name: String, watched: Set<Int64>, inLists: Set<Int64>)], minimum: Int) in
            groups.filter { $0.value.watched.count >= minimum }
                .sorted { $0.value.watched.count > $1.value.watched.count }
                .prefix(Self.shownLimit)
                .map { id, group in
                    FilmCollection(kind: kind, id: id, name: group.name, watched: group.watched, inLists: group.inLists,
                               filmography: filmographies.filmography(kind, id: id))
                }
                // Closest to finishing first, then the ones with the most seen
                .sorted { ($0.isComplete ? 1 : 0, $0.progress, $0.watched.count) > ($1.isComplete ? 1 : 0, $1.progress, $1.watched.count) }
        }
        // A director needs two films to be a pattern; one film from a franchise is already a start
        return (make(.director, directors, 2), make(.collection, franchises, 1))
    }

    var body: some View {
        let all = collections
        let shown = showingDirectors ? all.directors : all.franchises
        List {
            Picker("Show", selection: $showingDirectors) {
                Text("Directors").tag(true)
                Text("Franchises").tag(false)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if shown.isEmpty {
                Text(loadingInfo ? "Looking through your films…"
                     : showingDirectors ? "Mark films as watched, and directors you've seen two or more films by will show up here."
                     : "Mark films as watched, and franchises you've started will show up here.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(shown) { collection in
                NavigationLink {
                    CollectionDetailView(collection: collection)
                } label: {
                    row(collection)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Directors & Franchises")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadInfo)
        .onChange(of: infoVersion) { _ in loadFilmographies() }
    }

    private func row(_ collection: FilmCollection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(collection.name)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if collection.isComplete {
                    Label("Complete", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accentGradient)
                }
            }
            ProgressView(value: collection.progress)
                .tint(Theme.accent)
            Text(collection.total.map { "\(collection.watched.count) of \($0) seen" } ?? "\(collection.watched.count) seen")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func loadInfo() {
        let ids = movieLists.flatMap { $0.movies.map { Int64($0.tmdb_id) } }
        loadingInfo = true
        MovieInfoCache.shared.fetchMissing(ids, onBatch: { infoVersion += 1 }, completion: {
            loadingInfo = false
            infoVersion += 1
        })
        loadFilmographies()
    }

    private func loadFilmographies() {
        let all = collections
        filmographies.load((all.directors + all.franchises).map { (kind: $0.kind, id: $0.id) })
    }
}

/// One director's or franchise's films, oldest first: which the user has seen, which are in their lists, and a
/// way to add the rest
struct CollectionDetailView: View {
    let collection: FilmCollection
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @ObservedObject private var filmographies = FilmographyStore.shared
    @State private var details: CDMovie? = nil
    @State private var detailsMovie: Movie? = nil
    @State private var adding: Movie? = nil
    // Films added from here, so their button changes straight away
    @State private var added: Set<Int64> = []

    private var films: [Movie] {
        filmographies.filmography(collection.kind, id: collection.id)?.films ?? []
    }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 8) {
                Text(collection.total.map { "\(collection.watched.count) of \($0) seen" } ?? "\(collection.watched.count) seen")
                    .font(.title3.weight(.heavy))
                    .foregroundColor(Theme.textPrimary)
                ProgressView(value: collection.progress)
                    .tint(Theme.accent)
                Text(collection.isComplete ? "You've seen every one." : "Add the rest to a list to get to them.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            if films.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            ForEach(films) { film in
                row(film)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { filmographies.load([(kind: collection.kind, id: collection.id)]) }
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
                if !lists.isEmpty {
                    Haptics.success()
                    AppAnalytics.log(.filmAdded(.collection))
                    added.insert(movie.id)
                }
            }
            .environmentObject(authViewModel)
            .environment(\.managedObjectContext, context)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func row(_ film: Movie) -> some View {
        let seen = collection.watched.contains(film.id)
        let listed = collection.inLists.contains(film.id) || added.contains(film.id)
        return HStack(spacing: 12) {
            Button {
                Haptics.tap()
                detailsMovie = film
                details = PersistenceController.preview(of: film)
            } label: {
                HStack(spacing: 12) {
                    PosterImage(path: film.poster_path, cornerRadius: 6, size: .small)
                        .frame(width: 44, height: 66)
                        .opacity(seen ? 1 : 0.85)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(film.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(Theme.year(from: film.release_date))
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if seen {
                Label("Seen", systemImage: "eye.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentGradient)
            } else if listed {
                Text("In your lists")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
            } else {
                Button {
                    Haptics.tap()
                    adding = film
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accentGradient, in: Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add \(film.title) to your lists")
            }
        }
    }
}
