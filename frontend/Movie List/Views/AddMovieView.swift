//
//  AddMovieView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

struct AddMovieView: View {
    @ObservedObject var viewModel: ListViewModel
    @Environment(\.dismiss) var dismiss
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14)]

    var body: some View{
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchField
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    results
                }
            }
            .navigationTitle("Add a Movie or Show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear { searchFocused = true }
        // Search as the user types, waiting for a short pause between keystrokes
        .task(id: viewModel.newMovieSearchText) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled {
                viewModel.searchMovies()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.textSecondary)
            TextField("Search movies and TV shows…", text: $viewModel.newMovieSearchText)
                .focused($searchFocused)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit {
                    viewModel.searchMovies()
                }
            if !viewModel.newMovieSearchText.isEmpty {
                Button {
                    viewModel.newMovieSearchText = ""
                    viewModel.searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.textTertiary)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(14)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: viewModel.newMovieSearchText.isEmpty)
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.searchResults.isEmpty {
            Spacer()
            EmptyStateView(
                icon: "magnifyingglass",
                title: viewModel.newMovieSearchText.isEmpty ? "Find a film" : "No matches yet",
                message: viewModel.newMovieSearchText.isEmpty
                    ? "Search by title to add it to \(viewModel.movieList.name ?? "your list")."
                    : "Try a different spelling or the original title."
            )
            Spacer()
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(viewModel.searchResults.enumerated()), id: \.element.id) { index, apiMovie in
                        resultCard(apiMovie)
                            .appearAnimation(delay: Double(min(index, 12)) * 0.03)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func resultCard(_ apiMovie: Movie) -> some View {
        let alreadyAdded = viewModel.movies.contains { Int64($0.tmdb_id) == apiMovie.id }
        return Button {
            guard !alreadyAdded else { return }
            print("adding movie")
            Haptics.success()
            viewModel.createAndSaveMovie(from: apiMovie)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                PosterImage(path: apiMovie.poster_path, cornerRadius: 12, size: .medium)
                    .aspectRatio(2/3, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if alreadyAdded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.onAccent, Theme.accent)
                                .padding(6)
                        }
                    }
                    .opacity(alreadyAdded ? 0.5 : 1)
                Text(apiMovie.title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    if apiMovie.isTV {
                        TVBadge()
                    }
                    Text(Theme.year(from: apiMovie.release_date))
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct AddMovieView_Previews: PreviewProvider{
    static var previews: some View{
        AddMovieView(viewModel: ListViewModel(movieList: CDMovieList.example, context: PersistenceController.preview.container.viewContext))
            .preferredColorScheme(.dark)
    }
}
