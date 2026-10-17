//
//  ListViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation

import SwiftUI
import CoreData

class ListViewModel: ObservableObject {
    @Published var movies: [CDMovie] = []
    @Published var searchResults: [Movie] = []
    @Published var recommendedMovie: CDMovie? = nil
    @Published var showPopup: Bool = false
    @Published var newMovieSearchText: String = ""
    @Published var searchText: String = ""
    @Published var showCompareMovieView = false
    @Published var showSetRank = false
    @Published var selectedMovie: CDMovie? = nil
    
    var movieList: CDMovieList
    private let context: NSManagedObjectContext
    
    init(movieList: CDMovieList, context: NSManagedObjectContext) {
        self.movieList = movieList
        self.context = context
        fetchMovies()
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
            guard newMovie != nil else { return }
            withAnimation(Theme.spring) {
                self.movies = Array(self.movieList.movies).sorted(by: { $0.rank < $1.rank })
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
    
    func recommendMovie() {
        if movies.isEmpty { return }
        recommendedMovie = movies.randomElement() // Simple random recommendation
    }
}
