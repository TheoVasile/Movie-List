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
    
    convenience init(name: String, overview: String, context: NSManagedObjectContext) {
        self.init(context: context)
        self.id = UUID()
        self.name = name
        
        self.creation_date = Date.now
        self.date_modified = Date.now
        
        self.overview = overview
    }
    
    static func delete(movieList: CDMovieList) {
        guard let context = movieList.managedObjectContext else { return }
        
        context.delete(movieList)
    }
    
    static func fetch(predicate: NSPredicate = .all) -> NSFetchRequest<CDMovieList> {
        let request = CDMovieList.fetchRequest()
        request.fetchLimit = 20
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMovieList.date_modified, ascending: true)]
        request.predicate = predicate
        
        return request
    }
    
    static var example: CDMovieList {
        let context =  PersistenceController.preview.container.viewContext
        let movieList = CDMovieList(name: "Christmas Movies", overview: "", context: context)
        
        guard let movie1 = try? CDMovie(id: 615777, title: "Babylon", release_date: "2022-12-22", overview: "A tale of outsized ambition and outrageous excess, tracing the rise and fall of multiple characters in an era of unbridled decadence and depravity during Hollywood's transition from silent films to sound films in the late 1920s.", rank: 1, poster_path: "/wjOHjWCUE0YzDiEzKv8AfqHj3ir.jpg", original_language: "en", popularity: 283.072, context: context) else {
                fatalError("Failed to initialize the movie entity properly.")
        }
        guard let movie2 = try? CDMovie(id: 615777, title: "Inglorious Basterds", release_date: "2009-12-22", overview: "In Nazi-occupied France during World War II, a plan to assassinate Nazi leaders by a group of Jewish U.S. soldiers coincides with a theatre owner's vengeful plans for the same.", rank: 2, poster_path: "", original_language: "en", popularity: 283.072, context: context) else {
                fatalError("Failed to initialize the movie entity properly.")
        }
        
        // movieList.movies.insert(movie)
        movieList.addToMovies_(movie1)
        movie1.addToList(movieList)
        
        movieList.addToMovies_(movie2)
        movie2.addToList(movieList)
        
        
        return movieList
    }
}
