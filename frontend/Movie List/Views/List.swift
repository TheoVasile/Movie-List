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
    @Environment(\.colorScheme) private var colorScheme
    // The image or ZIP waiting to go to the share sheet
    @State private var shareItem: ShareItem? = nil
    @State private var isPreparingShare = false
    @State private var detailMovie: CDMovie? = nil
    @State private var showDetail = false
    @State private var highlightedMovieID: Int64? = nil
    // Bumped by the recommend button so the list scrolls up to the new pick
    @State private var recommendationScrollRequest = 0
    // Set while asking to confirm marking the whole list watched (true) or unwatched (false)
    @State private var pendingBulkWatched: Bool? = nil

    init(movieList: CDMovieList, context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: ListViewModel(movieList: movieList, context: context))
    }
    
    // Search and genre filters only change which rows are shown; ranks stay as they are
    var filteredMovies: [CDMovie] {
        viewModel.movies.filter { movie in
            (viewModel.searchText.isEmpty || (movie.title ?? "").localizedCaseInsensitiveContains(viewModel.searchText))
                && viewModel.matchesGenreFilter(movie)
        }
    }

    var isFiltering: Bool {
        !viewModel.searchText.isEmpty || !viewModel.selectedGenres.isEmpty
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            MovieListSection
            if viewModel.showCompareMovieView, let selectedMovie = viewModel.selectedMovie {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { dismissCompare() }
                    .transition(.opacity)
                    .zIndex(1)
                CompareMovieView(
                    movies: $viewModel.movies,
                    movie: Binding.constant(selectedMovie),
                    prompt: viewModel.isRankingNewMovie ? "Where does \(selectedMovie.title ?? "it") rank?" : "Which do you prefer?",
                    cancelTitle: viewModel.isRankingNewMovie ? "Skip — keep it at the bottom" : "Cancel",
                    onCancel: dismissCompare
                ) { updatedMovie, rank in
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
        .onAppear { viewModel.loadInfo() }
        .navigationTitle(viewModel.movieList.name ?? "No Movie Name")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarOptions }
        .confirmationDialog(
            bulkWatchedTitle,
            isPresented: Binding(get: { pendingBulkWatched != nil }, set: { if !$0 { pendingBulkWatched = nil } }),
            titleVisibility: .visible,
            presenting: pendingBulkWatched
        ) { watched in
            Button(watched ? "Mark All as Watched" : "Mark All as Unwatched", role: watched ? nil : .destructive) {
                Haptics.success()
                viewModel.setAllWatched(watched)
            }
        } message: { watched in
            if !watched {
                Text("They'll also show as unwatched in your other lists.")
            }
        }
        .sheet(isPresented: $viewModel.showPopup) {
            AddMovieView(viewModel: viewModel)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: $showDetail) {
            if let detailMovie {
                MovieDetailView(
                    movie: detailMovie,
                    listName: viewModel.movieList.name,
                    onCompare: viewModel.movies.count > 1 ? { rankFromDetail(detailMovie) { viewModel.showCompareMovieView = true } } : nil,
                    onSetRank: { rankFromDetail(detailMovie) { viewModel.showSetRank = true } },
                    onToggleWatched: { viewModel.setWatched(detailMovie, !detailMovie.watched) }
                )
            }
        }
    }
}

