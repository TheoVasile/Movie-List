//
//  CDMovieList+helper.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation
import CoreData


extension CDMovieList {
    convenience init(name: String, creation_date: Date, overview: String, context: NSManagedObjectContext) {
        self.init(context: context)
        self.id = UUID()
        self.name = name
        
        self.creation_date = creation_date
        
        self.overview = overview
    }
    convenience init(name: String, creation_date: String, overview: String, context: NSManagedObjectContext) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let date = dateFormatter.date(from: creation_date)!
        
        self.init(name: name, creation_date: date, overview: overview, context: context)
    }
    
    static func delete(movieList: CDMovieList) {
        guard let context = movieList.managedObjectContext else { return }
        
        context.delete(movieList)
    }
    
    static func fetch(_ predicate: NSPredicate = .all) -> NSFetchRequest<CDMovieList> {
        let request = CDMovieList.fetchRequest()
        request.fetchLimit = 20
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMovieList.name, ascending: true)]
        request.predicate = predicate
        
        return request
    }
    
    static var example: CDMovieList {
        let context =  PersistenceController.preview.container.viewContext
        let movieList = CDMovieList(name: "Christmas Movies", creation_date: "2024-04-20", overview: "", context: context)
        
        return movieList
    }
}
