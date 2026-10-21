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
    // The film being added to other lists, which opens the list picker
    @State private var addingToLists: CDMovie? = nil
    // Placing that film in each other list it went into, one list at a time, like Discover does
    @State private var otherListRanking: (model: ListViewModel, movie: CDMovie)? = nil
    @State private var otherListQueue: [(list: CDMovieList, movie: CDMovie)] = []
    @State private var toast: String? = nil
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
        self.movieList = movieList
    }
    // Observed so the title and description update right after the list is edited
    @ObservedObject private var movieList: CDMovieList
    // Active while the user drags films into a new order
    @State private var editMode: EditMode = .inactive
    @State private var editingDetails = false
    // Who's on the list, for shared lists and inviting people
    @ObservedObject private var sharing = ListSharing.shared
    @State private var showSharing = false
    @Environment(\.dismiss) private var dismiss
    
    // Search and genre filters only change which rows are shown; ranks stay as they are
    var filteredMovies: [CDMovie] {
        viewModel.movies.filter { movie in
            (viewModel.searchText.isEmpty || (movie.title ?? "").localizedCaseInsensitiveContains(viewModel.searchText))
                && viewModel.matchesGenreFilter(movie)
                && (!viewModel.showAIPlacedOnly || viewModel.isAIPlaced(movie))
        }
    }

    var isFiltering: Bool {
        !viewModel.searchText.isEmpty || !viewModel.selectedGenres.isEmpty || viewModel.showAIPlacedOnly
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
                    onCancel: dismissCompare,
                    onSmartPlace: viewModel.isRankingNewMovie && Personalization.aiAllowed ? {
                        dismissCompare()
                        viewModel.smartPlace(selectedMovie) { showToast($0) }
                    } : nil
                ) { updatedMovie, rank in
                    dismissCompare()
                    viewModel.updateMovieRanking(updatedMovie: updatedMovie, newRank: rank)
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .zIndex(2)
            }
            else if let otherListRanking {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { finishOtherListRanking(skipped: true) }
                    .transition(.opacity)
                    .zIndex(1)
                otherListCompare(model: otherListRanking.model, movie: otherListRanking.movie)
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
        .overlay(alignment: .top) { toastView }
        .sheet(item: $addingToLists) { movie in
            ListPickerSheet(
                title: movie.title ?? "",
                posterPath: movie.poster_path,
                isAlreadyIn: { list in list.movies.contains { $0.tmdb_id == movie.tmdb_id } },
                excluding: viewModel.movieList
            ) { lists in
                addToOtherLists(movie, lists)
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search this list")
        .onAppear { viewModel.loadInfo() }
        .navigationTitle(movieList.name ?? "No Movie Name")
        .navigationBarTitleDisplayMode(.large)
        .toolbarTitleMenu {
            // Only the owner can rename a shared list
            if sharing.isOwner(movieList.id) {
                Button {
                    editingDetails = true
                } label: {
                    Label("Edit Details", systemImage: "pencil")
                }
            }
            if viewModel.movies.count > 1 {
                Button {
                    startReordering()
                } label: {
                    Label("Reorder Films", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        Haptics.success()
                        withAnimation(Theme.spring) { editMode = .inactive }
                    }
                    .bold()
                }
            } else {
                // In the navigation bar, so they stay put while the list scrolls
                ToolbarItemGroup(placement: .topBarTrailing) {
                    toolbarActions
                }
            }
        }
        .sheet(isPresented: $editingDetails) {
            EditListSheet(movieList: movieList)
        }
        .sheet(isPresented: $showSharing) {
            ShareListSheet(listID: movieList.id, listName: movieList.name ?? "List") {
                dismiss()
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Couldn't save the new order", isPresented: $viewModel.reorderFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The list is back the way it was. Check your connection and try again.")
        }
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
                    ranked: viewModel.isRanked,
                    onAddToLists: { addingToLists = detailMovie },
                    onCompare: viewModel.movies.count > 1 && viewModel.isRanked ? { rankFromDetail(detailMovie) { viewModel.showCompareMovieView = true } } : nil,
                    onSetRank: viewModel.isRanked ? { rankFromDetail(detailMovie) { viewModel.showSetRank = true } } : nil,
                    onToggleWatched: { viewModel.setWatched(detailMovie, !detailMovie.watched) },
                    onSaveNote: { note, done in viewModel.setNote(detailMovie, note, completion: done) },
                    onApprovePlacement: viewModel.isAIPlaced(detailMovie) ? { viewModel.approvePlacement(detailMovie) } : nil
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
                if let overview = movieList.overview, !overview.isEmpty, !editMode.isEditing {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
                }
                if sharing.isShared(movieList.id), !editMode.isEditing {
                    SharedListBanner(listID: movieList.id) { showSharing = true }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
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
                    listActions
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    genreFilterBar
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                }
                if !isFiltering, let spotlight = viewModel.recommendedMovie {
                    SpotlightCard(movie: spotlight, ranked: viewModel.isRanked)
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
                    MovieRow(movie: movie, showCompareMovieView: $viewModel.showCompareMovieView, selectedMovie: $viewModel.selectedMovie, showSetRank: $viewModel.showSetRank, info: viewModel.info(of: movie), aiPlaced: viewModel.isAIPlaced(movie), addedBy: sharing.addedBy(listID: movieList.id, movieID: movie.id), ranked: viewModel.isRanked, onAddToLists: { addingToLists = movie }) {
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
                // Only while reordering, and never on a filtered list, where positions wouldn't be ranks
                .onMove(perform: editMode.isEditing && !isFiltering ? viewModel.moveMovie : nil)
            }
            .environment(\.editMode, $editMode)
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
    
    // How many films are watched, with the bulk watched actions
    var listActions: some View {
        HStack {
            Menu {
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
            } label: {
                actionChip("\(viewModel.watchedCount) of \(viewModel.movies.count) watched", systemImage: "eye")
            }
            .accessibilityLabel("Watched Options")
            Spacer()
            // A quiet reminder that the order here isn't a ranking
            if !viewModel.isRanked {
                Label("Unranked", systemImage: "circle.grid.2x2")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
                    .accessibilityLabel("Unranked list: the order doesn't matter")
            }
        }
        .padding(.horizontal, 16)
    }

    // Recommend, share/export and add, at the top right
    @ViewBuilder
    var toolbarActions: some View {
        Button {
            Haptics.tap()
            // The recommendation card is hidden while searching or filtering
            viewModel.searchText = ""
            viewModel.selectedGenres = []
            viewModel.showAIPlacedOnly = false
            withAnimation(Theme.spring) { viewModel.recommendMovie() }
            recommendationScrollRequest += 1
        } label: {
            Image(systemName: "dice")
        }
        .disabled(viewModel.movies.count < 2)
        .accessibilityLabel("Recommend a Film")
        Menu {
            Button {
                shareImage()
            } label: {
                Label(viewModel.movies.count > ListShareImage.maxFilms ? "Share Top \(ListShareImage.maxFilms) as Image" : "Share as Image", systemImage: "photo")
            }
            .disabled(viewModel.movies.isEmpty)
            Button {
                exportZip()
            } label: {
                Label("Export List (ZIP)", systemImage: "doc.zipper")
            }
            Divider()
            Button {
                showSharing = true
            } label: {
                if sharing.isOwner(movieList.id) {
                    Label(sharing.isShared(movieList.id) ? "Contributors…" : "Add Contributors…", systemImage: "person.badge.plus")
                } else {
                    Label("Who Can Edit", systemImage: "person.2")
                }
            }
        } label: {
            if isPreparingShare {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .disabled(isPreparingShare)
        .accessibilityLabel("Share or Export List")
        Button {
            Haptics.tap()
            viewModel.showPopup = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Theme.accentGradient)
        }
        .accessibilityLabel("Add a Film")
    }

    func actionChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    // Horizontally scrolling genre chips with counts. Tapping chips narrows the list to films that
    // have every selected genre; it never changes the list itself
    var genreFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Only offered while some films were placed by the AI and not yet approved
                if viewModel.hasAIPlacedFilms || viewModel.showAIPlacedOnly {
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.spring) { viewModel.showAIPlacedOnly.toggle() }
                    } label: {
                        Label("Placed by AI", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(viewModel.showAIPlacedOnly ? Theme.onAccent : Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(viewModel.showAIPlacedOnly ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.92))
                }
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
        guard !editMode.isEditing else { return }
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

    // Shows every film so each one can be dragged to its new rank
    func startReordering() {
        Haptics.tap()
        viewModel.searchText = ""
        viewModel.selectedGenres = []
        withAnimation(Theme.spring) { editMode = .active }
    }

    func addToOtherLists(_ movie: CDMovie, _ lists: [CDMovieList]) {
        guard !lists.isEmpty else { return }
        viewModel.addCopy(of: movie, to: lists) { added in
            guard !added.isEmpty else {
                showToast("Couldn't add \(movie.title ?? "it"). Try again.")
                return
            }
            if added.count < lists.count {
                showToast("Added to \(added.count) of \(lists.count) lists. Try the rest again.")
            } else if added.count > 1 {
                showToast("Added to \(added.count) lists")
            }
            // New films land at the bottom, so ask where it belongs in each list that has other films
            otherListQueue = added.filter { $0.list.movies.count > 1 }
            if !startNextOtherListRanking(), added.count == 1, let only = added.first {
                showToast("Added to \(only.list.name ?? "your list") at #\(only.movie.rank)")
            }
        }
    }

    /// Starts placing the film in the next list waiting for it; false when there are none left
    @discardableResult
    func startNextOtherListRanking() -> Bool {
        guard let next = otherListQueue.first else { return false }
        otherListQueue.removeFirst()
        let model = ListViewModel(movieList: next.list, context: next.list.managedObjectContext ?? viewModel.movieList.managedObjectContext!)
        // Give the list picker time to finish closing before Compare appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(Theme.spring) { otherListRanking = (model, next.movie) }
        }
        return true
    }

    func finishOtherListRanking(skipped: Bool) {
        if skipped, let current = otherListRanking {
            showToast("Added to \(current.model.movieList.name ?? "your list") at #\(current.movie.rank)")
        }
        withAnimation(Theme.spring) { otherListRanking = nil }
        startNextOtherListRanking()
    }

    func otherListCompare(model: ListViewModel, movie: CDMovie) -> some View {
        let listName = model.movieList.name ?? "your list"
        return CompareMovieView(
            movies: Binding(get: { model.movies }, set: { model.movies = $0 }),
            movie: .constant(movie),
            prompt: "Where does \(movie.title ?? "it") rank in \(listName)?",
            cancelTitle: "Skip — keep it at the bottom",
            onCancel: { finishOtherListRanking(skipped: true) },
            onSmartPlace: Personalization.aiAllowed ? {
                model.smartPlace(movie) { message in showToast("\(message) in \(listName)") }
                finishOtherListRanking(skipped: false)
            } : nil
        ) { rankedMovie, rank in
            model.updateMovieRanking(updatedMovie: rankedMovie, newRank: rank)
            showToast("Ranked #\(rank) in \(listName)")
            finishOtherListRanking(skipped: false)
        }
    }

    func showToast(_ message: String) {
        withAnimation(Theme.spring) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(Theme.spring) {
                if toast == message { toast = nil }
            }
        }
    }

    @ViewBuilder
    var toastView: some View {
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
    var ranked = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PosterImage(path: movie.poster_path, cornerRadius: 14, size: .medium)
                .frame(width: 112, height: 168)
                .overlay(alignment: .topLeading) { if ranked { rankBadge } }
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
