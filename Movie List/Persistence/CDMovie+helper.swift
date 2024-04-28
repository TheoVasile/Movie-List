//
//  CDMovie+helper.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation
import CoreData

extension CDMovie {
    var user_rating: Float {
        get { user_rating_ ?? 2.5 }
        set { user_rating_ = newValue }
    }
    
    convenience init(id: Int64, title: String, release_date: String, overview: String, rank: Int32, poster_path: String, original_language: String, popularity: Float, context: NSManagedObjectContext) {
        self.init(context: context)
        self.id = id
        self.title = title
        
        let stringDate = "2022-12-22"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let date = dateFormatter.date(from: stringDate)
        self.release_date = date
        
        self.overview = overview
        self.original_language = original_language
        self.popularity = popularity
    }
    
    static var example: CDMovie {
        let context = PersistenceController.preview.container.viewContext
        let movie = CDMovie(id: 615777, title: "Babylon", release_date: "2022-12-22", overview: "A tale of outsized ambition and outrageous excess, tracing the rise and fall of multiple characters in an era of unbridled decadence and depravity during Hollywood's transition from silent films to sound films in the late 1920s.", rank: 1, poster_path: "/wjOHjWCUE0YzDiEzKv8AfqHj3ir.jpg", original_language: "en", popularity: 283.072, context: context)
        return movie
    }
}
