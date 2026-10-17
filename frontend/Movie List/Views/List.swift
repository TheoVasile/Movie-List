//
//  List.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI
import CoreData

struct ListView: View {
    @EnvironmentObject var network: NetworkService
    @StateObject var viewModel: ListViewModel
    @State private var detailMovie: CDMovie? = nil
    @State private var showDetail = false

    init(movieList: CDMovieList, context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: ListViewModel(movieList: movieList, context: context))
    }
    
    var filteredMovies: [CDMovie] {
        if viewModel.searchText.isEmpty {
            return viewModel.movies
        } else {
            return viewModel.movies.filter { movie in
                (movie.title ?? "").localizedCaseInsensitiveContains(viewModel.searchText)
                        }
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            MovieListSection
            if viewModel.showCompareMovieView, let selectedMovie = viewModel.selectedMovie {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { dismissCompare() }
                    .transition(.opacity)
                    .zIndex(1)
                CompareMovieView(movies: $viewModel.movies, movie: Binding.constant(selectedMovie), onCancel: dismissCompare) { updatedMovie, rank in
                    dismissCompare()
                    viewModel.updateMovieRanking(updatedMovie: updatedMovie, newRank: rank)
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .zIndex(2)
            }
            else if viewModel.showSetRank, let selectedMovie = viewModel.selectedMovie {
                SetRankView(movie: Binding.constant(selectedMovie), movieCount: viewModel.movies.count, showSetRank: $viewModel.showSetRank) {updatedMovie, rank in
                    withAnimation(Theme.spring) { viewModel.showSetRank = false }
                    viewModel.updateMovieRanking(updatedMovie: updatedMovie, newRank: rank)
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search this list")
        .navigationTitle(viewModel.movieList.name ?? "No Movie Name")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarOptions }
        .sheet(isPresented: $viewModel.showPopup) {
            AddMovieView(viewModel: viewModel)
        }
        .navigationDestination(isPresented: $showDetail) {
            if let detailMovie {
                MovieDetailView(
                    movie: detailMovie,
                    listName: viewModel.movieList.name,
                    onCompare: viewModel.movies.count > 1 ? { rankFromDetail(detailMovie) { viewModel.showCompareMovieView = true } } : nil,
                    onSetRank: { rankFromDetail(detailMovie) { viewModel.showSetRank = true } }
                )
            }
        }
    }
}

// MARK: - UI Components
private extension ListView {
    var MovieListSection: some View {
        List {
            if viewModel.movies.isEmpty {
                EmptyStateView(
                    icon: "film",
                    title: "This list is empty",
                    message: "Add a few films, then rank them head to head.",
                    actionTitle: "Add a Film"
                ) {
                    viewModel.showPopup = true
                }
                .padding(.top, 60)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if viewModel.searchText.isEmpty, let spotlight = viewModel.recommendedMovie ?? viewModel.movies.first {
                SpotlightCard(movie: spotlight, isRecommendation: viewModel.recommendedMovie != nil)
                    .id(spotlight.id)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .onTapGesture { openDetail(spotlight) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                    .appearAnimation()
            }
            ForEach(Array(filteredMovies.enumerated()), id: \.element.id) { index, movie in
                MovieRow(movie: movie, showCompareMovieView: $viewModel.showCompareMovieView, selectedMovie: $viewModel.selectedMovie, showSetRank: $viewModel.showSetRank)
                    .contentShape(Rectangle())
                    .onTapGesture { openDetail(movie) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .appearAnimation(delay: Double(min(index, 10)) * 0.04)
            }
            .onDelete(perform: deleteFilteredMovies)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
    
    @ToolbarContentBuilder
    var ToolbarOptions: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if viewModel.movies.count > 1 {
                Button {
                    Haptics.tap()
                    withAnimation(Theme.spring) { viewModel.recommendMovie() }
                } label: {
                    Image(systemName: "dice.fill")
                }
                .accessibilityLabel("Recommend Movie")
            }
            Button {
                Haptics.tap()
                viewModel.showPopup = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.accentGradient)
            }
            .accessibilityLabel("Add Movie")
        }
    }

    func openDetail(_ movie: CDMovie) {
        Haptics.tap()
        detailMovie = movie
        showDetail = true
    }

    // Pops the detail screen, then brings up a ranking overlay once the pop has finished
    func rankFromDetail(_ movie: CDMovie, show: @escaping () -> Void) {
        showDetail = false
        viewModel.selectedMovie = movie
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(Theme.spring, show)
        }
    }

    func dismissCompare() {
        withAnimation(Theme.spring) { viewModel.showCompareMovieView = false }
    }

    // Offsets refer to the filtered rows, so map them back onto the full list
    func deleteFilteredMovies(at offsets: IndexSet) {
        let ids = Set(offsets.map { filteredMovies[$0].id })
        let indices = IndexSet(viewModel.movies.indices.filter { ids.contains(viewModel.movies[$0].id) })
        viewModel.deleteMovie(at: indices)
    }
}

// MARK: - Spotlight

private struct SpotlightCard: View {
    @ObservedObject var movie: CDMovie
    let isRecommendation: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PosterImage(path: movie.poster_path, cornerRadius: 14)
                .frame(width: 112, height: 168)
                .shadow(color: .black.opacity(0.6), radius: 14, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                Label(isRecommendation ? "TONIGHT'S PICK" : "#1 IN THIS LIST",
                      systemImage: isRecommendation ? "sparkles" : "crown.fill")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accentGradient)
                Text(movie.title ?? "")
                    .font(.title3.weight(.heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(Theme.year(from: movie.release_date))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                if let overview = movie.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Theme.surface
                PosterBackdrop(path: movie.poster_path)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Theme.accent.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }
}


struct List_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ListView(movieList: CDMovieList.example, context: PersistenceController.preview.container.viewContext)
                .environmentObject(NetworkService())
        }
        .preferredColorScheme(.dark)
    }
}
