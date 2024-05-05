//
//  Network.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-04-25.
//

import SwiftUI

let environment = ProcessInfo.processInfo.environment
let api_key = environment["api_key"] ?? "default_value"

struct Search: Decodable {
    var results: [Movie]
}

class NetworkService: ObservableObject {
    
    @Published var movies: [Movie] = []
    
    func searchMovies(name: String) async {
        let url = URL(string: "https://api.themoviedb.org/3/search/movie")!
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        let queryItems: [URLQueryItem] = [
          URLQueryItem(name: "query", value: name),
          URLQueryItem(name: "include_adult", value: "false"),
          URLQueryItem(name: "language", value: "en-US"),
          URLQueryItem(name: "page", value: "1"),
        ]
        components.queryItems = components.queryItems.map { $0 + queryItems } ?? queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.allHTTPHeaderFields = [
          "accept": "application/json",
          "Authorization": "Bearer \(api_key)"
        ]
        
        print("initialized request")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            
            print("acquired data")
            
            print(String(decoding: data, as: UTF8.self))
            
            let decodedMovies = try JSONDecoder().decode(Search.self, from: data)
            print(decodedMovies)
            
            await MainActor.run() {
                self.movies = decodedMovies.results
                print(self.movies)
            }
        } catch {
            print("request failed \(error)")
        }
    }
}
