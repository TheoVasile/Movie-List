//
//  MovieRow.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-05-04.
//

import Foundation
import SwiftUI

struct MovieRow: View {
    @ObservedObject var movie: CDMovie
    
    var body: some View {
        HStack{
            Text("\(String(movie.rank)).")
            if let poster_path = movie.poster_path, !poster_path.isEmpty {
                AsyncImage(url: URL(string: "https://media.themoviedb.org/t/p/w600_and_h900_bestv2"+poster_path)) { image in
                    image.resizable()
                        .scaledToFit()
                } placeholder: {
                    Color.gray.opacity(0.3) // Placeholder if no image
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 100)
                .cornerRadius(10)
                .padding(5)
            }
            Text(movie.title ?? "No title")
            Text(yearString(from: movie.release_date ?? Date()))
        }
    }
    
    func yearString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }
}

#Preview {
    MovieRow(movie: CDMovie.example)
}
