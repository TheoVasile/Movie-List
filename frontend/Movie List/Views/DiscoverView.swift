//
//  DiscoverView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI

struct DiscoverView: View {
    @Environment(\.managedObjectContext) var context
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var movieLists: FetchedResults<CDMovieList>
    @StateObject private var viewModel = DiscoverViewModel()

    @State private var dragOffset: CGSize = .zero
    @State private var showDetails = false
    // The film swiped right, waiting for the user to pick a list
    @State private var pendingMovie: Movie? = nil
    @State private var showListPicker = false
    @State private var choseList = false
    @State private var toast: String? = nil

    private let swipeThreshold: CGFloat = 110

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                PosterBackdrop(path: viewModel.topMovie?.poster_path)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.5), value: viewModel.topMovie?.id)
                VStack(spacing: 22) {
                    cardStack
                        .frame(maxHeight: .infinity)
                    if viewModel.topMovie != nil {
                        actionButtons
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .overlay(alignment: .top) { toastView }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            withAnimation(Theme.spring) { viewModel.showSkippedAgain() }
                        } label: {
                            Label("Show Skipped Films Again", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showListPicker, onDismiss: listPickerDismissed) {
            listPicker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear(perform: syncWithLists)
        .onChange(of: listedIDs) { _ in syncWithLists() }
    }
}

// MARK: - Cards
private extension DiscoverView {
    @ViewBuilder
    var cardStack: some View {
        if viewModel.deck.isEmpty {
            emptyState
        } else {
            ZStack {
                ForEach(Array(viewModel.deck.prefix(3).enumerated()).reversed(), id: \.element.id) { index, movie in
                    DiscoverCard(movie: movie, showDetails: index == 0 && showDetails)
                        .overlay { if index == 0 { swipeStamps } }
                        // Cards behind the top one sit lower and smaller, and grow as the top card is dragged away
                        .scaleEffect(index == 0 ? 1 : 1 - CGFloat(index) * 0.05 + (index == 1 ? dragProgress * 0.05 : 0))
                        .offset(y: index == 0 ? 0 : CGFloat(index) * 16 - (index == 1 ? dragProgress * 16 : 0))
                        .offset(index == 0 ? dragOffset : .zero)
                        .rotationEffect(.degrees(index == 0 ? Double(dragOffset.width / 18) : 0), anchor: .bottom)
                        .gesture(dragGesture, including: index == 0 ? .all : .none)
                        .onTapGesture {
                            guard index == 0 else { return }
                            Haptics.tap()
                            withAnimation(Theme.spring) { showDetails.toggle() }
                        }
                        .zIndex(Double(3 - index))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    // 0 at rest, 1 once the top card has been dragged past the swipe threshold
    var dragProgress: CGFloat {
        min(abs(dragOffset.width) / swipeThreshold, 1)
    }

    var swipeStamps: some View {
        ZStack {
            stamp("ADD", color: Theme.accent, rotation: -14)
                .opacity(Double(max(dragOffset.width, 0) / swipeThreshold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            stamp("PASS", color: Theme.accentSecondary, rotation: 14)
                .opacity(Double(max(-dragOffset.width, 0) / swipeThreshold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(28)
        .allowsHitTesting(false)
    }

    func stamp(_ text: String, color: Color, rotation: Double) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .black, design: .rounded))
            .tracking(2)
            .foregroundColor(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 4))
            .rotationEffect(.degrees(rotation))
    }

    var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                // A quick flick counts even if the card hasn't travelled far
                let projected = value.predictedEndTranslation.width
                if value.translation.width > swipeThreshold || projected > swipeThreshold * 3 {
                    swipeRight()
                } else if value.translation.width < -swipeThreshold || projected < -swipeThreshold * 3 {
                    swipeLeft()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    var actionButtons: some View {
        HStack(spacing: 28) {
            circleButton(icon: "xmark", size: 64, style: AnyShapeStyle(Theme.accentSecondary), filled: false) {
                swipeLeft()
            }
            .accessibilityLabel("Pass")
            circleButton(icon: showDetails ? "info.circle.fill" : "info", size: 48, style: AnyShapeStyle(Theme.textSecondary), filled: false) {
                withAnimation(Theme.spring) { showDetails.toggle() }
            }
            .accessibilityLabel("Details")
            circleButton(icon: "plus", size: 64, style: AnyShapeStyle(Theme.accentGradient), filled: true) {
                swipeRight()
            }
            .accessibilityLabel("Add to a list")
        }
    }

    func circleButton(icon: String, size: CGFloat, style: AnyShapeStyle, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .heavy))
                .foregroundStyle(filled ? AnyShapeStyle(Color.black) : style)
                .frame(width: size, height: size)
                .background(filled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.88))
    }

    @ViewBuilder
    var emptyState: some View {
        if viewModel.loadFailed {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "Couldn't load films",
                message: "Check your connection and that the server is running.",
                actionTitle: "Try Again"
            ) {
                viewModel.retry()
            }
        } else if viewModel.isExhausted {
            EmptyStateView(
                icon: "checkmark.seal",
                title: "You're all caught up",
                message: "You've seen every recommendation for now.",
                actionTitle: "Show Skipped Films"
            ) {
                withAnimation(Theme.spring) { viewModel.showSkippedAgain() }
            }
        } else {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
                    .aspectRatio(2/3, contentMode: .fit)
                Text("Finding films for you…")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Swipe actions
private extension DiscoverView {
    func swipeLeft() {
        guard let movie = viewModel.topMovie else { return }
        Haptics.tap()
        withAnimation(.easeIn(duration: 0.22)) {
            dragOffset = CGSize(width: -700, height: dragOffset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(Theme.spring) {
                viewModel.pass(movie)
                dragOffset = .zero
                showDetails = false
            }
        }
    }

    // Flies the card off to the right and asks which list it goes in.
    // Cancelling brings the card back.
    func swipeRight() {
        guard let movie = viewModel.topMovie else { return }
        Haptics.select()
        pendingMovie = movie
        withAnimation(.easeIn(duration: 0.22)) {
            dragOffset = CGSize(width: 700, height: dragOffset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showListPicker = true
        }
    }

    func choose(_ list: CDMovieList) {
        guard let movie = pendingMovie else { return }
        Haptics.success()
        choseList = true
        showListPicker = false
        withAnimation(Theme.spring) {
            viewModel.add(movie, to: list, context: context) { newMovie in
                if let newMovie {
                    showToast("Added to \(list.name ?? "your list") at #\(newMovie.rank)")
                } else {
                    showToast("Couldn't add \(movie.title). Try again.")
                }
            }
            dragOffset = .zero
            showDetails = false
        }
    }

    func listPickerDismissed() {
        if !choseList {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                dragOffset = .zero
            }
        }
        choseList = false
        pendingMovie = nil
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
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - List picker
private extension DiscoverView {
    var listPicker: some View {
        NavigationStack {
            ZStack {
                Theme.surface.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let movie = pendingMovie {
                            HStack(spacing: 14) {
                                PosterImage(path: movie.poster_path, cornerRadius: 10, size: .small)
                                    .frame(width: 54, height: 81)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("ADD TO A LIST")
                                        .font(.caption.weight(.heavy))
                                        .tracking(2)
                                        .foregroundStyle(Theme.accentGradient)
                                    Text(movie.title)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        if movieLists.isEmpty {
                            EmptyStateView(
                                icon: "film.stack",
                                title: "No lists yet",
                                message: "Create a list on the Lists tab, then come back to add films to it."
                            )
                        } else {
                            ForEach(Array(movieLists.enumerated()), id: \.element) { index, list in
                                Button {
                                    choose(list)
                                } label: {
                                    listRow(list)
                                }
                                .buttonStyle(PressableButtonStyle(scale: 0.98))
                                .appearAnimation(delay: Double(min(index, 8)) * 0.04)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Choose a List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { showListPicker = false }
                }
            }
        }
    }

    func listRow(_ list: CDMovieList) -> some View {
        let top = list.movies.sorted { $0.rank < $1.rank }.first
        return HStack(spacing: 14) {
            PosterImage(path: top?.poster_path, cornerRadius: 8, size: .small)
                .frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name ?? "No Name")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(list.movies.count) \(list.movies.count == 1 ? "film" : "films")")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accentGradient)
        }
        .padding(12)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Lists
private extension DiscoverView {
    // TMDb ids of every film in any list; recommendations never include these
    var listedIDs: Set<Int64> {
        Set(movieLists.flatMap { list in list.movies.map { Int64($0.tmdb_id) } })
    }

    // The top two films of each list, best ranked first, to base recommendations on
    var seeds: [Int64] {
        let favourites = movieLists
            .flatMap { $0.movies.sorted { $0.rank < $1.rank }.prefix(2) }
            .sorted { $0.rank < $1.rank }
            .map { Int64($0.tmdb_id) }
            .filter { $0 > 0 }
        var seen = Set<Int64>()
        return Array(favourites.filter { seen.insert($0).inserted }.prefix(5))
    }

    func syncWithLists() {
        viewModel.update(listedIDs: listedIDs, seeds: seeds)
    }
}

// MARK: - Card

private struct DiscoverCard: View {
    let movie: Movie
    let showDetails: Bool

    var body: some View {
        PosterImage(path: movie.poster_path, cornerRadius: 28, size: .xlarge)
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(alignment: .bottom) { info }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let rating = movie.vote_average, rating > 0 {
                    MetaChip(icon: "star.fill", text: String(format: "%.1f", rating))
                }
                MetaChip(icon: "calendar", text: Theme.year(from: movie.release_date))
                if !movie.original_language.isEmpty {
                    MetaChip(icon: "globe", text: movie.original_language.uppercased())
                }
            }
            Text(movie.title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            if showDetails, !movie.overview.isEmpty {
                Text(movie.overview)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(9)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Label("Tap for details", systemImage: "hand.tap")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(20)
        .padding(.top, 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(showDetails ? 0.92 : 0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct DiscoverView_Previews: PreviewProvider {
    static var previews: some View {
        DiscoverView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
            .preferredColorScheme(.dark)
    }
}
