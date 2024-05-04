//
//  CDMovieList+helper.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation
import CoreData


extension CDMovieList {
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
    
    static func fetch(_ predicate: NSPredicate = .all) -> NSFetchRequest<CDMovieList> {
        let request = CDMovieList.fetchRequest()
        request.fetchLimit = 20
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMovieList.date_modified, ascending: true)]
        request.predicate = predicate
        
        return request
    }
    
    static var example: CDMovieList {
        let context =  PersistenceController.preview.container.viewContext
        let movieList = CDMovieList(name: "Christmas Movies", overview: "", context: context)
        
        return movieList
    }
}