// MARK: - UI Components
private extension ListView {
    var MovieListSection: some View {
        ScrollViewReader { proxy in
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
                } else {
                    genreFilterBar
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                }
                if !isFiltering, let spotlight = viewModel.recommendedMovie {
                    SpotlightCard(movie: spotlight)
                        // Prefixed so it can't collide with the ranked row of the same movie when scrolling
                        .id("spotlight-\(spotlight.id)")
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .onTapGesture { openDetail(spotlight) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                }
                if !viewModel.selectedGenres.isEmpty && filteredMovies.isEmpty {
                    Text("No films in this list match all of those genres.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(filteredMovies, id: \.id) { movie in
                    MovieRow(movie: movie, showCompareMovieView: $viewModel.showCompareMovieView, selectedMovie: $viewModel.selectedMovie, showSetRank: $viewModel.showSetRank, info: viewModel.info(of: movie)) {
                        viewModel.setWatched(movie, !movie.watched)
                    }
                        .contentShape(Rectangle())
                        .onTapGesture { openDetail(movie) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .overlay { highlightRing(for: movie) }
                        // Rows with custom swipe actions lose the built-in swipe to delete, so it's added back here
                        .swipeActions(edge: .leading) {
                            Button {
                                Haptics.tap()
                                viewModel.setWatched(movie, !movie.watched)
                            } label: {
                                Label(movie.watched ? "Unwatched" : "Watched", systemImage: movie.watched ? "eye.slash" : "eye")
                            }
                            .tint(movie.watched ? .gray : Theme.accentSecondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(movie)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .id(movie.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.movedMovieID) { movieID in
                guard let movieID else { return }
                scrollToMovedMovie(movieID, proxy: proxy)
            }
            .onChange(of: recommendationScrollRequest) { _ in
                guard let pick = viewModel.recommendedMovie else { return }
                // Wait a run loop so the card for the new pick exists before scrolling to it
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo("spotlight-\(pick.id)", anchor: .top)
                    }
                }
            }
        }
    }

    // Outline that glows around a movie right after its rank changes. Only built for that one
    // row, since a glow drawn at zero opacity still costs a shadow pass on every row
    @ViewBuilder
    func highlightRing(for movie: CDMovie) -> some View {
        if highlightedMovieID == movie.id {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.accentGradient, lineWidth: 2.5)
                .shadow(color: Theme.accent.opacity(0.6), radius: 10)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    func scrollToMovedMovie(_ movieID: Int64, proxy: ScrollViewProxy) {
        viewModel.movedMovieID = nil
        // A search or genre filter that hides the movie would leave nothing to scroll to
        if !filteredMovies.contains(where: { $0.id == movieID }) {
            viewModel.searchText = ""
            viewModel.selectedGenres = []
        }
        // Let the rows finish sliding into their new order before scrolling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo(movieID, anchor: .center)
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.35)) {
                highlightedMovieID = movieID
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeOut(duration: 0.6)) {
                    if highlightedMovieID == movieID { highlightedMovieID = nil }
                }
            }
        }
    }
    
