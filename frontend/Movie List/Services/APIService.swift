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
    let id: Int
    let user_id: String
    let name: String
    let overview: String
    let is_ranked: Bool
    let creation_date: String
    let date_modified: String
}

class APIService {
    static let shared = APIService()
    let baseURL = "http://localhost:3000/lists/create"

    func createList(userID: String, name: String, overview: String, isRanked: Bool, completion: @escaping (Result<ListResponse, Error>) -> Void) {
        guard let url = URL(string: baseURL) else { return }

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
