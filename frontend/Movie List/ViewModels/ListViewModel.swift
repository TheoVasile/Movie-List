//
//  ListViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation

import SwiftUI
import CoreData

/// What TMDb says about a film: its genres, US age rating and average user score
struct MovieInfo: Codable {
    let genres: [Int]
    // "G", "PG", "PG-13", "R", ...; empty when the film was never rated in the US
    let certification: String
    // Out of 10
    let voteAverage: Double
    let voteCount: Int
    let fetched: Date
}

/// TMDb info for each film, keyed by TMDb id, fetched once and kept on this device. Genres and
/// ratings rarely change, but user scores drift, so entries are refreshed after a month
final class MovieInfoCache {
    static let shared = MovieInfoCache()

    private static let storageKey = "movieInfoCache"
    private static let batchSize = 50
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    private var infoByID: [Int64: MovieInfo]

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: MovieInfo].self, from: $0) } ?? [:]
        infoByID = Dictionary(uniqueKeysWithValues: stored.compactMap { key, info in Int64(key).map { ($0, info) } })
        // Replaced by this cache, which also holds ratings
        UserDefaults.standard.removeObject(forKey: "genreCache")
    }

    func info(for tmdbID: Int64) -> MovieInfo? {
        infoByID[tmdbID]
    }

    private func needsFetch(_ tmdbID: Int64) -> Bool {
        guard tmdbID > 0 else { return false }
        guard let info = infoByID[tmdbID] else { return true }
        return Date().timeIntervalSince(info.fetched) > Self.maxAge
    }

    /// Fetches the films that aren't cached or are out of date, two batches at a time so a big list
    /// stays within TMDb's rate limit. Calls `onBatch` as each batch arrives, then `completion` at the end
    func fetchMissing(_ tmdbIDs: [Int64], onBatch: @escaping () -> Void, completion: @escaping () -> Void) {
        let missing = Array(Set(tmdbIDs.filter(needsFetch)))
        var batches = stride(from: 0, to: missing.count, by: Self.batchSize).map {
            Array(missing[$0..<min($0 + Self.batchSize, missing.count)])
        }
        guard !batches.isEmpty else {
            completion()
            return
        }
        var running = 0
        func startNext() {
            guard let batch = batches.popLast() else {
                if running == 0 {
                    save()
                    completion()
                }
                return
            }
            running += 1
            APIService.shared.fetchMovieInfo(tmdbIDs: batch) { result in
                if case .success(let found) = result {
                    self.infoByID.merge(found) { _, new in new }
                    onBatch()
                }
                running -= 1
                startNext()
            }
        }
        startNext()
        startNext()
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: infoByID.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

class ListViewModel: ObservableObject {
    @Published var movies: [CDMovie] = [] {
        didSet { ensureRecommendation() }
    }
    @Published var searchResults: [Movie] = []
    @Published var recommendedMovie: CDMovie? = nil
    @Published var showPopup: Bool = false
    @Published var newMovieSearchText: String = ""
    @Published var searchText: String = ""
    @Published var showCompareMovieView = false
    @Published var showSetRank = false
    @Published var selectedMovie: CDMovie? = nil
    // True while Compare is placing a film that was just added, rather than re-ranking one
    @Published var isRankingNewMovie = false
    // Genres to filter the list by; a film is shown only if it has all of them. Only changes what's shown
    @Published var selectedGenres: Set<Int> = []
    @Published private(set) var isLoadingGenres = false
    // Set once a movie's new rank is saved, so the list can scroll to where it landed
    @Published var movedMovieID: Int64? = nil
    // Set when a drag to reorder couldn't be saved and the old order was put back
    @Published var reorderFailed = false
    
    var movieList: CDMovieList
    private let context: NSManagedObjectContext
    
    init(movieList: CDMovieList, context: NSManagedObjectContext) {
        self.movieList = movieList
        self.context = context
        fetchMovies()
        ensureRecommendation()
    }

    /// Keeps a recommendation showing whenever the list has films, picking a new one when the
    /// current pick is removed
    private func ensureRecommendation() {
        if movies.isEmpty {
            if recommendedMovie != nil { recommendedMovie = nil }
        } else if recommendedMovie.map({ !movies.contains($0) }) ?? true {
            recommendMovie()
        }
    }
    
    func fetchMovies() {
        movies = Array(movieList.movies).sorted(by: { $0.rank < $1.rank })
    }
    
    func deleteMovie(at offsets: IndexSet) {
        for index in offsets {
            let poppedMovie = movies[index]
            APIService.shared.removeMovieFromList(list_id: movieList.id, movie_id: poppedMovie.id) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        if let managedObjectContext = poppedMovie.managedObjectContext {
                            if self.recommendedMovie == poppedMovie {
                                self.recommendedMovie = nil
                            }
                            managedObjectContext.delete(poppedMovie)
                            withAnimation(Theme.spring) {
                                // The deleted object can linger in the relationship until save, so remove it by identity
                                self.movies = Array(self.movieList.movies)
                                    .filter { $0 != poppedMovie }
                                    .sorted(by: { $0.rank < $1.rank })
                                for (i, m) in self.movies.enumerated() {
                                    m.rank = Int32(i+1)
                                }
                            }
                            self.movieList.movies = Set(self.movies)
                            do {
                                try managedObjectContext.save()
                                try self.context.save()
                            } catch {
                                print("Error saving Core Data:", error)
                            }
                        }
                    case .failure(let error):
                        print("Error deleting:", error)
                    }
                }
            }
        }
    }
    
    func createAndSaveMovie(from networkMovie: Movie) {
        movieList.addMovie(networkMovie, context: context) { newMovie in
            guard let newMovie else { return }
            // Look up the new film's genres and ratings
            self.loadInfo()
            withAnimation(Theme.spring) {
                self.movies = Array(self.movieList.movies).sorted(by: { $0.rank < $1.rank })
            }
            // New films land at the bottom, so ask where it belongs, unless it's the only film
            if self.movies.count > 1 {
                self.promptToRank(newMovie)
            }
        }
    }

    func promptToRank(_ movie: CDMovie) {
        selectedMovie = movie
        isRankingNewMovie = true
        // Give the add sheet time to finish closing before Compare appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(Theme.spring) { self.showCompareMovieView = true }
        }
    }
    
    /// Drag to reorder: moves the rows straight away and saves in the background, putting the old
    /// order back if the server can't save it
    func moveMovie(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let movie = movies[from]
        // destination counts the moved row's old slot, so moving down lands one place earlier
        let newIndex = destination > from ? destination - 1 : destination
        guard newIndex != from else { return }

        let previous = movies
        movies.move(fromOffsets: source, toOffset: destination)
        for (index, movie) in movies.enumerated() {
            movie.rank = Int32(index + 1)
        }
        try? context.save()

        APIService.shared.updateMovieRanking(list_id: movieList.id, movie_id: movie.id, rank: newIndex + 1) { result in
            DispatchQueue.main.async {
                guard case .failure(let error) = result else { return }
                print("error saving new order:", error)
                withAnimation(Theme.spring) {
                    self.movies = previous
                    for (index, movie) in previous.enumerated() {
                        movie.rank = Int32(index + 1)
                    }
                }
                try? self.context.save()
                self.reorderFailed = true
            }
        }
    }

    func updateMovieRanking(updatedMovie: CDMovie, newRank: Int) {
        APIService.shared.updateMovieRanking(list_id: movieList.id, movie_id: updatedMovie.id, rank: newRank) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    print("updated db rankings")
                    // Convert NSSet to sorted array
                    var reordered = Array(self.movieList.movies).sorted(by: { $0.rank < $1.rank })

                    // Remove the movie from the list
                    reordered.removeAll { $0.id == updatedMovie.id }

                    // Insert the movie at the new rank
                    let insertIndex = min(max(newRank - 1, 0), reordered.count)
                    reordered.insert(updatedMovie, at: insertIndex)

                    // Reassign correct rankings for all movies, sliding rows into their new places
                    withAnimation(Theme.spring) {
                        self.movies = reordered
                        for (index, movie) in self.movies.enumerated() {
                            movie.rank = Int32(index + 1)
                        }
                    }

                    // Update movieList's relationship
                    self.movieList.movies = Set(self.movies)
                    self.movedMovieID = updatedMovie.id

                    // Save changes to Core Data
                    do {
                        try self.context.save()
                        print("Core Data rankings updated successfully")
                    } catch {
                        print("Error saving Core Data:", error)
                    }
                case .failure(let error):
                    print("error updating movie rank:", error)
                }
            }
        }
    }
    
    func searchMovies() {
        if newMovieSearchText.isEmpty { return }
        let query = newMovieSearchText
        APIService.shared.searchMovies(name: query) { result in
            DispatchQueue.main.async {
                // A slower response for an older query must not replace newer results
                guard query == self.newMovieSearchText else { return }
                switch result {
                case .success(let movies):
                    self.searchResults = movies
                case .failure(let error):
                    print("Search error:", error.localizedDescription)
                }
            }
        }
    }
    
    func info(of movie: CDMovie) -> MovieInfo? {
        MovieInfoCache.shared.info(for: Int64(movie.tmdb_id))
    }

    func genres(of movie: CDMovie) -> [Int]? {
        info(of: movie)?.genres
    }

    func matchesGenreFilter(_ movie: CDMovie) -> Bool {
        selectedGenres.isEmpty || selectedGenres.isSubset(of: genres(of: movie) ?? [])
    }

    /// Genres in this list, most common first, with how many films have each
    var genreCounts: [(genre: Int, count: Int)] {
        var counts: [Int: Int] = [:]
        for movie in movies {
            for genre in genres(of: movie) ?? [] {
                counts[genre, default: 0] += 1
            }
        }
        return counts.map { (genre: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.genre < $1.genre }
    }

    /// Looks up genres and ratings for films in this list that haven't been seen recently
    func loadInfo() {
        guard !isLoadingGenres else { return }
        isLoadingGenres = true
        MovieInfoCache.shared.fetchMissing(movies.map { Int64($0.tmdb_id) }, onBatch: {
            self.objectWillChange.send()
        }, completion: {
            self.isLoadingGenres = false
        })
    }

    func toggleGenre(_ genre: Int) {
        if selectedGenres.contains(genre) {
            selectedGenres.remove(genre)
        } else {
            selectedGenres.insert(genre)
        }
    }

    var watchedCount: Int {
        movies.filter(\.watched).count
    }

    /// Marks a film watched or unwatched. Watched is per user, and each list keeps its own copy of a
    /// film, so every copy is updated. The change shows straight away and is undone if the server rejects it
    func setWatched(_ movie: CDMovie, _ watched: Bool) {
        let previous = applyWatched(watched, toMovieIDs: [movie.id])
        APIService.shared.setMovieWatched(movie_id: movie.id, watched: watched) { result in
            if case .failure(let error) = result {
                print("Error updating watched status:", error)
                self.restoreWatched(previous)
            }
        }
    }

    /// Marks every film in this list watched or unwatched
    func setAllWatched(_ watched: Bool) {
        let previous = applyWatched(watched, toMovieIDs: Set(movies.map(\.id)))
        APIService.shared.setListWatched(list_id: movieList.id, watched: watched) { result in
            if case .failure(let error) = result {
                print("Error updating watched status for list:", error)
                self.restoreWatched(previous)
            }
        }
    }

    // Returns each changed copy's old value so a failed request can put it back
    private func applyWatched(_ watched: Bool, toMovieIDs ids: Set<Int64>) -> [(CDMovie, Bool)] {
        let request = CDMovie.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(ids))
        let copies = (try? context.fetch(request)) ?? []
        let previous = copies.map { ($0, $0.watched) }
        withAnimation(Theme.spring) {
            objectWillChange.send()
            copies.forEach { $0.watched = watched }
        }
        saveContext()
        return previous
    }

    private func restoreWatched(_ previous: [(CDMovie, Bool)]) {
        withAnimation(Theme.spring) {
            objectWillChange.send()
            previous.forEach { movie, watched in movie.watched = watched }
        }
        saveContext()
    }

    private func saveContext() {
        do {
            try context.save()
        } catch {
            print("Error saving Core Data:", error)
        }
    }

    /// Picks a movie at random, weighted by rank: in a list of n, #1 is n times as likely as the last
    /// movie, #2 is n-1 times as likely, and so on
    func recommendMovie() {
        // Skip the current pick so the button always shows something new
        let candidates = movies.count > 1 ? movies.filter { $0 != recommendedMovie } : movies
        guard !candidates.isEmpty else { return }

        // `movies` is sorted by rank, so earlier movies get the larger weights
        let weights = candidates.indices.map { candidates.count - $0 }
        var roll = Int.random(in: 0..<weights.reduce(0, +))
        for (movie, weight) in zip(candidates, weights) {
            if roll < weight {
                recommendedMovie = movie
                return
            }
            roll -= weight
        }
    }
}
