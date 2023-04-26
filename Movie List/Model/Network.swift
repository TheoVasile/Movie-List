//
//  Network.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-04-25.
//

import SwiftUI

let api_key = "X"

struct Search: Decodable {
    var searchType: String
    var expression: String
    var results: [APIMovie]
}

struct APIMovie: Identifiable, Decodable {
    var id: String
    var resultType: String
    var image: String
    var title: String
    var description: String
}

class Network: ObservableObject {
    
    @Published var movies: [APIMovie] = []
    
    func searchMovies(name: String) {
        let newName = name.replacingOccurrences(of: " ", with: "%20", options: .literal, range: nil)
        guard let url = URL(string: "https://imdb-api.com/en/API/SearchMovie/\(api_key)/\(newName)") else { fatalError("Missing URL") }

        let urlRequest = URLRequest(url: url)

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

        dataTask.resume()
        
    }
    
}
