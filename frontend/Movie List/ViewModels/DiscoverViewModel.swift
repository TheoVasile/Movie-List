//
//  DiscoverViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI
import CoreData

class DiscoverViewModel: ObservableObject {
    /// Cards still to swipe, top card first
    @Published private(set) var deck: [Movie] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var isExhausted = false

    private var page = 1
    private var seeds: [Int64] = []
    // TMDb ids of every film already in one of the user's lists
    private var listedIDs: Set<Int64> = []
    // Films swiped left, remembered across launches so they don't come back
    private var passedIDs: Set<Int64>

    private static let passedKey = "discover.passedMovieIDs"
    private static let maxPages = 30
    private static let refillThreshold = 5

    init() {
        let stored = UserDefaults.standard.array(forKey: Self.passedKey) as? [Int] ?? []
        passedIDs = Set(stored.map(Int64.init))
    }

    var topMovie: Movie? { deck.first }

    /// Call whenever the user's lists change, so cards for films they've since added disappear
    func update(listedIDs: Set<Int64>, seeds: [Int64]) {
        self.listedIDs = listedIDs
        self.seeds = seeds
        deck.removeAll { listedIDs.contains($0.id) }
        refillIfNeeded()
    }

    func pass(_ movie: Movie) {
        deck.removeAll { $0.id == movie.id }
        passedIDs.insert(movie.id)
        UserDefaults.standard.set(passedIDs.map { Int($0) }, forKey: Self.passedKey)
        refillIfNeeded()
    }

    /// Removes the card straight away; if saving fails, the card comes back on top
    func add(_ movie: Movie, to list: CDMovieList, context: NSManagedObjectContext, completion: @escaping (CDMovie?) -> Void) {
        deck.removeAll { $0.id == movie.id }
        listedIDs.insert(movie.id)
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
        passedIDs = []
        UserDefaults.standard.removeObject(forKey: Self.passedKey)
        page = 1
        isExhausted = false
        deck = []
        loadMore()
    }

    func retry() {
        loadFailed = false
        loadMore()
    }

    private func refillIfNeeded() {
        if deck.count < Self.refillThreshold {
            loadMore()
        }
    }

    private func loadMore() {
        guard !isLoading, !isExhausted, !loadFailed else { return }
        isLoading = true
        APIService.shared.discoverMovies(seeds: seeds, page: page) { result in
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
                    self.deck.append(contentsOf: fresh)
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
