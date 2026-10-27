//
//  MoreLikeThisView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-27.
//

import Foundation
import SwiftUI

/// More Like This: films like one film, from TMDb's recommendations for it, to add to a list. Films already in
/// the user's lists and ones they marked Not for Me in Discover are left out. Tapping a film opens its info,
/// which has its own More Like This, so one film can lead to the next
struct MoreLikeThisView: View {
    let source: Movie

    @Environment(\.dismiss) private var dismiss
    @FetchRequest(fetchRequest: CDMovieList.fetch()) private var movieLists: FetchedResults<CDMovieList>
    @State private var films: [Movie] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var details: CDMovie? = nil
    @State private var detailsMovie: Movie? = nil
    @State private var adding: Movie? = nil
    // Films added from here, so their button changes straight away
    @State private var added: Set<Int64> = []

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 14, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .disabled(isLoading)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("More Like This")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
            .sheet(item: $details) { preview in
                // Add to Lists closes the info screen and asks which lists
                MovieDetailView(movie: preview, onAddToLists: {
                    let movie = detailsMovie
                    details = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { adding = movie }
                })
            }
            // The same list picker and Compare as adding anywhere else
            .addToListFlow(movie: $adding, source: .moreLikeThis) { movie, _ in
                added.insert(movie.id)
            }
        }
        .onAppear {
            guard films.isEmpty && !isLoading else { return }
            AppAnalytics.log(.moreLikeThisOpened)
            load()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PosterImage(path: source.poster_path, cornerRadius: 6, size: .small)
                .frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.isTV ? "SHOWS LIKE" : "FILMS LIKE")
                    .font(.caption.weight(.heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.accentGradient)
                Text(source.title)
                    .font(.title3.weight(.heavy))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                let year = Theme.year(from: source.release_date)
                if !year.isEmpty {
                    Text(year)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    // A spinner while loading, a way to try again if it failed, a note when nothing's left, otherwise the films
    @ViewBuilder private var content: some View {
        if isLoading {
            ProgressView("Finding films…")
                .tint(Theme.accent)
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        } else if loadFailed {
            VStack(spacing: 10) {
                Text("Couldn't load films like this.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                Button("Try Again") {
                    Haptics.tap()
                    load()
                }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else if films.isEmpty {
            Text("Nothing new like this one. You've already got the closest matches in your lists.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        } else {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(films) { film in
                    cell(film)
                }
            }
            // TMDb's terms ask apps to credit them where their data is shown
            Text("Recommendations from TMDB")
                .font(.caption2)
                .foregroundColor(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private func cell(_ film: Movie) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Haptics.tap()
                detailsMovie = film
                details = PersistenceController.stackedPreview(of: film)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    PosterImage(path: film.poster_path, cornerRadius: 10, size: .small)
                        .aspectRatio(2 / 3, contentMode: .fit)
                    Text(film.title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(Theme.year(from: film.release_date))
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.96))
            .accessibilityLabel("\(film.title), \(Theme.year(from: film.release_date))")
            .accessibilityHint("Shows film info")
            if added.contains(film.id) {
                Label("Added", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.vertical, 7)
            } else {
                Button {
                    Haptics.tap()
                    adding = film
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accentGradient, in: Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add \(film.title) to your lists")
            }
        }
    }

    private func load() {
        isLoading = true
        loadFailed = false
        APIService.shared.fetchSimilarFilms(tmdbID: source.id) { result in
            isLoading = false
            switch result {
            case .success(let similar):
                // The server leaves out films in the user's lists; this also catches ones added since it last synced,
                // and the ones marked Not for Me, which are only kept on this device
                let listed = Set(movieLists.flatMap { $0.movies.map { Int64($0.tmdb_id) } })
                let disliked = Set((UserDefaults.standard.array(forKey: DiscoverViewModel.dislikedKey) as? [Int] ?? []).map(Int64.init))
                films = similar.filter { !listed.contains($0.id) && !disliked.contains($0.id) && $0.id != source.id }
            case .failure:
                loadFailed = true
            }
        }
    }
}
