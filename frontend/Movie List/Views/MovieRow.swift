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
    @Binding var showCompareMovieView: Bool
    @Binding var selectedMovie: CDMovie?
    @Binding var showSetRank: Bool
    
    var body: some View {
        HStack(spacing: 14) {
            rankBadge
            PosterImage(path: movie.poster_path, cornerRadius: 10)
                .frame(width: 58, height: 87)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(movie.title ?? "No title")
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(Theme.year(from: movie.release_date))
                    if !movie.original_language.isNilOrEmpty {
                        Text("·")
                        Text((movie.original_language ?? "").uppercased())
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button {
                    present { showSetRank = true }
                } label: {
                    Label("Set Rank", systemImage: "number")
                }
                Button {
                    print("Compare Tapped")
                    present { showCompareMovieView = true }
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .rotationEffect(.degrees(90)) // Makes it vertical like ⋮
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(12)
        .background(
            ZStack {
                Theme.surface
                if movie.rank == 1 {
                    Theme.accentGradient.opacity(0.12)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(movie.rank == 1 ? Theme.accent.opacity(0.35) : Theme.stroke, lineWidth: 1)
        )
    }

    private var rankBadge: some View {
        Text("\(movie.rank)")
            .font(.system(size: movie.rank < 100 ? 28 : 20, weight: .heavy, design: .rounded))
            .foregroundStyle(movie.rank <= 3 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
            .frame(width: 40)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
            .animation(Theme.spring, value: movie.rank)
    }

    private func present(_ change: () -> Void) {
        Haptics.tap()
        selectedMovie = movie
        withAnimation(Theme.spring, change)
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

#Preview {
    MovieRow(movie: CDMovie.example, showCompareMovieView: .constant(false), selectedMovie: .constant(nil), showSetRank: .constant(false))
}
