//
//  CDMovie+helper.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation
import CoreData

enum cdmovieError : Error {
    case nilValueFound(String);
}

extension CDMovie {
    
    convenience init(id: Int64, tmdb_id: Int32, title: String, release_date: Date, overview: String, rank: Int32, poster_path: String, original_language: String, popularity: Double, context: NSManagedObjectContext) {
        self.init(context: context)
        self.id = id
        self.tmdb_id = tmdb_id
        self.title = title
        self.rank = rank
        self.release_date = release_date
        self.overview = overview
        self.original_language = original_language
        self.popularity = popularity
        self.poster_path = poster_path
    }
    
    convenience init(id: Int64, tmdb_id: Int32, title: String, release_date: String, overview: String, rank: Int32, poster_path: String, original_language: String, popularity: Double, context: NSManagedObjectContext) throws {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard let formattedDate: Date = dateFormatter.date(from: release_date) else { throw cdmovieError.nilValueFound("Improper date submitted for movie") }
        
        self.init(id: id, tmdb_id: tmdb_id, title: title, release_date: formattedDate, overview: overview, rank: rank, poster_path: poster_path, original_language: original_language, popularity: popularity, context: context)
    }
    
    func get_date() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd" // Ensures only the date is shown
        return release_date.map { dateFormatter.string(from: $0) } ?? "None"
    }
    
    static func delete(movie: CDMovie) {
        guard let context = movie.managedObjectContext else { return }
        
        context.delete(movie)
    }
    
    static func fetch(_ predicate: NSPredicate = .all) -> NSFetchRequest<CDMovie> {
        let request = CDMovie.fetchRequest()
        request.fetchLimit = 20
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMovie.popularity, ascending: true), NSSortDescriptor(keyPath: \CDMovie.release_date, ascending: true), NSSortDescriptor(keyPath: \CDMovie.title, ascending: true)]
        request.predicate = predicate
        
        return request
    }
    
    static var example: CDMovie {
        get {
            let context = PersistenceController.preview.container.viewContext
            let movie = try! CDMovie(id: 1, tmdb_id: 615777, title: "Babylon", release_date: "2022-12-22", overview: "A tale of outsized ambition and outrageous excess, tracing the rise and fall of multiple characters in an era of unbridled decadence and depravity during Hollywood's transition from silent films to sound films in the late 1920s.", rank: 1, poster_path: "/wjOHjWCUE0YzDiEzKv8AfqHj3ir.jpg", original_language: "en", popularity: 283.072, context: context)
            return movie
        }
    }
}
