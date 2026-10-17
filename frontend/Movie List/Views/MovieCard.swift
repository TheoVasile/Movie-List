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
    var isHighlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PosterImage(path: movie.poster_path, cornerRadius: 16)
                .aspectRatio(2/3, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.accentGradient, lineWidth: isHighlighted ? 3 : 0)
                )
                .shadow(color: isHighlighted ? Theme.accent.opacity(0.5) : .black.opacity(0.45), radius: isHighlighted ? 18 : 10, y: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.title ?? "None")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Theme.year(from: movie.release_date))
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(isHighlighted ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHighlighted)
    }
}

struct MovieCardPreviews: PreviewProvider {
    static var previews: some View {
        MovieCard(movie: .constant(CDMovie.example))
    }
}
