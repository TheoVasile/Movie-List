//
//  PersistenceContainer.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation
import CoreData
import WidgetKit

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
    
    /// Loads the user's lists from the server into Core Data. Retries while a sleeping server wakes up,
    /// and reports progress and failures through `SyncStatus`
    func fetchAllCoreDataObjects(firebase_id: String) {
        SyncStatus.shared.sync(firebaseID: firebase_id)
    }

    /// Brings Core Data in line with the server's lists: updates lists and films that are already
    /// here, adds new ones and removes ones that are gone. Updating in place rather than starting
    /// over keeps any open list screen pointing at live objects
    func merge(_ responses: [ListDetailsResponse]) {
        let context = container.viewContext
        AIPlacement.replaceAll(from: responses)
        ListSharing.shared.replaceAll(from: responses)
        NoteReview.shared.replaceAll(from: responses)
        let existing = (try? context.fetch(CDMovieList.fetchRequest())) ?? []
        var listsByID: [Int64: CDMovieList] = [:]
        for list in existing {
            // Earlier versions could save a list twice; keep one copy
            if listsByID[list.id] != nil || !responses.contains(where: { $0.id == list.id }) {
                list.movies.forEach(context.delete)
                context.delete(list)
            } else {
                listsByID[list.id] = list
            }
        }
        for response in responses {
            ListVisibility.remember(response.visibility.flatMap(ListVisibility.init) ?? .followers, for: response.id)
            ListRanking.remember(response.is_ranked ?? true, for: response.id)
            if let list = listsByID[response.id] {
                Self.update(list, from: response, in: context)
            } else {
                Self.insert(response, into: context)
            }
        }
        do {
            try context.save()
        } catch {
            print("Failed to save synced lists", error)
        }
        updateWidgets()
        NotificationManager.shared.scheduleSuggestions()
    }

    /// Unwatched films to suggest: from the watchlist (any list with "watch" in its name) if it has any, otherwise
    /// from every list, best ranked first and each film once
    func suggestionCandidates() -> [(tmdbID: Int64, label: String, fromWatchlist: Bool)] {
        let lists = (try? container.viewContext.fetch(CDMovieList.fetchRequest())) ?? []
        let unwatched = { (lists: [CDMovieList]) in lists.flatMap(\.movies).filter { !$0.watched }.sorted { $0.rank < $1.rank } }
        let watchlistFilms = unwatched(lists.filter { ($0.name ?? "").localizedCaseInsensitiveContains("watch") })
        let fromWatchlist = !watchlistFilms.isEmpty
        var seen = Set<Int32>()
        return (fromWatchlist ? watchlistFilms : unwatched(lists))
            .filter { seen.insert($0.tmdb_id).inserted }
            .prefix(60)
            .map { movie in
                let year = Theme.year(from: movie.release_date)
                let title = movie.title ?? ""
                return (Int64(movie.tmdb_id), year.isEmpty ? title : "\(title) (\(year))", fromWatchlist)
            }
    }

    /// Saves what the Home Screen widgets show and asks them to redraw: the top 3 of the biggest list,
    /// and unwatched films from the watchlist (any list with "watch" in its name), or from every list
    func updateWidgets() {
        let lists = (try? container.viewContext.fetch(CDMovieList.fetchRequest())) ?? []
        let film = { (movie: CDMovie) in
            WidgetSnapshot.Film(tmdbID: Int64(movie.tmdb_id), title: movie.title ?? "", year: Theme.year(from: movie.release_date),
                                posterPath: movie.poster_path, rank: Int(movie.rank))
        }
        guard let biggest = lists.max(by: { $0.movies.count < $1.movies.count }), !biggest.movies.isEmpty else {
            WidgetSnapshot.remove()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let watchlists = lists.filter { ($0.name ?? "").localizedCaseInsensitiveContains("watch") }
        let unwatched = (watchlists.isEmpty ? lists : watchlists)
            .flatMap(\.movies)
            .filter { !$0.watched }
            .sorted { $0.rank < $1.rank }
        var seen = Set<Int32>()
        let tonight = unwatched.filter { seen.insert($0.tmdb_id).inserted }.prefix(60).map(film)

        WidgetSnapshot(listName: biggest.name ?? "Your List",
                       top: biggest.movies.sorted { $0.rank < $1.rank }.prefix(3).map(film),
                       tonight: Array(tonight),
                       updated: Date()).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func update(_ list: CDMovieList, from response: ListDetailsResponse, in context: NSManagedObjectContext) {
        list.name = response.name
        list.overview = response.overview
        if let created = parseServerDate(response.creation_date) {
            list.creation_date = created
        }
        if let modified = parseServerDate(response.date_modified) {
            list.date_modified = modified
        }
        var moviesByID: [Int64: CDMovie] = [:]
        for movie in list.movies {
            if moviesByID[movie.id] != nil || !response.movies.contains(where: { $0.id == movie.id }) {
                context.delete(movie)
            } else {
                moviesByID[movie.id] = movie
            }
        }
        for movieResponse in response.movies {
            if let movie = moviesByID[movieResponse.id] {
                movie.rank = Int32(movieResponse.rank)
                movie.title = movieResponse.title
                movie.overview = movieResponse.overview
                movie.poster_path = movieResponse.poster_path
                movie.popularity = movieResponse.popularity
                movie.watched = movieResponse.watched ?? false
                movie.note = movieResponse.note
            } else if let movie = makeMovie(movieResponse, in: context) {
                list.addToMovies_(movie)
            }
        }
    }

    private static func makeMovie(_ movieResponse: MovieDetailsResponse, in context: NSManagedObjectContext) -> CDMovie? {
        do {
            let movie = try CDMovie(id: movieResponse.id, tmdb_id: Int32(movieResponse.tmdb_id)!, title: movieResponse.title, release_date: movieResponse.release_date, overview: movieResponse.overview, rank: Int32(movieResponse.rank), poster_path: movieResponse.poster_path, original_language: movieResponse.original_language, popularity: movieResponse.popularity, context: context)
            movie.watched = movieResponse.watched ?? false
            movie.note = movieResponse.note
            return movie
        } catch {
            print("Failed to create CD Movie", error)
            return nil
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
            if let curMovie = makeMovie(movieResponse, in: context) {
                curList.addToMovies_(curMovie)
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

    // For films that aren't in any list, like Discover's, so screens built for saved films can show them.
    // Nothing made here is ever saved
    private static let scratchContext: NSManagedObjectContext = {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = shared.container.persistentStoreCoordinator
        return context
    }()

    /// A temporary copy of a TMDb film for the film info screen. It has no rank and isn't in any list
    static func preview(of movie: Movie) -> CDMovie {
        scratchContext.reset()
        return preview(of: movie, in: scratchContext)
    }

    // More Like This opens film info on top of film info, again and again, so its copies go in a context that's
    // never reset: resetting would break the info screens still open underneath. Nothing made here is saved either
    private static let stackedContext: NSManagedObjectContext = {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = shared.container.persistentStoreCoordinator
        return context
    }()

    /// A temporary copy of a TMDb film for film info opened from film info, leaving the screens below it alone
    static func stackedPreview(of movie: Movie) -> CDMovie {
        preview(of: movie, in: stackedContext)
    }

    private static func preview(of movie: Movie, in context: NSManagedObjectContext) -> CDMovie {
        let release = (try? CDMovie(id: 0, tmdb_id: Int32(movie.id), title: movie.title, release_date: movie.release_date,
                                    overview: movie.overview, rank: 0, poster_path: movie.poster_path ?? "",
                                    original_language: movie.original_language, popularity: movie.popularity, context: context))
        return release ?? CDMovie(id: 0, tmdb_id: Int32(movie.id), title: movie.title, release_date: Date(), overview: movie.overview,
                                  rank: 0, poster_path: movie.poster_path ?? "", original_language: movie.original_language,
                                  popularity: movie.popularity, context: context)
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

/// Whether the user's lists are loading from the server, and why the last attempt failed. The free
/// server can take most of a minute to wake up, so a failed load is retried a couple of times first
final class SyncStatus: ObservableObject {
    static let shared = SyncStatus()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String? = nil
    @Published private(set) var lastSynced: Date? = nil

    /// Whether the lists are still on their way for the first time, so no lists on the phone doesn't yet mean
    /// the user has none
    var isFirstSync: Bool { lastSynced == nil && (isSyncing || lastError == nil) }

    private static let retryDelays: [TimeInterval] = [2, 5]
    private var waiting: [() -> Void] = []

    /// Loads the lists, calling back on the main thread once it has succeeded or given up. A sync
    /// that's already running is joined rather than started again
    func sync(firebaseID: String, completion: (() -> Void)? = nil) {
        if let completion {
            waiting.append(completion)
        }
        guard !isSyncing else { return }
        isSyncing = true
        attempt(firebaseID: firebaseID, number: 0)
    }

    private func attempt(firebaseID: String, number: Int) {
        APIService.shared.fetchData(firebase_id: firebaseID) { result in
            switch result {
            case .success(let lists):
                PersistenceController.shared.merge(lists)
                self.lastSynced = Date()
                self.lastError = nil
                self.finish()
                // Imports and films added while a milestone couldn't be recorded (offline) are caught here
                Milestones.shared.check()
            case .failure(let error):
                print("Couldn't load lists (attempt \(number + 1)):", error.localizedDescription)
                if number < Self.retryDelays.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[number]) {
                        self.attempt(firebaseID: firebaseID, number: number + 1)
                    }
                } else {
                    self.lastError = Self.message(for: error)
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        isSyncing = false
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0() }
    }

    /// Forgets the last sync, so the next account starts fresh
    func reset() {
        lastSynced = nil
        lastError = nil
    }

    private static func message(for error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "You're offline."
        case .timedOut:
            return "The server took too long to respond."
        default:
            return "Couldn't reach the server."
        }
    }
}
