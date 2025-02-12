//
//  MovieCard.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-04.
//

import Foundation
import SwiftUI

struct MovieCard: View {
    @Binding var movie: CDMovie
    var body: some View {
        ZStack {
            Color.white
            VStack{
                Text(movie.title ?? "None")
                    .fontWeight(.bold)
                    .foregroundColor(.black) // Text color
                Text(movie.get_date() ?? "None")
                    .foregroundColor(.gray)
                if let poster_path = movie.poster_path, !poster_path.isEmpty {
                    AsyncImage(url: URL(string: "https://media.themoviedb.org/t/p/w600_and_h900_bestv2"+poster_path)) { image in
                        image.resizable()
                            .scaledToFit()
                    } placeholder: {
                        Color.gray.opacity(0.3) // Placeholder if no image
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .cornerRadius(10)
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity) // Make width relative to screen size
        .cornerRadius(20) // Rounded corners
        .shadow(radius: 5) // Shadow effect
        .padding(10) // Add padding
    }
}

struct MovieCardPreviews: PreviewProvider {
    static var previews: some View {
        MovieCard(movie: .constant(CDMovie.example))
    }
}
