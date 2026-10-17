//
//  PersistenceContainer.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation
import CoreData

struct PersistenceController {
    
    static let shared = PersistenceController()
    
    let container: NSPersistentContainer
    
    init(inMemory: Bool = false) {
        self.container = NSPersistentContainer(name: "MovieListModel")
        
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                fatalError("Error loading container: \(error), \(error.userInfo)")
            }
        }
    }
    
    func fetchAllCoreDataObjects(firebase_id: String) {
        let context = container.viewContext
        
        APIService.shared.fetchData(firebase_id: firebase_id) { result in
            DispatchQueue.main.async {
                switch result {
                case .success (let listResponses):
                    for listResponse in listResponses {
                        PersistenceController.insert(listResponse, into: context)
                    }
                    do {
                        try context.save()
                    } catch {
                        print("Failed to save context", error)
                    }
                case .failure(let error):
                    print("Error deleting:", error)
                }
            }
        }
    }
    
    @discardableResult
    static func insert(_ listResponse: ListDetailsResponse, into context: NSManagedObjectContext) -> CDMovieList {
        let curList = CDMovieList(id: listResponse.id, name: listResponse.name, overview: listResponse.overview, context: context)
        // Keep the server's dates rather than the time of this sync
        if let created = parseServerDate(listResponse.creation_date) {
            curList.creation_date = created
        }
        if let modified = parseServerDate(listResponse.date_modified) {
            curList.date_modified = modified
        }
        for movieResponse in listResponse.movies {
            do {
                let curMovie = try CDMovie(id: movieResponse.id, tmdb_id: Int32(movieResponse.tmdb_id)!, title: movieResponse.title, release_date: movieResponse.release_date, overview: movieResponse.overview, rank: Int32(movieResponse.rank), poster_path: movieResponse.poster_path, original_language: movieResponse.original_language, popularity: movieResponse.popularity, context: context)
                curMovie.watched = movieResponse.watched ?? false
                curList.addToMovies_(curMovie)
            } catch {
                print("Failed to create CD Movie", error)
            }
        }
        return curList
    }
    
    // The backend sends timestamps like "2026-10-17T06:52:17.123Z"
    private static func parseServerDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    func deleteAllCoreDataObjects() {
        let context = container.viewContext
        let persistentStoreCoordinator = context.persistentStoreCoordinator
        
        guard let storeCoordinator = persistentStoreCoordinator else { return }
        
        for store in storeCoordinator.persistentStores {
            do {
                let entityNames = storeCoordinator.managedObjectModel.entities.compactMap { $0.name }
                
                for entityName in entityNames {
                    let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                    
                    try context.execute(deleteRequest)
                }
                
                try context.save()
                print("✅ All Core Data objects deleted successfully.")
            } catch {
                print("❌ Error deleting Core Data objects: \(error.localizedDescription)")
            }
        }
    }
    
    func saveContext() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nserror = error as NSError
                fatalError("Unresolved error \(nserror)")
            }
        }
    }
    
    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        
        let movie = try! CDMovie(id: 1, tmdb_id: Int32(Int64(615777)), title: "Babylon", release_date: "2022-12-22", overview: "A tale of outsized ambition and outrageous excess, tracing the rise and fall of multiple characters in an era of unbridled decadence and depravity during Hollywood's transition from silent films to sound films in the late 1920s.", rank: 1, poster_path: "/wjOHjWCUE0YzDiEzKv8AfqHj3ir.jpg", original_language: "en", popularity: 283.072, context: context)
        
        let movieList = CDMovieList(id: Int64(1), name: "Christmas Movies", overview: "", context: context)
        
        return controller
    }()
}
