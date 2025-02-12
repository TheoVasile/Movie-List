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
    @Published var searchText: String = ""
    
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
                            managedObjectContext.delete(poppedMovie)
                            do {
                                try managedObjectContext.save()
                                self.movies.remove(at: index) // Remove from UI
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
    
    func updateMovieRanking(updatedMovie: CDMovie, newRank: Int) {
        APIService.shared.updateMovieRanking(list_id: movieList.id, movie_id: updatedMovie.id, rank: newRank) { result in
            switch result {
                case .success:
                    print("updated db rankings")
                    // ✅ Ensure Core Data context exists
                    guard let context = updatedMovie.managedObjectContext else {
                        print("❌ Error: No Core Data context found")
                        return
                    }

                    let oldRank = Int(updatedMovie.rank)
                    updatedMovie.rank = Int32(newRank)  // ✅ Update selected movie's rank

                    // ✅ Convert NSSet to sorted array
                    var movies = Array(self.movieList.movies).sorted(by: { $0.rank < $1.rank })

                    // ✅ Remove the movie from the list
                    movies.removeAll { $0.id == updatedMovie.id }

                    // ✅ Insert the movie at the new rank
                    movies.insert(updatedMovie, at: newRank - 1)

                    // ✅ Reassign correct rankings for all movies
                    for (index, movie) in movies.enumerated() {
                        movie.rank = Int32(index + 1)
                    }

                    // ✅ Update movieList's relationship
                    self.movieList.movies = Set(movies)

                    // ✅ Save changes to Core Data
                    do {
                        try context.save()
                        print("✅ Core Data rankings updated successfully")
                    } catch {
                        print("❌ Error saving Core Data:", error.localizedDescription)
                    }
                case .failure(let error):
                    print("error updating movie rank:", error)
                }
        }
    }
    
    func searchMovies() {
        if searchText.isEmpty { return }
        APIService.shared.searchMovies(name: searchText) { result in
            DispatchQueue.main.async {
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
