//
//  AddToListFlow.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-26.
//

import Foundation
import SwiftUI

/// The standard way to add a film from outside a list, the same as Discover: choose lists with the list picker
/// (lists it's already in can't be picked), then place it in each ranked list that has other films, one list at
/// a time, with the head-to-head Compare, Smart Placement where AI is allowed, or Skip to keep it at the bottom.
/// The screen is blocked with a spinner while the film is being added
struct AddToListFlow: ViewModifier {
    // Setting it opens the list picker; it goes back to nil when the picker closes
    @Binding var movie: Movie?
    let source: AppAnalytics.FilmSource
    // Called on the main thread with the lists the film went into and its new copy in each, before ranking
    var onAdded: (Movie, [(list: CDMovieList, movie: CDMovie)]) -> Void

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @State private var isAdding = false
    // Placing the film in the list being ranked now, and the lists still waiting after it
    @State private var ranking: (model: ListViewModel, movie: CDMovie)? = nil
    @State private var rankingQueue: [(list: CDMovieList, movie: CDMovie)] = []
    @State private var toast: String? = nil

    func body(content: Content) -> some View {
        content
            .disabled(isAdding)
            .overlay {
                if isAdding {
                    ZStack {
                        Theme.scrim.ignoresSafeArea()
                        ProgressView("Adding…")
                            .tint(Theme.accent)
                            .foregroundColor(Theme.textPrimary)
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if let ranking {
                    ZStack {
                        Theme.scrim
                            .ignoresSafeArea()
                            .onTapGesture { skipRanking() }
                            .transition(.opacity)
                        rankingOverlay(model: ranking.model, movie: ranking.movie)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
            }
            .overlay(alignment: .top) { toastView }
            .sheet(item: $movie) { movie in
                ListPickerSheet(
                    title: movie.title,
                    posterPath: movie.poster_path,
                    isAlreadyIn: { list in list.movies.contains { Int64($0.tmdb_id) == movie.id } }
                ) { lists in
                    add(movie, to: lists)
                }
                .environmentObject(authViewModel)
                .environment(\.managedObjectContext, context)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }

    private func add(_ movie: Movie, to lists: [CDMovieList]) {
        guard !lists.isEmpty else { return }
        withAnimation(Theme.spring) { isAdding = true }
        var added: [Int: CDMovie] = [:]
        let group = DispatchGroup()
        for (index, list) in lists.enumerated() {
            group.enter()
            list.addMovie(tmdbID: movie.id, context: context) { newMovie in
                added[index] = newMovie
                group.leave()
            }
        }
        group.notify(queue: .main) {
            withAnimation(Theme.spring) { isAdding = false }
            let done = lists.indices.compactMap { index in added[index].map { (list: lists[index], movie: $0) } }
            guard !done.isEmpty else {
                showToast("Couldn't add \(movie.title). Try again.")
                return
            }
            AppAnalytics.log(.filmAdded(source))
            onAdded(movie, done)
            if done.count < lists.count {
                showToast("Added to \(done.count) of \(lists.count) lists. Try the rest again.")
            } else if done.count > 1 {
                showToast("Added to \(done.count) lists")
            }
            // New films land at the bottom, so ask where it belongs in each ranked list that has other films
            rankingQueue = done.filter { $0.list.movies.count > 1 && ListRanking.isRanked($0.list.id) }
            if !startNextRanking(), done.count == 1, let only = done.first {
                showToast("Added to \(only.list.name ?? "your list") at #\(only.movie.rank)")
            }
        }
    }

    /// Starts placing the film in the next list waiting for it; false when there are none left
    @discardableResult
    private func startNextRanking() -> Bool {
        guard let next = rankingQueue.first else { return false }
        rankingQueue.removeFirst()
        let model = ListViewModel(movieList: next.list, context: context)
        // Give the list picker time to finish closing before Compare appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(Theme.spring) { ranking = (model, next.movie) }
        }
        return true
    }

    private func endRanking() {
        withAnimation(Theme.spring) { ranking = nil }
        startNextRanking()
    }

    private func skipRanking() {
        if let current = ranking {
            showToast("Added to \(current.model.movieList.name ?? "your list") at #\(current.movie.rank)")
        }
        endRanking()
    }

    private func rankingOverlay(model: ListViewModel, movie: CDMovie) -> some View {
        let listName = model.movieList.name ?? "your list"
        return CompareMovieView(
            movies: Binding(get: { model.movies }, set: { model.movies = $0 }),
            movie: .constant(movie),
            prompt: "Where does \(movie.title ?? "it") rank in \(listName)?",
            cancelTitle: "Skip — keep it at the bottom",
            onCancel: skipRanking,
            onSmartPlace: Personalization.aiAllowed ? {
                endRanking()
                model.smartPlace(movie) { message in showToast("\(message) in \(listName)") }
            } : nil
        ) { rankedMovie, rank in
            model.updateMovieRanking(updatedMovie: rankedMovie, newRank: rank)
            endRanking()
            showToast("Ranked #\(rank) in \(listName)")
        }
    }

    private func showToast(_ message: String) {
        withAnimation(Theme.spring) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(Theme.spring) {
                if toast == message { toast = nil }
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: Theme.shadow.opacity(0.4), radius: 16, y: 8)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension View {
    /// Adds the film in `movie` to the lists the user picks, the same way as everywhere else in the app: list
    /// picker, then Compare (or Smart Placement) in each ranked list. Logs `film_added` with `source`
    func addToListFlow(movie: Binding<Movie?>, source: AppAnalytics.FilmSource,
                       onAdded: @escaping (Movie, [(list: CDMovieList, movie: CDMovie)]) -> Void = { _, _ in }) -> some View {
        modifier(AddToListFlow(movie: movie, source: source, onAdded: onAdded))
    }
}
