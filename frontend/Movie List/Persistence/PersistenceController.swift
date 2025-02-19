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
