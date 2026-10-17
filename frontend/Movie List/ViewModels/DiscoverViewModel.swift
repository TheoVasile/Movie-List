//
//  DiscoverViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI
import CoreData

/// What Discover has learned from the user's swipes. Kept on this device only, as TMDb film ids and
/// a score per genre: liking a film raises its genres' scores, passing lowers them a little
struct TasteProfile: Codable {
    private(set) var genreScores: [Int: Double] = [:]
    // Most recent first
    private(set) var likedMovieIDs: [Int64] = []
    private(set) var swipeCount = 0

    static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary",
        18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Science Fiction", 10770: "TV Movie", 53: "Thriller",
        10752: "War", 37: "Western",
    ]

    mutating func record(_ movie: Movie, liked: Bool) {
        // Every swipe makes older ones count a little less, so the profile follows changing taste
        for genre in genreScores.keys {
            genreScores[genre]! *= 0.97
        }
        // A pass can mean "seen it" or "not tonight", so it counts for much less than a like
        for genre in movie.genre_ids ?? [] {
            genreScores[genre, default: 0] += liked ? 1 : -0.35
        }
        if liked {
            likedMovieIDs.removeAll { $0 == movie.id }
            likedMovieIDs = Array(([movie.id] + likedMovieIDs).prefix(20))
        }
        swipeCount += 1
    }

    var favoriteGenres: [Int] {
        genreScores.filter { $0.value >= 1.5 }.sorted { $0.value > $1.value }.prefix(3).map(\.key)
    }

    var avoidedGenres: [Int] {
        genreScores.filter { $0.value <= -1.5 }.sorted { $0.value < $1.value }.prefix(3).map(\.key)
    }

    /// How well a film's genres match the profile; 0 when nothing is known yet
    func affinity(for movie: Movie) -> Double {
        let genres = movie.genre_ids ?? []
        guard !genres.isEmpty else { return 0 }
        // Divided by √count so a film isn't favoured just for listing many genres
        return genres.reduce(0) { $0 + (genreScores[$1] ?? 0) } / Double(genres.count).squareRoot()
    }
}

class DiscoverViewModel: ObservableObject {
    /// Cards still to swipe, top card first
    @Published private(set) var deck: [Movie] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var isExhausted = false
    @Published private(set) var profile: TasteProfile

    private var page = 1
    // Every film in the user's lists, weighted by how highly it's ranked
    private var seedPool: [(id: Int64, weight: Double)] = []
    // Films already used as seeds, so each batch draws on different ones
    private var usedSeeds: Set<Int64> = []
    // TMDb ids of every film already in one of the user's lists
    private var listedIDs: Set<Int64> = []
    // Films swiped left, remembered across launches so they don't come back
    private var passedIDs: Set<Int64>

    private static let passedKey = "discover.passedMovieIDs"
    private static let profileKey = "discover.tasteProfile"
    private static let maxPages = 30
    private static let refillThreshold = 5

    init() {
        let stored = UserDefaults.standard.array(forKey: Self.passedKey) as? [Int] ?? []
        passedIDs = Set(stored.map(Int64.init))
        profile = UserDefaults.standard.data(forKey: Self.profileKey)
            .flatMap { try? JSONDecoder().decode(TasteProfile.self, from: $0) } ?? TasteProfile()
    }

    private static let seedsPerBatch = 6
    private static let likedSeedsPerBatch = 2

    /// Picks the films to base the next batch on: up to two recently liked films, plus a rank-weighted
    /// sample from the whole collection. Favourites are likelier, but any film can be picked, and no film
    /// is used again until the rest have been, so one film can't steer the whole deck
    private func nextSeeds() -> [Int64] {
        let liked = Array(profile.likedMovieIDs.filter { !usedSeeds.contains($0) }.prefix(Self.likedSeedsPerBatch))
        var available = seedPool.filter { !usedSeeds.contains($0.id) && !liked.contains($0.id) }
        if available.count < Self.seedsPerBatch {
            // Every film has had a turn, so start over
            usedSeeds = []
            available = seedPool.filter { !liked.contains($0.id) }
        }
        // Weighted sampling without replacement: each film draws random^(1/weight), and the highest draws win
        let sampled = available
            .map { (id: $0.id, key: pow(Double.random(in: Double.leastNonzeroMagnitude...1), 1 / $0.weight)) }
            .sorted { $0.key > $1.key }
            .prefix(Self.seedsPerBatch)
            .map(\.id)
        let seeds = liked + sampled
        usedSeeds.formUnion(seeds)
        return seeds
    }

