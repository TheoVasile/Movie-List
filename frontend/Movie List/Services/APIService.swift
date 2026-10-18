//
//  APIService.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-09.
//

import Foundation
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
    let swipe_count: Int
    let like_count: Int
    let region: String?
    let language: String?
    let age_range: String?
    let pronouns: String?
    let already_suggested: [String]
    let exclude_ids: [Int64]
    let count: Int
}

class APIService {
    static let shared = APIService()
    #if !DEBUG
    // Release builds, including TestFlight, use the backend hosted on Render (see render.yaml)
    let baseURL = "https://movie-list-backend.onrender.com"
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
        guard let user = Auth.auth().currentUser else {
            completion(nil, nil, NSError(domain: "Not signed in", code: 401, userInfo: nil))
            return
        }
        // Firebase caches the token and only refreshes it when it is close to expiring
        user.getIDToken { token, error in
            guard let token = token else {
                completion(nil, nil, error ?? NSError(domain: "Not signed in", code: 401, userInfo: nil))
                return
            }
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
        }
    }
    
    func fetchData(firebase_id: String, completion: @escaping (Result<[ListDetailsResponse], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/fetch?user_id=\(firebase_id)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
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
    func discoverMovies(seeds: [Int64], genres: [Int] = [], avoidGenres: [Int] = [], page: Int, completion: @escaping (Result<[Movie], Error>) -> Void) {
        var components = URLComponents(string: "\(baseURL)/movies/discover")
        components?.queryItems = [
            URLQueryItem(name: "seeds", value: seeds.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "genres", value: genres.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "avoid_genres", value: avoidGenres.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "page", value: String(page)),
        ]
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
    func aiDiscoverMovies(_ body: AIDiscoverRequest, completion: @escaping (Result<[Movie], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/ai-discover") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Choosing films takes the AI a few seconds
        request.timeoutInterval = 60
        request.httpBody = try? JSONEncoder().encode(body)

        send(request) { data, response, error in
            let result: Result<[Movie], Error>
            if let data, let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
               let movies = try? JSONDecoder().decode([Movie].self, from: data) {
                result = .success(movies)
            } else {
                result = .failure(error ?? NSError(domain: "AI discover failed", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil))
            }
            DispatchQueue.main.async { completion(result) }
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