    @ToolbarContentBuilder
    var ToolbarOptions: some ToolbarContent {
        // On its own on the left, next to Back: with four buttons on the right, iOS would fold one
        // of them into a "more" (•••) menu
        ToolbarItem(placement: .topBarLeading) {
            if !viewModel.movies.isEmpty {
                Menu {
                    Button {
                        shareImage()
                    } label: {
                        Label(viewModel.movies.count > ListShareImage.maxFilms ? "Share Top \(ListShareImage.maxFilms) as Image" : "Share as Image", systemImage: "photo")
                    }
                    Button {
                        exportZip()
                    } label: {
                        Label("Export List (ZIP)", systemImage: "doc.zipper")
                    }
                } label: {
                    if isPreparingShare {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isPreparingShare)
                .accessibilityLabel("Share List")
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if viewModel.movies.count > 1 {
                Button {
                    Haptics.tap()
                    // The recommendation card is hidden while searching or filtering
                    viewModel.searchText = ""
                    viewModel.selectedGenres = []
                    withAnimation(Theme.spring) { viewModel.recommendMovie() }
                    recommendationScrollRequest += 1
                } label: {
                    Image(systemName: "dice.fill")
                }
                .accessibilityLabel("Recommend Movie")
            }
            if !viewModel.movies.isEmpty {
                Menu {
                    Section("\(viewModel.watchedCount) of \(viewModel.movies.count) watched") {
                        Button {
                            pendingBulkWatched = true
                        } label: {
                            Label("Mark All as Watched", systemImage: "eye")
                        }
                        .disabled(viewModel.watchedCount == viewModel.movies.count)
                        Button {
                            pendingBulkWatched = false
                        } label: {
                            Label("Mark All as Unwatched", systemImage: "eye.slash")
                        }
                        .disabled(viewModel.watchedCount == 0)
                    }
                } label: {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel("Watched Options")
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

    // Horizontally scrolling genre chips with counts. Tapping chips narrows the list to films that
    // have every selected genre; it never changes the list itself
    var genreFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !viewModel.selectedGenres.isEmpty {
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.spring) { viewModel.selectedGenres = [] }
                    } label: {
                        Label("Clear", systemImage: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.surfaceRaised)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.92))
                    .transition(.scale.combined(with: .opacity))
                }
                ForEach(viewModel.genreCounts, id: \.genre) { item in
                    genreChip(item.genre, count: item.count)
                }
                if viewModel.isLoadingGenres {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading genres…")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                }
            }
            .padding(.horizontal, 16)
            .animation(Theme.spring, value: viewModel.selectedGenres)
        }
    }

    func genreChip(_ genre: Int, count: Int) -> some View {
        let isSelected = viewModel.selectedGenres.contains(genre)
        return Button {
            Haptics.tap()
            withAnimation(Theme.spring) { viewModel.toggleGenre(genre) }
        } label: {
            HStack(spacing: 5) {
                Text(TasteProfile.genreNames[genre] ?? "Other")
                Text("\(count)")
                    .foregroundColor(isSelected ? Theme.onAccent.opacity(0.6) : Theme.textTertiary)
            }
            .font(.caption.weight(.bold))
            .foregroundColor(isSelected ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isSelected ? Color.clear : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func shareImage() {
        Haptics.tap()
        isPreparingShare = true
        Task {
            let image = await ListShareImage.render(viewModel.movieList, colorScheme: colorScheme)
            isPreparingShare = false
            if let image {
                shareItem = ShareItem(items: [image])
            }
        }
    }

    func exportZip() {
        Haptics.tap()
        do {
            shareItem = ShareItem(items: [try ListExport.makeZip(lists: [viewModel.movieList])])
        } catch {
            print("Error exporting list:", error)
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
        viewModel.isRankingNewMovie = false
    }

    func delete(_ movie: CDMovie) {
        guard let index = viewModel.movies.firstIndex(of: movie) else { return }
        viewModel.deleteMovie(at: IndexSet(integer: index))
    }

    var bulkWatchedTitle: String {
        let count = viewModel.movies.count
        let films = "\(count) \(count == 1 ? "film" : "films")"
        return pendingBulkWatched == false ? "Mark all \(films) as unwatched?" : "Mark all \(films) as watched?"
    }
}

// MARK: - Spotlight

private struct SpotlightCard: View {
    @ObservedObject var movie: CDMovie

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PosterImage(path: movie.poster_path, cornerRadius: 14, size: .medium)
                .frame(width: 112, height: 168)
                .overlay(alignment: .topLeading) { rankBadge }
                .shadow(color: Theme.shadow.opacity(0.6), radius: 14, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                Label("TONIGHT'S PICK", systemImage: "moon.fill")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accentGradient)
                Text(movie.title ?? "")
                    .font(.title3.weight(.heavy))
                    .foregroundColor(Theme.textPrimary)
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
        .shadow(color: Theme.shadow.opacity(0.4), radius: 18, y: 10)
    }

    private var rankBadge: some View {
        Text("#\(movie.rank)")
            .font(.system(size: 15, weight: .black, design: .rounded))
            .foregroundColor(Theme.onAccent)
            .contentTransition(.numericText())
            .animation(Theme.spring, value: movie.rank)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.accentGradient)
            .clipShape(Capsule())
            .shadow(color: Theme.shadow.opacity(0.4), radius: 6, y: 2)
            .padding(8)
            .accessibilityLabel("Ranked \(movie.rank) in this list")
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
