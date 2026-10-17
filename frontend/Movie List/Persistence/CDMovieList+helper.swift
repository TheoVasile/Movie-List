//
//  CDMovieList+helper.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation
import CoreData


extension CDMovieList {
    
    var movies: Set<CDMovie> {
        get { (movies_ as? Set<CDMovie>) ?? [] }
        set { movies_ = newValue as NSSet }
    }
    
    convenience init(id: Int64, name: String, overview: String, context: NSManagedObjectContext) {
        self.init(context: context)
        self.id = id
        self.name = name
        
        self.creation_date = Date.now
        self.date_modified = Date.now
        
        self.overview = overview
    }
    
    /// Saves a TMDb movie on the backend, adds it to the bottom of this list, and mirrors it in Core Data.
    /// Calls back on the main thread with the new movie, or nil if any step failed.
    func addMovie(_ networkMovie: Movie, context: NSManagedObjectContext, completion: @escaping (CDMovie?) -> Void = { _ in }) {
        APIService.shared.createMovie(tmdb_id: networkMovie.id, title: networkMovie.title, release_date: networkMovie.release_date, overview: networkMovie.overview, poster_path: networkMovie.poster_path ?? "", original_language: networkMovie.original_language, popularity: networkMovie.popularity) { result in
            switch result {
            case .success(let movieResponse):
                let rank = self.movies.count + 1
                APIService.shared.addMovieToList(list_id: self.id, movie_id: movieResponse.id, rank: rank) { result in
                    switch result {
                    case .success:
                        // A release date the app can't parse would otherwise crash here
                        guard let tmdbID = Int32(movieResponse.tmdb_id),
                              let newMovie = try? CDMovie(
                                id: movieResponse.id,
                                tmdb_id: tmdbID,
                                title: movieResponse.title,
                                release_date: movieResponse.release_date,
                                overview: movieResponse.overview,
                                rank: Int32(rank),
                                poster_path: movieResponse.poster_path,
                                original_language: movieResponse.original_language,
                                popularity: movieResponse.popularity,
                                context: context) else {
                            print("Couldn't create a local copy of", movieResponse.title)
                            completion(nil)
                            return
                        }
                        self.addToMovies_(newMovie)
                        self.date_modified = Date.now
                        do {
                            try context.save()
                        } catch {
                            print("Error saving context: \(error)")
                        }
                        completion(newMovie)
                    case .failure(let error):
                        print("Error adding movie to list:", error.localizedDescription)
                        completion(nil)
                    }
                }
            case .failure(let error):
                print("Error creating movie:", error.localizedDescription)
                completion(nil)
            }
        }
    }

    static func delete(movieList: CDMovieList) {
        guard let context = movieList.managedObjectContext else { return }
        
        context.delete(movieList)
        
        do {
            try context.save() // Save changes to persist the deletion
            print("✅ Movie list deleted successfully.")
        } catch {
            print("❌ Error deleting movie list:", error.localizedDescription)
        }
    }
    
    static func fetch(predicate: NSPredicate = .all) -> NSFetchRequest<CDMovieList> {
        let request = CDMovieList.fetchRequest()
        // Creation order stays put as films are added; date_modified changes with every addition
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMovieList.creation_date, ascending: true)]
        request.predicate = predicate
        
        return request
    }
    
    static var example: CDMovieList {
        let context =  PersistenceController.preview.container.viewContext
        let movieList = CDMovieList(id: Int64(1), name: "Christmas Movies", overview: "", context: context)
        
        guard let movie1 = try? CDMovie(id: 1, tmdb_id: 615777, title: "Babylon", release_date: "2022-12-22", overview: "A tale of outsized ambition and outrageous excess, tracing the rise and fall of multiple characters in an era of unbridled decadence and depravity during Hollywood's transition from silent films to sound films in the late 1920s.", rank: 1, poster_path: "/wjOHjWCUE0YzDiEzKv8AfqHj3ir.jpg", original_language: "en", popularity: 283.072, context: context) else {
                fatalError("Failed to initialize the movie entity properly.")
        }
        guard let movie2 = try? CDMovie(id: 2, tmdb_id: 615777, title: "Inglorious Basterds", release_date: "2009-12-22", overview: "In Nazi-occupied France during World War II, a plan to assassinate Nazi leaders by a group of Jewish U.S. soldiers coincides with a theatre owner's vengeful plans for the same.", rank: 2, poster_path: "/7sfbEnaARXDDhKm0CZ7D7uc2sbo.jpg", original_language: "en", popularity: 283.072, context: context) else {
                fatalError("Failed to initialize the movie entity properly.")
        }
        guard let movie3 = try? CDMovie(id: 3, tmdb_id: 615777, title: "Elf", release_date: "1999-12-22", overview: "Will Ferrel Funny", rank: 3, poster_path: "/oOleziEempUPu96jkGs0Pj6tKxj.jpg", original_language: "en", popularity: 283.072, context: context) else {
                fatalError("Failed to initialize the movie entity properly.")
        }
        
        
        // movieList.movies.insert(movie)
        movieList.addToMovies_(movie1)
        movie1.addToList(movieList)
        
        movieList.addToMovies_(movie2)
        movie2.addToList(movieList)
        
        movieList.addToMovies_(movie3)
        movie3.addToList(movieList)
        
        
        return movieList
    }
}
