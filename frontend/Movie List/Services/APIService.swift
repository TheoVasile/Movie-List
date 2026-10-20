//
//  APIService.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-09.
//

import Foundation
import UIKit
import CoreData
import FirebaseAuth

struct ListRequest: Codable {
    let user_id: String
    let name: String
    let overview: String
    let is_ranked: Bool
}

struct ListResponse: Codable {
    let id: Int64
    let user_id: String
    let name: String
    let overview: String
    let is_ranked: Bool
    let creation_date: String
    let date_modified: String
}

struct MovieRequest: Codable {
    let tmdb_id: Int64
    let title: String
    let release_date: String
    let overview: String
    let poster_path: String
    let original_language: String
    let popularity: Double
}

struct MovieResponse: Codable {
    let id: Int64
    let tmdb_id: String
    let title: String
    let release_date: String
    let overview: String
    let poster_path: String
    let original_language: String
    let popularity: Double
    let created_at: String
}

struct UserResponse: Codable {
    let id: Int64
    let firebase_id: String
    let email: String
    let name: String
}

struct UserRequest: Codable {
    let firebase_id: String
    let email: String
    let username: String
}

struct MovieDetailsResponse: Codable {
    let id: Int64
    let tmdb_id: String
    let title: String
    let overview: String
    let poster_path: String
    let original_language: String
    let popularity: Double
    let created_at: String
    let release_date: String
    let rank: Int
    // Optional so responses from before watched tracking still decode
    let watched: Bool?
    // The user's private note on the film; nil when they haven't written one
    let note: String?
    // Placed by Smart Placement and not yet approved
    let ai_placed: Bool?
    // On shared lists, who added it when it wasn't the user
    let added_by_name: String?
}

/// Someone on a shared list: its owner, or a person they invited to edit it
struct ListMember: Codable, Identifiable, Hashable {
    var id: String { handle }
    let handle: String
    let display_name: String
    let avatar_version: Double?
    let is_owner: Bool
    // The signed-in user
    let is_me: Bool
}

struct ListDetailsResponse: Codable {
    let id: Int64
    let user_id: String
    let name: String
    let overview: String
    let creation_date: String
    let date_modified: String
    let movies: [MovieDetailsResponse]
    // Only set on Letterboxd imports: films that couldn't be matched to TMDb
    let skipped: [String]?
    // "public", "followers" or "private"
    let visibility: String?
    // False for lists someone else owns and invited the user to edit; nil from servers before shared lists
    let is_owner: Bool?
    // Everyone on a shared list, owner first; empty when it isn't shared
    let members: [ListMember]?
}

struct LetterboxdImportRequest: Encodable {
    let user_id: String
    let lists: [LetterboxdList]
}

struct AIDiscoverRequest: Encodable {
    struct Film: Encodable {
        let title: String
        let year: String
    }
    let liked: [Film]
    let passed: [Film]
    let disliked: [Film]
    let favorite_genres: [String]
    let avoided_genres: [String]
    // Genres the user picked themselves; every pick must have one of them. Empty when Discover is automatic
    let required_genres: [String]
    let swipe_count: Int
    let like_count: Int
    let region: String?
    let language: String?
    let age_range: String?
    let pronouns: String?
    let already_suggested: [String]
    let exclude_ids: [Int64]
    let count: Int
    // Filters: original languages, streaming services (ids and names) in region, and one list to recommend from
    var languages: [String] = []
    var providers: [Int] = []
    var provider_names: [String] = []
    var list_ids: [Int64] = []
}

/// A movie night group: everyone in it besides the user, and whether all of them (the user included) allow AI
struct MovieGroup: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let is_owner: Bool
    let members: [UserSummary]
    let ai_possible: Bool
    // Whether a vote is open, and whether the user still has films to vote on in it. Optional for older servers
    let poll_open: Bool?
    let needs_my_vote: Bool?
}

/// A movie night vote: 2 to 5 films someone in a group sent, with everyone's 👍 and 👎 so far
struct GroupPoll: Decodable, Equatable {
    let id: Int64
    let created_by_name: String?
    let started_by_me: Bool
    let closes_at: String
    let closed: Bool
    let winner_tmdb_id: Int64?
    // How many people have voted on at least one film, out of everyone in the group
    let voters: Int
    let people: Int
    let options: [PollOption]

    var winner: PollOption? { options.first { $0.tmdb_id == winner_tmdb_id } }

    var closesAt: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: closes_at) ?? ISO8601DateFormatter().date(from: closes_at)
    }
}

struct PollOption: Decodable, Identifiable, Equatable {
    var id: Int64 { tmdb_id }
    let tmdb_id: Int64
    let title: String
    let poster_path: String?
    let release_date: String?
    let reason: String?
    let up: Int
    let down: Int
    // 1, -1, or 0 when the user hasn't voted on it
    let my_vote: Int

    /// As a Movie, for adding the winner to a list
    var movie: Movie {
        Movie(id: tmdb_id, title: title, release_date: release_date ?? "", overview: "", poster_path: poster_path,
              original_language: "", popularity: 0, reason: reason)
    }
}

