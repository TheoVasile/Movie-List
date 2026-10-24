//
//  CompareMovieView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI
import StoreKit

struct CompareMovieView: View {
    @EnvironmentObject var network: NetworkService
    @Environment(\.requestReview) private var requestReview
    
    @Binding var movies: [CDMovie]
    @Binding var movie: CDMovie
    // Binary search bounds over `otherMovies`: the answer lies in [low, high)
    @State var low: Int = 0
    @State var high: Int = 0
    @State var middle: Int = 0
    @State private var picked: Side? = nil
    @State private var round: Int = 1
    var onRankingUpdate: (CDMovie, Int) -> Void
    var onCancel: (() -> Void)?
    var prompt: String
    var cancelTitle: String
    // Offered when adding a film: let the AI choose its place instead of comparing
    var onSmartPlace: (() -> Void)?

    private enum Side { case selected, other }
    
    init(movies: Binding<[CDMovie]>, movie: Binding<CDMovie>, prompt: String = "Which do you prefer?", cancelTitle: String = "Cancel", onCancel: (() -> Void)? = nil, onSmartPlace: (() -> Void)? = nil, onRankingUpdate: @escaping (CDMovie, Int) -> Void) {
            self._movies = movies
            self._movie = movie
            self.prompt = prompt
            self.cancelTitle = cancelTitle
            self.onCancel = onCancel
            self.onSmartPlace = onSmartPlace
            self.onRankingUpdate = onRankingUpdate
        }
    
    var body : some View {
        VStack(spacing: 22) {
            header
            // Selected movie is always on the left and the movie to compare with is on the right
            if otherMovies.count > 0 {
                HStack(alignment: .top, spacing: 14) {
                    MovieCard(movie: $movie, isHighlighted: picked == .selected)
                        .opacity(picked == .other ? 0.45 : 1)
                        .onTapGesture { choose(.selected) }
                    if middle < otherMovies.count {
                        MovieCard(movie: .constant(otherMovies[middle]), isHighlighted: picked == .other)
                            .opacity(picked == .selected ? 0.45 : 1)
                            .id(otherMovies[middle].id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                            .onTapGesture { choose(.other) }
                    }
                }
                .overlay(alignment: .top) { versusBadge.offset(y: 100) }
            } else{
                Text("Need at least 2 movies to compare")
                    .foregroundColor(Theme.textSecondary)
                    .padding(.vertical, 40)
            }
            if let onSmartPlace {
                Button(action: onSmartPlace) {
                    Label("Let AI place it", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentGradient)
                }
            }
            if let onCancel {
                Button(cancelTitle, action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(20)
        .background(
            ZStack {
                Theme.surface
                PosterBackdrop(path: movie.poster_path)
                    .opacity(0.5)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .shadow(color: Theme.shadow.opacity(0.5), radius: 30, y: 12)
        .padding(.horizontal, 16)
        .onAppear {
            low = 0
            high = otherMovies.count
            if high > 0 {
                compare()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("ROUND \(round)")
                .font(.caption.weight(.heavy))
                .tracking(2)
                .foregroundStyle(Theme.accentGradient)
                .contentTransition(.numericText())
            Text(prompt)
                .font(.title3.weight(.bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            ProgressView(value: progress)
                .tint(Theme.accent)
                .animation(Theme.spring, value: progress)
                .padding(.horizontal, 40)
        }
    }

    private var versusBadge: some View {
        Text("VS")
            .font(.system(size: 15, weight: .black, design: .rounded))
            .foregroundColor(Theme.onAccent)
            .frame(width: 44, height: 44)
            .background(Theme.accentGradient)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.background, lineWidth: 4))
            .shadow(color: Theme.accentSecondary.opacity(0.5), radius: 10)
    }

    // How much of the list has been ruled out so far
    private var progress: Double {
        guard otherMovies.count > 0 else { return 1 }
        return 1 - Double(high - low) / Double(otherMovies.count)
    }

    // Every movie in the list except the one being ranked, in rank order
    private var otherMovies: [CDMovie] {
        movies.filter { $0.id != movie.id }
    }

    private func choose(_ side: Side) {
        // Ignore taps while the previous pick is still animating
        guard picked == nil, low < high else { return }
        Haptics.select()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            picked = side
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(Theme.spring) {
                if side == .selected {
                    high = middle
                } else {
                    low = middle + 1
                }
                picked = nil
                if low < high {
                    round += 1
                }
                compare()
            }
        }
    }

    private func compare() {
        if low >= high {
            Haptics.success()
            AppAnalytics.log(.filmRanked(.compare))
            // Only rankings that took at least one head-to-head pick count towards asking for a rating
            if !otherMovies.isEmpty { ReviewPrompter.rankingFinished(requestReview) }
            onRankingUpdate(movie, low + 1)
            return
        }
        middle = (low + high) / 2
    }
}

struct CompareMovieView_Previews: PreviewProvider{
    static var previews: some View {
        CompareMovieView(movies: .constant(Array(CDMovieList.example.movies)), movie: .constant(Array(CDMovieList.example.movies)[0])) { updatedMovie, rank in
            print(updatedMovie)
            
        }
            .environmentObject(NetworkService()) // Keep if needed
    }
}

