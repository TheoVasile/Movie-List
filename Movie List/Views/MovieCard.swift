//
//  MovieCard.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-04.
//

import Foundation
import SwiftUI

struct MovieCard: View {
    @State var movie: CDMovie?
    var body: some View {
        ZStack {
            Color.white
            Text(movie?.title ?? "None")
                .fontWeight(.bold)
                .foregroundColor(.black) // Text color
        }
            .frame(maxWidth: .infinity) // Make width relative to screen size
            .aspectRatio(1, contentMode: .fit) // Keep it square (1:1 aspect ratio)
            .cornerRadius(20) // Rounded corners
            .shadow(radius: 5) // Shadow effect
            .padding(50) // Add padding
    }
}

#Preview{
    MovieCard(movie: CDMovie.example)
}