/// What a movie night's picks are limited to
struct MovieNightFilters: Equatable {
    var genres: Set<Int> = []
    var languages: [String] = []
    var services: [StreamingService] = []

    var isEmpty: Bool { genres.isEmpty && languages.isEmpty && services.isEmpty }
}

/// A streaming service the user can filter recommendations by
/// Which services the user has, in which country, and whether they want to hear when watchlist films arrive on them
struct StreamingPreferences: Decodable {
    let region: String?
    let services: [Int]
    let notify: Bool
}

struct StreamingService: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let logo_path: String?
}

/// A streaming service, shop or free service, as TMDb names it
struct WatchProvider: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    let logo_path: String?

    var logoURL: URL? {
        logo_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w92\($0)") }
    }
}

/// Where a film can be watched in one country. Availability data is from JustWatch, via TMDb
struct WatchProviders: Decodable {
    let region: String
    // TMDb's watch page for the film, which links out to each service
    let link: String?
    let stream: [WatchProvider]
    let free: [WatchProvider]
    let rent: [WatchProvider]
    let buy: [WatchProvider]

    var isEmpty: Bool { stream.isEmpty && free.isEmpty && rent.isEmpty && buy.isEmpty }
}

/// A film's main trailer on YouTube; key is nil when it has none
struct Trailer: Decodable {
    let key: String?
    let name: String?
}

// MARK: - Friends

/// The signed-in user's @username (nil until they pick one), display name and follow counts
struct UserProfile: Decodable {
    let handle: String?
    let display_name: String
    let followers: Int
    let following: Int
    // People waiting for the user to accept their follow request
    let requests: Int?
    // When the user's profile picture last changed; nil when they don't have one
    let avatar_version: Double?
    // Which push notifications the user wants
    let notify_requests: Bool?
    let notify_activity: Bool?
    // Whether they've added a phone number so contacts can find them
    let has_phone: Bool?
}

/// Follow requests waiting on the user, and the @usernames the user has asked to follow
struct FollowRequests: Decodable {
    let incoming: [UserSummary]
    let outgoing: [String]
}

/// Someone to follow, from search or the user's following list
struct UserSummary: Decodable, Identifiable, Hashable {
    var id: String { handle }
    let handle: String
    let display_name: String
    var following: Bool
    // Only in the following list
    let list_count: Int?
    let film_count: Int?
    // When their profile picture last changed; nil when they don't have one
    let avatar_version: Double?
}

/// A followed person's lists, read-only. lists is empty when the user doesn't follow them
/// One watch of a film. A film's first watch is its watched mark; later ones are rewatches, which
/// have an id so they can be removed
struct DiaryEntry: Decodable {
    let id: Int?
    let kind: String
    let movie_id: Int64
    let tmdb_id: Int64
    let title: String
    let poster_path: String?
    let release_date: String
    let watched_at: String
    // Saved along with many other films at once, by an import or marking a whole list, so the date
    // is when it was recorded rather than when it was seen
    let bulk: Bool

    var isRewatch: Bool { kind == "rewatch" }
    var entryID: String { id.map { "r\($0)" } ?? "f\(movie_id)" }
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: watched_at) ?? ISO8601DateFormatter().date(from: watched_at)
    }
}

struct FriendLists: Decodable {
    struct Film: Decodable, Identifiable {
        var id: Int64 { tmdb_id }
        let tmdb_id: Int64
        let title: String
        let release_date: String
        let poster_path: String?
        let rank: Int
        let watched: Bool
    }
    struct List: Decodable, Identifiable {
        let id: Int64
        let name: String
        let overview: String
        let movies: [Film]
        let visibility: String?
        let owner_handle: String?
        let owner_name: String?
        // Whether the user follows this list, and how many people do
        let followed: Bool?
        let follower_count: Int?
    }
    let handle: String
    let display_name: String
    let avatar_version: Double?
    var following: Bool
    // The user has asked to follow them and is waiting for them to accept
    let requested: Bool?
    // How many people follow them and how many they follow
    let follower_count: Int?
    let following_count: Int?
    // Whether they allow AI features; only sent to people who follow them
    let ai_allowed: Bool?
    let lists: [List]
}

/// What one person the user follows thinks of a film
struct FriendTake: Decodable, Identifiable {
    struct Ranking: Decodable {
        let list_name: String
        let rank: Int
        let list_size: Int
    }
    var id: String { handle }
    let handle: String
    let display_name: String
    let avatar_version: Double?
    let watched: Bool
    let note: String?
    let ranking: Ranking?
}

class APIService {
    static let shared = APIService()
    #if !DEBUG
    // Release builds, including TestFlight, use the backend hosted on Render (see render.yaml)
    let baseURL = "https://movie-list-backend-dgct.onrender.com"
    #elseif targetEnvironment(simulator)
    let baseURL = "http://localhost:3000"
    #else
    // On a real phone "localhost" is the phone itself, so reach the backend on this Mac over Wi-Fi.
    // The phone must be on the same network as the Mac, with `node server.js` running
    let baseURL = "http://Theodors-MacBook-Pro.local:3000"
    #endif

