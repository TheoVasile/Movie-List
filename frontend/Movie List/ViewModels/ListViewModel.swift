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
/// A director or a franchise (TMDb collection), by TMDb id
struct CreditPerson: Codable, Hashable {
    let id: Int
    let name: String
}

struct MovieInfo: Codable {
    let genres: [Int]
    // "G", "PG", "PG-13", "R", ...; empty when the film was never rated in the US
    let certification: String
    // Out of 10
    let voteAverage: Double
    let voteCount: Int
    // Minutes (a show's typical episode), 0 when TMDb doesn't know. nil in info cached before lengths were kept
    var runtime: Int? = nil
    // For TV shows
    var seasons: Int? = nil
    var episodes: Int? = nil
    // Who directed it (empty for shows) and the franchise it's part of. nil directors means info cached before
    // these were kept
    var directors: [CreditPerson]? = nil
    var collection: CreditPerson? = nil
    let fetched: Date

    /// The length as "2h 14m", or "45m" for a show's episodes, nil when unknown
    var length: String? {
        guard let runtime, runtime > 0 else { return nil }
        let hours = runtime / 60, minutes = runtime % 60
        if hours == 0 { return "\(minutes)m" }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
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
        guard tmdbID != 0 else { return false }
        guard let info = infoByID[tmdbID] else { return true }
        // Info cached before lengths, directors and franchises were kept is fetched again to get them
        return info.runtime == nil || info.directors == nil || Date().timeIntervalSince(info.fetched) > Self.maxAge
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
    // Tonight's Pick. Remembered for each list on this device, so it stays the same until the dice is rolled
    @Published var recommendedMovie: CDMovie? = nil {
        didSet {
            if let recommendedMovie {
                UserDefaults.standard.set(Int(recommendedMovie.id), forKey: pickKey)
            }
        }
    }

    private var pickKey: String { "tonightsPick.\(movieList.id)" }
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
    // Shows only films placed by Smart Placement and not yet approved
    @Published var showAIPlacedOnly = false
    // "What can I watch tonight?": only films streaming on the user's services, optionally shortest first
    @Published var showStreamingOnly = false
    @Published var shortestFirst = false
    // Bumped when a film's AI mark changes, so rows showing it update
    @Published private(set) var placementVersion = 0
    @Published private(set) var isLoadingGenres = false
    // Set once a movie's new rank is saved, so the list can scroll to where it landed
    @Published var movedMovieID: Int64? = nil
    // Set when a drag to reorder couldn't be saved and the old order was put back
    @Published var reorderFailed = false
    // Looking up TMDb scores before sorting by them
    @Published var isSorting = false
    
    var movieList: CDMovieList
    private let context: NSManagedObjectContext
    
    init(movieList: CDMovieList, context: NSManagedObjectContext) {
        self.movieList = movieList
        self.context = context
        fetchMovies()
        ensureRecommendation()
    }

    /// Keeps a recommendation showing whenever the list has films: the one picked last time, or a new one when
    /// there isn't one yet or it has left the list
    private func ensureRecommendation() {
        if movies.isEmpty {
            if recommendedMovie != nil { recommendedMovie = nil }
        } else if recommendedMovie.map({ !movies.contains($0) }) ?? true {
            let saved = UserDefaults.standard.object(forKey: pickKey) as? Int
            if let saved, let movie = movies.first(where: { Int($0.id) == saved }) {
                recommendedMovie = movie
            } else {
                recommendMovie()
            }
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
        movieList.addMovie(tmdbID: networkMovie.id, context: context) { newMovie in
            guard let newMovie else { return }
            AppAnalytics.log(.filmAdded(.search))
            // Look up the new film's genres and ratings
            self.loadInfo()
            withAnimation(Theme.spring) {
                self.movies = Array(self.movieList.movies).sorted(by: { $0.rank < $1.rank })
            }
            // New films land at the bottom, so ask where it belongs, unless it's the only film or the list is
            // unranked, where the end is where it belongs
            if self.movies.count > 1 && self.isRanked {
                self.promptToRank(newMovie)
            }
        }
    }

    /// Unranked lists are collections in no particular order: no comparing, set ranks or Smart Placement
    var isRanked: Bool { ListRanking.isRanked(movieList.id) }

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
        // Dragging a film into place means the user chose its spot
        if AIPlacement.isPlaced(listID: movieList.id, movieID: movie.id) {
            AIPlacement.set(false, listID: movieList.id, movieID: movie.id)
            placementVersion += 1
        }
        // destination counts the moved row's old slot, so moving down lands one place earlier
        let newIndex = destination > from ? destination - 1 : destination
        guard newIndex != from else { return }

        let previous = movies
        movies.move(fromOffsets: source, toOffset: destination)
        for (index, movie) in movies.enumerated() {
            movie.rank = Int32(index + 1)
        }
        try? context.save()
        AppAnalytics.log(.filmRanked(.drag))

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

    /// Reorders the whole list by TMDb user score, highest first, looking up any scores not yet known.
    /// Films TMDb has no score for keep their order at the end. Puts the old order back if the server can't save it
    func sortByRating(completion: @escaping () -> Void = {}) {
        isSorting = true
        MovieInfoCache.shared.fetchMissing(movies.map { Int64($0.tmdb_id) }, onBatch: {}, completion: {
            DispatchQueue.main.async {
                self.isSorting = false
                self.applyRatingOrder()
                completion()
            }
        })
    }

    private func applyRatingOrder() {
        let score = { (movie: CDMovie) -> Double? in
            guard let info = self.info(of: movie), info.voteCount > 0 else { return nil }
            return info.voteAverage
        }
        let previous = movies
        let sorted = previous.enumerated().sorted { a, b in
            switch (score(a.element), score(b.element)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        guard sorted != previous else { return }

        withAnimation(Theme.spring) {
            movies = sorted
            for (index, movie) in sorted.enumerated() {
                movie.rank = Int32(index + 1)
                // The new spots come from TMDb, not the AI
                AIPlacement.set(false, listID: movieList.id, movieID: movie.id)
            }
        }
        placementVersion += 1
        try? context.save()

        APIService.shared.setListOrder(listID: movieList.id, movieIDs: sorted.map(\.id)) { saved in
            guard !saved else { return }
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

    /// Adds a film from this list to other lists, at the bottom of each. Calls back with the lists it was
    /// added to and the new copy in each, in the order given. The film is already saved, so only its TMDb id goes
    func addCopy(of movie: CDMovie, to lists: [CDMovieList], completion: @escaping ([(list: CDMovieList, movie: CDMovie)]) -> Void) {
        let tmdbID = Int64(movie.tmdb_id)
        var added: [Int: CDMovie] = [:]
        let group = DispatchGroup()
        for (index, list) in lists.enumerated() {
            group.enter()
            list.addMovie(tmdbID: tmdbID, context: context) { newMovie in
                added[index] = newMovie
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !added.isEmpty { AppAnalytics.log(.filmAdded(.otherList)) }
            completion(lists.indices.compactMap { index in added[index].map { (list: lists[index], movie: $0) } })
        }
    }

    func isAIPlaced(_ movie: CDMovie) -> Bool {
        _ = placementVersion
        return AIPlacement.isPlaced(listID: movieList.id, movieID: movie.id)
    }

    var hasAIPlacedFilms: Bool {
        movies.contains(where: isAIPlaced)
    }

    /// Asks the AI where the film belongs and moves it there. Calls back on the main thread with a message to
    /// show: where it went, or why it couldn't
    func smartPlace(_ movie: CDMovie, completion: @escaping (String) -> Void) {
        APIService.shared.smartPlace(listID: movieList.id, movieID: movie.id) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let placement):
                    AppAnalytics.log(.aiPickUsed(.smartPlacement))
                    AIPlacement.set(true, listID: self.movieList.id, movieID: movie.id)
                    self.placementVersion += 1
                    self.moveLocally(movie, to: placement.rank)
                    completion("AI placed it at #\(placement.rank)")
                case .failure(let error):
                    switch (error as NSError).code {
                    case 403: completion("Allow AI features in Settings to use Smart Placement")
                    case 429: completion("You've used today's AI requests. It's at the bottom for now")
                    default: completion("Smart Placement didn't work. It's at the bottom for now")
                    }
                }
            }
        }
    }

    /// Keeps a Smart Placement spot as if the user had chosen it
    func approvePlacement(_ movie: CDMovie) {
        AIPlacement.set(false, listID: movieList.id, movieID: movie.id)
        placementVersion += 1
        APIService.shared.approvePlacement(listID: movieList.id, movieID: movie.id) { approved in
            if !approved {
                AIPlacement.set(true, listID: self.movieList.id, movieID: movie.id)
                self.placementVersion += 1
            }
        }
    }

    func updateMovieRanking(updatedMovie: CDMovie, newRank: Int) {
        APIService.shared.updateMovieRanking(list_id: movieList.id, movie_id: updatedMovie.id, rank: newRank) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    print("updated db rankings")
                    // Moving a film yourself means you chose its spot
                    if AIPlacement.isPlaced(listID: self.movieList.id, movieID: updatedMovie.id) {
                        AIPlacement.set(false, listID: self.movieList.id, movieID: updatedMovie.id)
                        self.placementVersion += 1
                    }
                    self.moveLocally(updatedMovie, to: newRank)
                case .failure(let error):
                    print("error updating movie rank:", error)
                }
            }
        }
    }