    var topMovie: Movie? { deck.first }

    /// Call whenever the user's lists change, so cards for films they've since added disappear
    func update(listedIDs: Set<Int64>, seedPool: [(id: Int64, weight: Double)]) {
        self.listedIDs = listedIDs
        self.seedPool = seedPool
        deck.removeAll { listedIDs.contains($0.id) }
        refillIfNeeded()
    }

    func pass(_ movie: Movie) {
        deck.removeAll { $0.id == movie.id }
        passedIDs.insert(movie.id)
        UserDefaults.standard.set(passedIDs.map { Int($0) }, forKey: Self.passedKey)
        learn(from: movie, liked: false)
        refillIfNeeded()
    }

    /// Removes the card straight away; if saving fails, the card comes back on top
    func add(_ movie: Movie, to list: CDMovieList, context: NSManagedObjectContext, completion: @escaping (CDMovie?) -> Void) {
        deck.removeAll { $0.id == movie.id }
        listedIDs.insert(movie.id)
        learn(from: movie, liked: true)
        refillIfNeeded()
        list.addMovie(movie, context: context) { newMovie in
            if newMovie == nil {
                withAnimation(Theme.spring) {
                    self.listedIDs.remove(movie.id)
                    self.deck.insert(movie, at: 0)
                }
            }
            completion(newMovie)
        }
    }

    func showSkippedAgain() {
        usedSeeds = []
        passedIDs = []
        UserDefaults.standard.removeObject(forKey: Self.passedKey)
        page = 1
        isExhausted = false
        deck = []
        loadMore()
    }

    /// Forgets everything learned from swipes and starts the deck over
    func resetProfile() {
        usedSeeds = []
        profile = TasteProfile()
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        page = 1
        isExhausted = false
        deck = []
        loadMore()
    }

    private func learn(from movie: Movie, liked: Bool) {
        profile.record(movie, liked: liked)
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
    }

    func retry() {
        loadFailed = false
        loadMore()
    }

    // Puts the films that best match the profile first, while spreading out similar ones: each genre a
    // film shares with the two cards before it counts against it. The server's order still counts a little
    private func orderedByTaste(_ movies: [Movie]) -> [Movie] {
        var remaining = movies.enumerated().map {
            (movie: $0.element, score: profile.affinity(for: $0.element) - Double($0.offset) * 0.05)
        }
        var ordered: [Movie] = []
        var recentGenres: [Set<Int>] = []
        while !remaining.isEmpty {
            let recent = recentGenres.suffix(2).reduce(into: Set<Int>()) { $0.formUnion($1) }
            func adjusted(_ candidate: (movie: Movie, score: Double)) -> Double {
                candidate.score - 0.6 * Double(recent.intersection(candidate.movie.genre_ids ?? []).count)
            }
            let best = remaining.indices.max { adjusted(remaining[$0]) < adjusted(remaining[$1]) }!
            let pick = remaining.remove(at: best)
            ordered.append(pick.movie)
            recentGenres.append(Set(pick.movie.genre_ids ?? []))
        }
        return ordered
    }

    private func refillIfNeeded() {
        if deck.count < Self.refillThreshold {
            loadMore()
        }
    }

    private func loadMore() {
        guard !isLoading, !isExhausted, !loadFailed else { return }
        isLoading = true
        APIService.shared.discoverMovies(seeds: nextSeeds(), genres: profile.favoriteGenres, avoidGenres: profile.avoidedGenres, page: page) { result in
            self.isLoading = false
            switch result {
            case .success(let movies):
                self.page += 1
                let fresh = movies.filter { movie in
                    !self.listedIDs.contains(movie.id)
                        && !self.passedIDs.contains(movie.id)
                        && !self.deck.contains { $0.id == movie.id }
                }
                withAnimation(Theme.spring) {
                    self.deck.append(contentsOf: self.orderedByTaste(fresh))
                }
                if movies.isEmpty || self.page > Self.maxPages {
                    self.isExhausted = true
                } else {
                    // Most of a page can be filtered out, so keep going until there's a few cards ready
                    self.refillIfNeeded()
                }
            case .failure(let error):
                print("Discover error:", error.localizedDescription)
                self.loadFailed = true
            }
        }
    }
}
