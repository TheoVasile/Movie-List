//
//  APIService.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-09.
//

import Foundation

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
    let name: String
}

class APIService {
    static let shared = APIService()
    let baseURL = "http://localhost:3000"
    
    func createUser(firebase_id: String, email: String, name: String, completion: @escaping (Result<UserResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/users/create") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = UserRequest(firebase_id: firebase_id, email: email, name: name)

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            print("❌ Encoding error:", error)
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
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
        }.resume()
        
    }
    
    func searchMovies(name: String, completion: @escaping (Result<[Movie], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/search?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
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
        }.resume()
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

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
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

        task.resume()
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

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
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

            task.resume()
    }
    
    func removeMovieFromList(list_id: Int64, movie_id: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/movies/removeFromList/\(list_id)/\(movie_id)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
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

        }.resume()
        
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
        
        URLSession.shared.dataTask(with: request) { data, response, error in
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
        }.resume()
        
    }
    
    func deleteList(listID: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/lists/delete/\(listID)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error)) // Return error if request fails
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(.success(())) // Success
            } else {
                completion(.failure(NSError(domain: "Delete failed", code: 0, userInfo: nil)))
            }
        }.resume()
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

        URLSession.shared.dataTask(with: request) { data, response, error in
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
        }.resume()
    }
}
