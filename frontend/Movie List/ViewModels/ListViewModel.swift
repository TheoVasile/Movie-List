//
//  ListViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation

import SwiftUI
import CoreData

/// TMDb genres for each film, keyed by TMDb id. A film's genres don't change, so they're fetched
/// once and kept on this device. They're only used to filter what a list shows
final class GenreCache {
    static let shared = GenreCache()

    private static let storageKey = "genreCache"
    private static let batchSize = 50
    private var genresByID: [Int64: [Int]]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [Int]] ?? [:]
        genresByID = Dictionary(uniqueKeysWithValues: stored.compactMap { key, genres in Int64(key).map { ($0, genres) } })
    }

    func genres(for tmdbID: Int64) -> [Int]? {
        genresByID[tmdbID]
    }

    func store(_ genres: [Int], for tmdbID: Int64) {
        genresByID[tmdbID] = genres
        save()
    }

    /// Fetches the films that aren't cached yet, two batches at a time so a big list stays within
    /// TMDb's rate limit. Calls `onBatch` as each batch arrives, then `completion` at the end
    func fetchMissing(_ tmdbIDs: [Int64], onBatch: @escaping () -> Void, completion: @escaping () -> Void) {
        let missing = Array(Set(tmdbIDs.filter { $0 > 0 && genresByID[$0] == nil }))
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
            APIService.shared.fetchGenres(tmdbIDs: batch) { result in
                if case .success(let found) = result {
                    self.genresByID.merge(found) { _, new in new }
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
        let stored = Dictionary(uniqueKeysWithValues: genresByID.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(stored, forKey: Self.storageKey)
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
        // Search results already carry their genres, so there's nothing to look up later
        if let genres = networkMovie.genre_ids {
            GenreCache.shared.store(genres, for: networkMovie.id)
        }
        movieList.addMovie(networkMovie, context: context) { newMovie in
            guard let newMovie else { return }
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
    
    func genres(of movie: CDMovie) -> [Int]? {
        GenreCache.shared.genres(for: Int64(movie.tmdb_id))
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

    /// Looks up genres for films in this list that haven't been seen before
    func loadGenres() {
        guard !isLoadingGenres else { return }
        isLoadingGenres = true
        GenreCache.shared.fetchMissing(movies.map { Int64($0.tmdb_id) }, onBatch: {
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
