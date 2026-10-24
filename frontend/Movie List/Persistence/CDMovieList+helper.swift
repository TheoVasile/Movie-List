//
//  CDMovieList+helper.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation
import CoreData
import FirebaseAuth


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


/// Which of the user's lists are unranked: collections in no particular order, like a watchlist, where films go
/// on the end and a film's place says nothing about how much anyone liked it. Kept on the phone (Core Data has no
/// field for it) and refreshed from the server on every sync
enum ListRanking {
    private static let storageKey = "unrankedLists"

    static func isRanked(_ listID: Int64) -> Bool {
        let unranked = UserDefaults.standard.array(forKey: storageKey) as? [String] ?? []
        return !unranked.contains(String(listID))
    }

    static func remember(_ ranked: Bool, for listID: Int64) {
        var unranked = Set(UserDefaults.standard.array(forKey: storageKey) as? [String] ?? [])
        if ranked { unranked.remove(String(listID)) } else { unranked.insert(String(listID)) }
        UserDefaults.standard.set(Array(unranked), forKey: storageKey)
    }
}

/// Who can see a list. New lists are Everyone unless the owner picks otherwise
enum ListVisibility: String, CaseIterable, Identifiable {
    case `public`, followers, `private`

    var id: String { rawValue }

    var title: String {
        switch self {
        case .public: return "Everyone"
        case .followers: return "Followers"
        case .private: return "Only Me"
        }
    }

    var icon: String {
        switch self {
        case .public: return "globe"
        case .followers: return "person.2.fill"
        case .private: return "lock.fill"
        }
    }

    var explanation: String {
        switch self {
        case .public: return "Anyone on Marquee can see and follow this list, even if they don't follow you."
        case .followers: return "Only people you've accepted as followers can see and follow this list."
        case .private: return "Only you can see this list. It's also left out of Movie Night and your friends' digests."
        }
    }

    /// The choices a user has: a private profile's lists are only ever for followers ("Friends") or the owner
    static func options(isPrivate: Bool) -> [ListVisibility] {
        isPrivate ? [.followers, .private] : allCases
    }

    func title(isPrivate: Bool) -> String {
        isPrivate && self == .followers ? "Friends" : title
    }

    func explanation(isPrivate: Bool) -> String {
        isPrivate && self == .followers ? "Only people you've accepted as followers can see and follow this list." : explanation
    }

    private static let storageKey = "listVisibility"

    /// The visibility of one of the user's lists, as last synced or changed on this phone
    static func of(_ listID: Int64) -> ListVisibility {
        let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]
        return saved?[String(listID)].flatMap(ListVisibility.init) ?? .public
    }

    static func remember(_ visibility: ListVisibility, for listID: Int64) {
        var saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        saved[String(listID)] = visibility.rawValue
        UserDefaults.standard.set(saved, forKey: storageKey)
    }
}


/// Which films in the user's lists were placed by Smart Placement and not yet approved, kept on the phone as
/// "listID:movieID" (Core Data has no field for it) and refreshed from the server on every sync
enum AIPlacement {
    private static let storageKey = "aiPlacedFilms"

    private static var saved: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: storageKey) }
    }

    private static func key(_ listID: Int64, _ movieID: Int64) -> String { "\(listID):\(movieID)" }

    static func isPlaced(listID: Int64, movieID: Int64) -> Bool {
        saved.contains(key(listID, movieID))
    }

    static func set(_ placed: Bool, listID: Int64, movieID: Int64) {
        if placed {
            saved.insert(key(listID, movieID))
        } else {
            saved.remove(key(listID, movieID))
        }
    }

    /// Replaces everything with what the server says, after a sync
    static func replaceAll(from lists: [ListDetailsResponse]) {
        saved = Set(lists.flatMap { list in
            list.movies.filter { $0.ai_placed == true }.map { key(list.id, $0.id) }
        })
    }
}


/// Who's on each shared list and who added which film, kept on the phone (Core Data has no fields for them) and
/// refreshed from the server on every sync. Lists that aren't shared have no entry
final class ListSharing: ObservableObject {
    static let shared = ListSharing()

    struct Info: Codable {
        // False when someone else owns the list and invited the user to edit it
        var isOwner: Bool
        var members: [ListMember]
        // Film id -> name of whoever added it, when it wasn't the user
        var addedBy: [String: String]
    }

    private static let storageKey = "listSharing"

    @Published private(set) var lists: [Int64: Info] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Int64: Info].self, from: data) {
            lists = saved
        }
    }

    func replaceAll(from responses: [ListDetailsResponse]) {
        var updated: [Int64: Info] = [:]
        for response in responses {
            let members = response.members ?? []
            let isOwner = response.is_owner ?? true
            guard !members.isEmpty || !isOwner else { continue }
            var addedBy: [String: String] = [:]
            for movie in response.movies {
                if let name = movie.added_by_name { addedBy[String(movie.id)] = name }
            }
            updated[response.id] = Info(isOwner: isOwner, members: members, addedBy: addedBy)
        }
        lists = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func isShared(_ listID: Int64) -> Bool { lists[listID] != nil }

    /// Whether the user owns the list; true for every list that isn't shared
    func isOwner(_ listID: Int64) -> Bool { lists[listID]?.isOwner ?? true }

    func members(of listID: Int64) -> [ListMember] { lists[listID]?.members ?? [] }

    /// Everyone on the list but the user, owner first
    func others(on listID: Int64) -> [ListMember] { members(of: listID).filter { !$0.is_me } }

    func addedBy(listID: Int64, movieID: Int64) -> String? { lists[listID]?.addedBy[String(movieID)] }

    /// Loads the lists again, after someone was added to or taken off one
    func refresh(completion: (() -> Void)? = nil) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        SyncStatus.shared.sync(firebaseID: uid, completion: completion)
    }
}
