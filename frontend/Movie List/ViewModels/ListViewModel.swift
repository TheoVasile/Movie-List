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
        if let index = movies.firstIndex(where: { $0.id == updatedMovie.id }) {
            movies[index] = updatedMovie
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