    /// Sends a request to the backend as the signed-in Firebase user. The backend identifies
    /// the caller from this ID token, so every request has to go through here
    private func send(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        authorize(request) { result in
            switch result {
            case .success(let request):
                URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
            case .failure(let error):
                completion(nil, nil, error)
            }
        }
    }

    /// Adds the signed-in user's Firebase ID token to a request
    private func authorize(_ request: URLRequest, completion: @escaping (Result<URLRequest, Error>) -> Void) {
        guard let user = Auth.auth().currentUser else {
            completion(.failure(NSError(domain: "Not signed in", code: 401, userInfo: nil)))
            return
        }
        // Firebase caches the token and only refreshes it when it is close to expiring
        user.getIDToken { token, error in
            guard let token = token else {
                completion(.failure(error ?? NSError(domain: "Not signed in", code: 401, userInfo: nil)))
                return
            }
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            completion(.success(request))
        }
    }
    
    func fetchData(firebase_id: String, completion: @escaping (Result<[ListDetailsResponse], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/fetch?user_id=\(firebase_id)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The free server can take most of a minute to wake up before it starts on the request
        request.timeoutInterval = 90
        
        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "No Data", code: 0, userInfo: nil)))
                }
                return
            }
            
            do {
                let decodedResponse = try JSONDecoder().decode([ListDetailsResponse].self, from: data)
                DispatchQueue.main.async {
                    completion(.success(decodedResponse))
                }
            } catch {
                print(error.localizedDescription)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    func importLetterboxdLists(userID: String, lists: [LetterboxdList], completion: @escaping (Result<[ListDetailsResponse], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/letterboxd/import") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Every film is matched against TMDb on the server, so long lists take a while
        request.timeoutInterval = 600

        do {
            request.httpBody = try JSONEncoder().encode(LetterboxdImportRequest(user_id: userID, lists: lists))
        } catch {
            completion(.failure(error))
            return
        }

        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data, let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "Import failed", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil)))
                }
                return
            }

            do {
                let decodedResponse = try JSONDecoder().decode([ListDetailsResponse].self, from: data)
                DispatchQueue.main.async {
                    completion(.success(decodedResponse))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func createUser(firebase_id: String, email: String, name: String, completion: @escaping (Result<UserResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/create") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = UserRequest(firebase_id: firebase_id, email: email, username: name)

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            print("Encoding error:", error)
            return
        }
        
        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "No Data", code: 0, userInfo: nil)))
                }
                return
            }

            do {
                let userResponse = try JSONDecoder().decode(UserResponse.self, from: data)
                DispatchQueue.main.async {
                    completion(.success(userResponse))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        
    }
    
    // MARK: Friends

    /// Sends a request and decodes the JSON reply; the error's code is the HTTP status. Calls back on the main thread
    private func sendJSON<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil, completion: @escaping (Result<T, Error>) -> Void) {
        var components = URLComponents(string: baseURL + path)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        }
        send(request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<T, Error>
            if let data, (200...299).contains(status), let decoded = try? JSONDecoder().decode(T.self, from: data) {
                result = .success(decoded)
            } else {
                result = .failure(error ?? NSError(domain: "Request failed", code: status, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private struct HandleResponse: Decodable { let handle: String }
    private struct FollowResponse: Decodable { let following: Bool }

    func fetchMyProfile(completion: @escaping (Result<UserProfile, Error>) -> Void) {
        sendJSON("GET", "/users/me", completion: completion)
    }

    /// Fails with code 409 when the username is taken, 400 when it isn't allowed
    func setHandle(_ handle: String, completion: @escaping (Result<String, Error>) -> Void) {
        sendJSON("PUT", "/users/me/handle", body: ["handle": handle]) { (result: Result<HandleResponse, Error>) in
            completion(result.map(\.handle))
        }
    }

    func searchUsers(_ query: String, completion: @escaping (Result<[UserSummary], Error>) -> Void) {
        sendJSON("GET", "/users/search", query: [URLQueryItem(name: "q", value: query)], completion: completion)
    }

    func fetchFollowing(completion: @escaping (Result<[UserSummary], Error>) -> Void) {
        sendJSON("GET", "/users/me/following", completion: completion)
    }

    /// Someone's followers or the people they follow (the user's own when handle is nil). Fails with 403 when
    /// the user doesn't follow them
    func fetchConnections(handle: String?, followers: Bool, completion: @escaping (Result<[UserSummary], Error>) -> Void) {
        let who = handle.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 } ?? "me"
        sendJSON("GET", "/users/\(who)/\(followers ? "followers" : "following")", completion: completion)
    }

    private struct ListFollowResponse: Decodable { let followed: Bool }

    /// Follows or unfollows someone else's list, to hear about films added to it
    func setListFollowed(_ listID: Int64, _ follow: Bool, completion: @escaping (Bool) -> Void) {
        sendJSON(follow ? "POST" : "DELETE", "/lists/\(listID)/follow") { (result: Result<ListFollowResponse, Error>) in
            completion((try? result.get()) != nil)
        }
    }

    func fetchFollowedLists(completion: @escaping (Result<[FriendLists.List], Error>) -> Void) {
        sendJSON("GET", "/users/me/followed-lists", completion: completion)
    }

    /// Streaming services in the user's country, most popular first
    /// The user's streaming services and country, and whether they want "now streaming" alerts
    func fetchStreamingPreferences(completion: @escaping (Result<StreamingPreferences, Error>) -> Void) {
        sendJSON("GET", "/users/me/streaming", completion: completion)
    }

    /// Saves any of them; nil leaves that one as it is. Calls back with what was saved
    func saveStreamingPreferences(services: [Int]? = nil, notify: Bool? = nil, completion: @escaping (Result<StreamingPreferences, Error>) -> Void) {
        // The country always goes along, so alerts follow the user when they move
        var body: [String: Any] = ["region": Locale.current.region?.identifier ?? "US"]
        if let services { body["services"] = services }
        if let notify { body["notify"] = notify }
        sendJSON("PUT", "/users/me/streaming", body: body, completion: completion)
    }

    func fetchStreamingServices(completion: @escaping (Result<[StreamingService], Error>) -> Void) {
        sendJSON("GET", "/movies/streaming-services", query: [URLQueryItem(name: "region", value: Locale.current.region?.identifier ?? "US")], completion: completion)
    }

    func fetchFollowRequests(completion: @escaping (Result<FollowRequests, Error>) -> Void) {
        sendJSON("GET", "/users/me/requests", completion: completion)
    }

    private struct AvatarResponse: Decodable { let avatar_version: Double? }

    /// Uploads a JPEG as the user's profile picture. Calls back with its new version, or nil if it failed
    func uploadAvatar(_ jpeg: Data, completion: @escaping (Double?) -> Void) {
        guard let url = URL(string: "\(baseURL)/users/me/avatar") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        send(request) { data, response, _ in
            let ok = (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            let version = ok ? data.flatMap { try? JSONDecoder().decode(AvatarResponse.self, from: $0) }?.avatar_version : nil
            DispatchQueue.main.async { completion(version) }
        }
    }

    func deleteAvatar(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/users/me/avatar") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        send(request) { _, response, _ in
            let ok = (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Someone's profile picture, or the user's own when handle is nil
    func fetchAvatar(handle: String?, version: Double, completion: @escaping (UIImage?) -> Void) {
        let who = handle.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 } ?? "me"
        guard let url = URL(string: "\(baseURL)/users/\(who)/avatar?v=\(Int64(version))") else { return }
        send(URLRequest(url: url)) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let image = ok ? data.flatMap(UIImage.init(data:)) : nil
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Which contacts (as SHA-256 hashes of their emails and phone numbers) are on CineList
    func matchContacts(emails: [String], phones: [String], completion: @escaping (Result<[UserSummary], Error>) -> Void) {
        sendJSON("POST", "/users/contacts/match", body: ["emails": emails, "phones": phones], completion: completion)
    }

    private struct PhoneResponse: Decodable { let has_phone: Bool }

    /// Saves the hash of the user's phone number so contacts can find them; nil removes it
    func setPhoneHash(_ hash: String?, completion: @escaping (Bool) -> Void) {
        sendJSON("PUT", "/users/me/phone", body: ["phone_hash": hash ?? NSNull()]) { (result: Result<PhoneResponse, Error>) in
            completion((try? result.get()) != nil)
        }
    }

    private struct Registered: Decodable { let registered: Bool }

    /// Tells the server to send this account's notifications to this device
    func registerDevice(token: String) {
        sendJSON("PUT", "/users/me/devices", body: ["token": token]) { (result: Result<Registered, Error>) in
            if case .failure(let error) = result { print("Couldn't register for notifications:", error) }
        }
    }

    func unregisterDevice(token: String) {
        guard let url = URL(string: "\(baseURL)/users/me/devices/\(token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        send(request) { _, _, _ in }
    }

    private struct NotificationPreferences: Decodable { let requests: Bool?; let activity: Bool? }

    /// Saves which push notifications the user wants; nil leaves that one unchanged
    func setNotificationPreferences(requests: Bool? = nil, activity: Bool? = nil, completion: @escaping (Bool) -> Void) {
        var body: [String: Any] = [:]
        if let requests { body["requests"] = requests }
        if let activity { body["activity"] = activity }
        sendJSON("PUT", "/users/me/notifications", body: body) { (result: Result<NotificationPreferences, Error>) in
            completion((try? result.get()) != nil)
        }
    }

    private struct RequestAnswer: Decodable { let accepted: Bool }

    /// Accepts or declines someone's request to follow the user
    func answerFollowRequest(_ handle: String, accept: Bool, completion: @escaping (Bool) -> Void) {
        let escaped = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        sendJSON(accept ? "POST" : "DELETE", accept ? "/users/me/requests/\(escaped)/accept" : "/users/me/requests/\(escaped)") { (result: Result<RequestAnswer, Error>) in
            completion((try? result.get()) != nil)
        }
    }

    func setFollowing(_ handle: String, _ following: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        let path = "/users/\(handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)/follow"
        sendJSON(following ? "POST" : "DELETE", path) { (result: Result<FollowResponse, Error>) in
            completion(result.map(\.following))
        }
    }

    func fetchFriendLists(_ handle: String, completion: @escaping (Result<FriendLists, Error>) -> Void) {
        sendJSON("GET", "/users/\(handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)/lists", completion: completion)
    }

    func fetchFriendTakes(tmdbID: Int64, completion: @escaping (Result<[FriendTake], Error>) -> Void) {
        sendJSON("GET", "/users/me/following/films/\(tmdbID)", completion: completion)
    }

    private struct AIAllowedResponse: Decodable { let allowed: Bool }

    private struct NameResponse: Decodable { let name: String }

    /// Saves the name friends see on the server
    func setDisplayName(_ name: String, completion: @escaping (Bool) -> Void) {
        sendJSON("PUT", "/users/me/name", body: ["name": name]) { (result: Result<NameResponse, Error>) in
            completion((try? result.get()) != nil)
        }
    }

    /// Saves whether the user allows AI features on the server
    func setAIAllowed(_ allowed: Bool, completion: @escaping (Bool) -> Void) {
        sendJSON("PUT", "/users/me/ai", body: ["allowed": allowed]) { (result: Result<AIAllowedResponse, Error>) in
            completion((try? result.get()) != nil)
        }
    }

    /// Films the user and a friend they follow would both enjoy, picked by the AI, each with a reason.
    /// A failure's code is the HTTP status (403 not following or AI not allowed by one of them, 429 daily
    /// limit, 503 AI not set up), and its description is the server's explanation when there is one
    /// Films for a movie night with people the user follows (handles) or a saved group, optionally narrowed
    /// to genres, languages and streaming services. usesAI false asks for Classic picks, from TMDb's
    /// recommendations for everyone's favourites. A failure's code is the HTTP status (403 not following or AI
    /// not allowed by someone, 429 daily limit, 503 AI not set up), and its description is the server's explanation
    func movieNight(handles: [String], groupID: Int64? = nil, usesAI: Bool, filters: MovieNightFilters = MovieNightFilters(),
                    completion: @escaping (Result<[Movie], Error>) -> Void) {
        var request = URLRequest(url: URL(string: "\(baseURL)/movies/movie-night")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "count": 10,
            "mode": usesAI ? "ai" : "classic",
            "genres": filters.genres.sorted(),
            "genre_names": filters.genres.sorted().compactMap { TasteProfile.genreNames[$0] },
            "languages": filters.languages,
            "providers": filters.services.map(\.id),
            "provider_names": filters.services.map(\.name),
            "region": Locale.current.region?.identifier ?? "US",
        ]
        if let groupID { body["group_id"] = groupID } else { body["handles"] = handles }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Reading several people's lists takes the AI a little while
        request.timeoutInterval = 90
        send(request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<[Movie], Error>
            if let data, status == 200, let movies = try? JSONDecoder().decode([Movie].self, from: data) {
                result = .success(movies)
            } else {
                let message = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
                result = .failure(error ?? NSError(domain: "Movie night failed", code: status,
                                                   userInfo: message.map { [NSLocalizedDescriptionKey: $0] }))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func fetchGroups(completion: @escaping (Result<[MovieGroup], Error>) -> Void) {
        sendJSON("GET", "/users/me/groups", completion: completion)
    }

    private struct CreatedGroup: Decodable { let id: Int64 }

    /// Makes a movie night group from people the user follows. Calls back with whether it worked
    func createGroup(name: String, handles: [String], completion: @escaping (Bool) -> Void) {
        sendJSON("POST", "/users/me/groups", body: ["name": name, "handles": handles]) { (result: Result<CreatedGroup, Error>) in
            completion((try? result.get()) != nil)
        }
    }

    /// Sends films for the group to vote on, closing after the given hours; calls back with the new poll
    func startPoll(groupID: Int64, films: [Movie], hours: Int, completion: @escaping (Result<GroupPoll, Error>) -> Void) {
        let body: [String: Any] = [
            "hours": hours,
            "films": films.map { film -> [String: Any] in
                var item: [String: Any] = ["tmdb_id": film.id, "title": film.title, "release_date": film.release_date]
                if let poster = film.poster_path { item["poster_path"] = poster }
                if let reason = film.reason { item["reason"] = reason }
                return item
            },
        ]
        sendJSON("POST", "/users/me/groups/\(groupID)/polls", body: body, completion: completion)
    }

    /// The group's open vote, or the last one for a day after it closes; nil when there's none
    func fetchPoll(groupID: Int64, completion: @escaping (Result<GroupPoll?, Error>) -> Void) {
        sendJSON("GET", "/users/me/groups/\(groupID)/polls/current") { (result: Result<GroupPoll, Error>) in
            switch result {
            case .success(let poll): completion(.success(poll))
            // 204: no vote right now
            case .failure(let error) where (error as NSError).code == 204: completion(.success(nil))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    /// Votes 👍 (1) or 👎 (-1) on a film, or takes the vote back (0); calls back with the poll as it is now
    func vote(groupID: Int64, pollID: Int64, tmdbID: Int64, vote: Int, completion: @escaping (Result<GroupPoll, Error>) -> Void) {
        sendJSON("PUT", "/users/me/groups/\(groupID)/polls/\(pollID)/votes", body: ["tmdb_id": tmdbID, "vote": vote], completion: completion)
    }

    /// Deletes a group the user made, or leaves one they were added to
    /// Invites someone the user follows to edit one of their lists. Calls back with nil once they're added,
    /// otherwise with a reason to show
    func addListEditor(listID: Int64, handle: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/\(listID)/editors") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["handle": handle])
        send(request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = (200...299).contains(status) ? nil
                : data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
                    ?? "Couldn't add them. Check your connection and try again."
            DispatchQueue.main.async { completion(message) }
        }
    }

    /// Takes someone off a shared list (the owner can remove anyone), or with no handle, leaves it
    func removeListEditor(listID: Int64, handle: String? = nil, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/\(listID)/editors/\(handle ?? "me")") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        send(request) { _, response, _ in
            let ok = (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func leaveGroup(_ id: Int64, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/users/me/groups/\(id)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        send(request) { _, response, _ in
            let ok = (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func deleteUser(firebase_id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/delete/\(firebase_id)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(.success(()))
            } else {
                completion(.failure(NSError(domain: "Delete failed", code: 0, userInfo: nil)))
            }

        }
    }
    
    func searchMovies(name: String, completion: @escaping (Result<[Movie], Error>) -> Void) {
        // .urlQueryAllowed leaves "&", "+" and "=" alone, which would cut titles like "Fast & Furious" short
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let url = URL(string: "\(baseURL)/movies/search?name=\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")") else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "No Data", code: 0, userInfo: nil)))
                }
                return
            }
            
            do {
                let decodedResponse = try JSONDecoder().decode([Movie].self, from: data)
                DispatchQueue.main.async {
                    completion(.success(decodedResponse))
                }
            } catch {
                print(error.localizedDescription)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    /// Films for the Discover tab, recommended from the given TMDb ids (the user's favourites) and genres, plus trending films
    /// onlyGenres: the user picked these genres themselves, so every film returned has one of them
    func discoverMovies(seeds: [Int64], genres: [Int] = [], avoidGenres: [Int] = [], onlyGenres: Bool = false, languages: [String] = [], providers: [Int] = [], page: Int, completion: @escaping (Result<[Movie], Error>) -> Void) {
        var components = URLComponents(string: "\(baseURL)/movies/discover")
        components?.queryItems = [
            URLQueryItem(name: "seeds", value: seeds.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "genres", value: genres.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "avoid_genres", value: avoidGenres.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "languages", value: languages.joined(separator: ",")),
            URLQueryItem(name: "providers", value: providers.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "region", value: Locale.current.region?.identifier ?? "US"),
        ] + (onlyGenres ? [URLQueryItem(name: "only_genres", value: "1")] : [])
        guard let url = components?.url else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }

        send(URLRequest(url: url)) { data, response, error in
            guard let data = data, error == nil,
                  let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(error ?? NSError(domain: "Discover failed", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil)))
                }
                return
            }

            do {
                let decodedResponse = try JSONDecoder().decode([Movie].self, from: data)
                DispatchQueue.main.async {
                    completion(.success(decodedResponse))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Films picked by AI from the user's lists, swipes and anything they chose to share. Fails with
    /// code 503 when AI isn't set up on the server and 429 at the daily limit
    /// AI picks, streamed: onMovie gets each film as soon as the server has it, then completion gets how many
    /// arrived. Fails (with the HTTP status as the error code) before any film if AI isn't available.
    /// Both callbacks run on the main thread
    func aiDiscoverStream(_ body: AIDiscoverRequest, onMovie: @escaping (Movie) -> Void, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/ai-discover") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        // The AI thinks for a few seconds before the first film, then streams the rest
        request.timeoutInterval = 90
        request.httpBody = try? JSONEncoder().encode(body)

        authorize(request) { result in
            guard case .success(let request) = result else {
                if case .failure(let error) = result { DispatchQueue.main.async { completion(.failure(error)) } }
                return
            }
            Task {
                var count = 0
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(status) else {
                        throw NSError(domain: "AI discover failed", code: status, userInfo: nil)
                    }
                    // One film per line
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), let movie = try? JSONDecoder().decode(Movie.self, from: data) else { continue }
                        count += 1
                        await MainActor.run { onMovie(movie) }
                    }
                    await MainActor.run { completion(.success(count)) }
                } catch {
                    // A stream that breaks after some films still delivered them; report what arrived
                    let finalCount = count
                    await MainActor.run { completion(finalCount > 0 ? .success(finalCount) : .failure(error)) }
                }
            }
        }
    }

    func addMovieToList(list_id: Int64, movie_id: Int64, rank: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/addToList") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "list_id": list_id,
            "movie_id": movie_id,
            "rank": rank
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            completion(.failure(error))
            return
        }

        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "Invalid response", code: 0, userInfo: nil)))
                }
                return
            }

            DispatchQueue.main.async {
                completion(.success(()))
            }
        }
    }
    
    /// Genres, US age rating and TMDb user score for up to 50 films, keyed by TMDb id. Calls back on the main thread
    func fetchMovieInfo(tmdbIDs: [Int64], completion: @escaping (Result<[Int64: MovieInfo], Error>) -> Void) {
        struct FilmInfo: Decodable {
            let id: Int64
            let genre_ids: [Int]
            let certification: String
            let vote_average: Double
            let vote_count: Int
        }
        var components = URLComponents(string: "\(baseURL)/movies/info")
        components?.queryItems = [URLQueryItem(name: "ids", value: tmdbIDs.map(String.init).joined(separator: ","))]
        guard let url = components?.url else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }

        send(URLRequest(url: url)) { data, response, error in
            let result: Result<[Int64: MovieInfo], Error>
            if let data, let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
               let films = try? JSONDecoder().decode([FilmInfo].self, from: data) {
                let fetched = Date()
                result = .success(Dictionary(films.map {
                    ($0.id, MovieInfo(genres: $0.genre_ids, certification: $0.certification, voteAverage: $0.vote_average, voteCount: $0.vote_count, fetched: fetched))
                }, uniquingKeysWith: { first, _ in first }))
            } else {
                result = .failure(error ?? NSError(domain: "Film info lookup failed", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The film's IMDb id (e.g. "tt0099785"), or nil when TMDb doesn't have one
    func fetchIMDbID(tmdbID: Int64, completion: @escaping (Result<String?, Error>) -> Void) {
        struct IMDbResponse: Decodable {
            let imdb_id: String?
        }
        var components = URLComponents(string: "\(baseURL)/movies/imdb")
        components?.queryItems = [URLQueryItem(name: "tmdb_id", value: String(tmdbID))]
        guard let url = components?.url else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }

        send(URLRequest(url: url)) { data, response, error in
            let result: Result<String?, Error>
            if let data, let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
               let decoded = try? JSONDecoder().decode(IMDbResponse.self, from: data) {
                result = .success(decoded.imdb_id)
            } else {
                result = .failure(error ?? NSError(domain: "IMDb lookup failed", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Where the film can be streamed, rented or bought in the given country (two-letter code)
    func fetchWatchProviders(tmdbID: Int64, region: String, completion: @escaping (Result<WatchProviders, Error>) -> Void) {
        var components = URLComponents(string: "\(baseURL)/movies/providers")
        components?.queryItems = [
            URLQueryItem(name: "tmdb_id", value: String(tmdbID)),
            URLQueryItem(name: "region", value: region),
        ]
        guard let url = components?.url else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }

        send(URLRequest(url: url)) { data, response, error in
            let result: Result<WatchProviders, Error>
            if let data, let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
               let decoded = try? JSONDecoder().decode(WatchProviders.self, from: data) {
                result = .success(decoded)
            } else {
                result = .failure(error ?? NSError(domain: "Watch providers lookup failed", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The film's main trailer on YouTube, if TMDb knows of one
    func fetchTrailer(tmdbID: Int64, completion: @escaping (Result<Trailer, Error>) -> Void) {
        var components = URLComponents(string: "\(baseURL)/movies/trailer")
        components?.queryItems = [URLQueryItem(name: "tmdb_id", value: String(tmdbID))]
        guard let url = components?.url else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }

        send(URLRequest(url: url)) { data, response, error in
            let result: Result<Trailer, Error>
            if let data, let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
               let decoded = try? JSONDecoder().decode(Trailer.self, from: data) {
                result = .success(decoded)
            } else {
                result = .failure(error ?? NSError(domain: "Trailer lookup failed", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Marks a film watched or unwatched for the signed-in user, across all of their lists
    func setMovieWatched(movie_id: Int64, watched: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/watched") else { return }
        putWatched(url: url, body: ["movie_id": movie_id, "watched": watched], completion: completion)
    }

    /// Marks every film in a list watched or unwatched for the signed-in user
    func setListWatched(list_id: Int64, watched: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/\(list_id)/watched") else { return }
        putWatched(url: url, body: ["watched": watched], completion: completion)
    }

    /// Every watch, newest first, or only one film's when movieID is given
    func fetchDiary(movieID: Int64? = nil, completion: @escaping (Result<[DiaryEntry], Error>) -> Void) {
        sendJSON("GET", "/movies/diary", query: movieID.map { [URLQueryItem(name: "movie_id", value: String($0))] } ?? [], completion: completion)
    }

    /// Logs a watch on the given day. The first watch marks the film watched; later ones are rewatches
    func logWatch(movieID: Int64, on day: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/watch") else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        sendVoid(url: url, method: "POST", body: ["movie_id": movieID, "watched_on": formatter.string(from: day)], completion: completion)
    }

    func deleteRewatch(id: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/watch/\(id)") else { return }
        sendVoid(url: url, method: "DELETE", body: nil, completion: completion)
    }

    private func sendVoid(url: URL, method: String, body: [String: Any]?, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        }
        send(request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<Void, Error> = (200...299).contains(status)
                ? .success(())
                : .failure(error ?? NSError(domain: "Request failed", code: status, userInfo: nil))
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func putWatched(url: URL, body: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            completion(.failure(error))
            return
        }

        send(request) { _, response, error in
            let result: Result<Void, Error>
            if let error = error {
                result = .failure(error)
            } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                result = .success(())
            } else {
                result = .failure(NSError(domain: "Watched update failed", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Saves the user's note on a film; an empty note deletes it. Calls back on the main thread
    func setMovieNote(movie_id: Int64, note: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/note") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["movie_id": movie_id, "note": note], options: [])
        } catch {
            completion(.failure(error))
            return
        }

        send(request) { _, response, error in
            let result: Result<Void, Error>
            if let error = error {
                result = .failure(error)
            } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                result = .success(())
            } else {
                result = .failure(NSError(domain: "Note save failed", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private struct Placement: Decodable { let rank: Int; let reason: String }

    /// Smart Placement: Claude decides where a film already in the list belongs, and the server moves it there.
    /// Calls back with the new rank and why, or an error whose code is the HTTP status
    func smartPlace(listID: Int64, movieID: Int64, completion: @escaping (Result<(rank: Int, reason: String), Error>) -> Void) {
        sendJSON("POST", "/movies/smart-place", body: ["list_id": listID, "movie_id": movieID]) { (result: Result<Placement, Error>) in
            completion(result.map { ($0.rank, $0.reason) })
        }
    }

    private struct Approved: Decodable { let approved: Bool }

    /// Keeps a Smart Placement spot, clearing its AI mark
    func approvePlacement(listID: Int64, movieID: Int64, completion: @escaping (Bool) -> Void) {
        sendJSON("PUT", "/movies/approve-placement", body: ["list_id": listID, "movie_id": movieID]) { (result: Result<Approved, Error>) in
            completion((try? result.get()) != nil)
        }
    }

    func updateMovieRanking(list_id: Int64, movie_id: Int64, rank: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/updateRank") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
                "list_id": list_id,
                "movie_id": movie_id,
                "rank": rank
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            } catch {
                completion(.failure(error))
                return
            }

            send(request) { data, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let statusError = NSError(domain: "", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: nil)
                    completion(.failure(statusError))
                    return
                }

                completion(.success(()))
            }
    }
    
    func removeMovieFromList(list_id: Int64, movie_id: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/removeFromList/\(list_id)/\(movie_id)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(.success(()))
            } else {
                completion(.failure(NSError(domain: "Delete failed", code: 0, userInfo: nil)))
            }

        }
        
    }
    
    func createMovie(tmdb_id: Int64, title: String, release_date: String, overview: String, poster_path: String, original_language: String, popularity: Double, completion: @escaping (Result<MovieResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/create") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = MovieRequest(tmdb_id: tmdb_id, title: title, release_date: release_date, overview: overview, poster_path: poster_path, original_language: original_language, popularity: popularity)

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            print("❌ Encoding error:", error)
            return
        }
        
        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "No Data", code: 0, userInfo: nil)))
                }
                return
            }

            do {
                let movieResponse = try JSONDecoder().decode(MovieResponse.self, from: data)
                DispatchQueue.main.async {
                    completion(.success(movieResponse))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        
    }
    
    func deleteList(listID: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/delete/\(listID)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        send(request) { data, response, error in
            if let error = error {
                completion(.failure(error)) // Return error if request fails
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(.success(())) // Success
            } else {
                completion(.failure(NSError(domain: "Delete failed", code: 0, userInfo: nil)))
            }
        }
    }

    /// Renames a list and/or changes its description; nil leaves that field as it is
    func updateList(listID: Int64, name: String?, overview: String?, visibility: ListVisibility? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/\(listID)") else { return }
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let overview { body["overview"] = overview }
        if let visibility { body["visibility"] = visibility.rawValue }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            completion(.failure(error))
            return
        }

        send(request) { _, response, error in
            let result: Result<Void, Error>
            if let error = error {
                result = .failure(error)
            } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                result = .success(())
            } else {
                result = .failure(NSError(domain: "List update failed", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func createList(userID: String, name: String, overview: String, isRanked: Bool, completion: @escaping (Result<ListResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/create") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ListRequest(user_id: userID, name: name, overview: overview, is_ranked: isRanked)

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            print("❌ Encoding error:", error)
            return
        }

        send(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "No Data", code: 0, userInfo: nil)))
                }
                return
            }

            do {
                let listResponse = try JSONDecoder().decode(ListResponse.self, from: data)
                DispatchQueue.main.async {
                    completion(.success(listResponse))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}
