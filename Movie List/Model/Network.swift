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
    var results: [APIMovie]
}

struct APIMovie: Identifiable, Decodable {
    var id: Int
    var poster_path: String?
    var title: String
    var overview: String?
}

class Network: ObservableObject{
    
    @Published var movies: [APIMovie] = []
    
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

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            //print(String(decoding: data, as: UTF8.self))
            let decodedMovies = try JSONDecoder().decode(Search.self, from: data)
            print("succeeded")
            
            await MainActor.run() {
                self.movies = decodedMovies.results
            }
        } catch {
            print("request failed \(error)")
        }
        /*
        let dataTask = URLSession.shared.dataTask(with: urlRequest) { (data, response, error) in
            if let error = error {
            print("Request error: ", error)
            return
            }

            guard let response = response as? HTTPURLResponse else { return }

            if response.statusCode == 200 {
            guard let data = data else { return }
            DispatchQueue.main.async {
                    do {
                        let decodedMovies = try JSONDecoder().decode(Search.self, from: data)
                        self.movies = decodedMovies.results
                        print(self.movies[0].description)
                        print(self.movies)
                        print(self.movies[0].title)
                    } catch let error {
                        print("Error decoding: ", error)
                    }
                }
            }
        }

        dataTask.resume()*/
    }
}
