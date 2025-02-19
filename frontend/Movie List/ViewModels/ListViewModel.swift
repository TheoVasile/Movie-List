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
                            managedObjectContext.delete(poppedMovie)
                            self.movies = Array(self.movieList.movies).sorted(by: { $0.rank < $1.rank })
                            self.movies.remove(at: index)
                            for (i, m) in self.movies.enumerated() {
                                m.rank = Int32(i+1)
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
            print("COUNTS", movies.count)
            APIService.shared.createMovie(tmdb_id: networkMovie.id, title: networkMovie.title, release_date: networkMovie.release_date, overview: networkMovie.overview, poster_path: networkMovie.poster_path ?? "", original_language: networkMovie.original_language, popularity: networkMovie.popularity) { result in
                switch result {
                    case .success(let movieResponse):
                    APIService.shared.addMovieToList(list_id: self.movieList.id, movie_id: movieResponse.id, rank: self.movies.count + 1) { result in
                        switch result {
                        case .success:
                            print("succesfully added movie to list")
                            let newMovie = try! CDMovie(
                                id: movieResponse.id,
                                tmdb_id: Int32(movieResponse.tmdb_id)!,
                                title: movieResponse.title,
                                release_date: movieResponse.release_date,
                                overview: movieResponse.overview,
                                rank: Int32(self.movies.count + 1),
                                poster_path: movieResponse.poster_path,
                                original_language: movieResponse.original_language,
                                popularity: movieResponse.popularity,
                                context: self.context)
                            self.movieList.addToMovies_(newMovie)
                            self.movies = Array(self.movieList.movies).sorted(by: { $0.rank < $1.rank })
                            
                            do {
                                print("saving context")
                                try self.context.save()
                            } catch {
                                print("Error saving context: \(error)")
                            }
                        case .failure(let error):
                            print(error.localizedDescription)
                        }
                    }
                case .failure(let error):
                    print("❌ Backend request failed, deleting from Core Data:", error.localizedDescription)
                }
            }
        }
    
    func updateMovieRanking(updatedMovie: CDMovie, newRank: Int) {
        APIService.shared.updateMovieRanking(list_id: movieList.id, movie_id: updatedMovie.id, rank: newRank) { result in
            switch result {
                case .success:
                    print("updated db rankings")
                    // ✅ Ensure Core Data context exists
                    /*guard let context = updatedMovie.managedObjectContext else {
                        print("❌ Error: No Core Data context found")
                        return
                    }*/
                    updatedMovie.rank = Int32(newRank)  // ✅ Update selected movie's rank

                    // ✅ Convert NSSet to sorted array
                    self.movies = Array(self.movieList.movies).sorted(by: { $0.rank < $1.rank })

                    // ✅ Remove the movie from the list
                    self.movies.removeAll { $0.id == updatedMovie.id }

                    // ✅ Insert the movie at the new rank
                    self.movies.insert(updatedMovie, at: newRank - 1)

                    // ✅ Reassign correct rankings for all movies
                    for (index, movie) in self.movies.enumerated() {
                        movie.rank = Int32(index + 1)
                    }

                    // ✅ Update movieList's relationship
                    self.movieList.movies = Set(self.movies)

                    // ✅ Save changes to Core Data
                    DispatchQueue.main.async {
                        do {
                            try self.context.save()
                            print("✅ Core Data rankings updated successfully")
                        } catch {
                            print("❌ Error saving Core Data:", error)
                        }
                    }
                case .failure(let error):
                    print("error updating movie rank:", error)
                }
        }
    }
    
    func searchMovies() {
        if newMovieSearchText.isEmpty { return }
        APIService.shared.searchMovies(name: newMovieSearchText) { result in
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