    /// Puts a film at a rank on the phone after the server has moved it, renumbering the rest
    private func moveLocally(_ updatedMovie: CDMovie, to newRank: Int) {
        var reordered = Array(movieList.movies).sorted(by: { $0.rank < $1.rank })
        reordered.removeAll { $0.id == updatedMovie.id }
        reordered.insert(updatedMovie, at: min(max(newRank - 1, 0), reordered.count))

        // Reassign correct rankings for all movies, sliding rows into their new places
        withAnimation(Theme.spring) {
            movies = reordered
            for (index, movie) in movies.enumerated() {
                movie.rank = Int32(index + 1)
            }
        }
        movieList.movies = Set(movies)
        movedMovieID = updatedMovie.id
        do {
            try context.save()
        } catch {
            print("Error saving Core Data:", error)
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
        if watched { AppAnalytics.log(.filmWatched(.list)) }
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
    /// Saves the user's note on a film (empty deletes it). Like watched, the note belongs to the film rather
    /// than the list, so every list's copy is updated. Calls back with nil once the server saved it, or a message
    /// to show; on failure the old note is put back. A saved note moderation flags is marked as under review
    func setNote(_ movie: CDMovie, _ note: String, completion: @escaping (String?) -> Void = { _ in }) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CDMovie.fetchRequest()
        request.predicate = NSPredicate(format: "id == %lld", movie.id)
        let copies = (try? context.fetch(request)) ?? [movie]
        let previous = copies.map { ($0, $0.note) }
        objectWillChange.send()
        copies.forEach { $0.note = trimmed.isEmpty ? nil : trimmed }
        saveContext()

        APIService.shared.setMovieNote(movie_id: movie.id, note: trimmed) { result in
            switch result {
            case .success(let underReview):
                NoteReview.shared.set(underReview, movieID: movie.id)
                completion(nil)
            case .failure(let error):
                print("Error saving note:", error)
                self.objectWillChange.send()
                previous.forEach { copy, note in copy.note = note }
                self.saveContext()
                completion(error.serverMessage ?? "Couldn't save your note. Check your connection and try again.")
            }
        }
    }

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
