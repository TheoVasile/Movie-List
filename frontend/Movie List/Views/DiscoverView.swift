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
    @EnvironmentObject var authViewModel: AuthenticationViewModel
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var movieLists: FetchedResults<CDMovieList>
    @StateObject private var viewModel = DiscoverViewModel()
    @AppStorage(Personalization.useAIKey) private var useAI = false
    @AppStorage(Personalization.aiConsentAskedKey) private var aiConsentAsked = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared

    @State private var dragOffset: CGSize = .zero
    @State private var showDetails = false
    // The film swiped right, waiting for the user to pick a list
    @State private var pendingMovie: Movie? = nil
    @State private var showListPicker = false
    @State private var choseList = false
    // Lists ticked in the picker; the film goes into all of them
    @State private var selectedLists: [CDMovieList] = []
    // Lists still waiting for the film to be placed with Compare, after the current one
    @State private var rankingQueue: [(list: CDMovieList, movie: CDMovie)] = []
    @State private var toast: String? = nil
    // Creating a new list from the list picker
    @State private var showNewListField = false
    @State private var newListName = ""
    @State private var isCreatingList = false
    @State private var createListFailed = false
    @FocusState private var newListFocused: Bool
    // Placing a film just added from Discover within its list, using the same head-to-head Compare
    @State private var ranking: (model: ListViewModel, movie: CDMovie)? = nil
    @State private var showGenrePicker = false
    // Genres ticked in the picker, applied when it closes with Done
    @State private var draftGenres: Set<Int> = []

    private let swipeThreshold: CGFloat = 110

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                PosterBackdrop(path: viewModel.topMovie?.poster_path)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.5), value: viewModel.topMovie?.id)
                VStack(spacing: 22) {
                    tasteSummary
                        .transition(.opacity)
                    cardStack
                        .frame(maxHeight: .infinity)
                    if viewModel.topMovie != nil {
                        actionButtons
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                if let ranking {
                    Theme.scrim
                        .ignoresSafeArea()
                        .onTapGesture { endRanking() }
                        .transition(.opacity)
                        .zIndex(1)
                    rankingOverlay(model: ranking.model, movie: ranking.movie)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .overlay(alignment: .top) { toastView }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Section(sourceDescription) {
                            Picker("Recommendations", selection: $useAI) {
                                Label("AI Picks", systemImage: "brain").tag(true)
                                Label("Classic (TMDb)", systemImage: "film.stack").tag(false)
                            }
                            .disabled(isUnder18)
                        }
                        Section(profileDescription) {
                            Button {
                                withAnimation(Theme.spring) { viewModel.showSkippedAgain() }
                            } label: {
                                Label("Show Skipped Films Again", systemImage: "arrow.counterclockwise")
                            }
                            Button(role: .destructive) {
                                withAnimation(Theme.spring) { viewModel.resetProfile() }
                            } label: {
                                Label("Reset Taste Profile", systemImage: "trash")
                            }
                            .disabled(viewModel.profile.swipeCount == 0)
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
        .sheet(isPresented: $showGenrePicker) {
            genrePicker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: askForAIConsent) {
            aiConsentSheet
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
        }
        .onChange(of: useAI) { _ in
            aiConsentAsked = true
            withAnimation(Theme.spring) { viewModel.sourceChanged() }
        }
        .onChange(of: ageRange) { _ in
            withAnimation(Theme.spring) { viewModel.sourceChanged() }
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

    var favoriteGenreNames: [String] {
        viewModel.profile.favoriteGenres.compactMap { TasteProfile.genreNames[$0] }
    }

    var isUnder18: Bool {
        ageRange == Personalization.under18
    }

    // Asked once, the first time Discover opens, before anything is sent to the AI
    var askForAIConsent: Binding<Bool> {
        Binding(get: { !aiConsentAsked && !isUnder18 }, set: { _ in })
    }

    var aiConsentSheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accentGradient)
            Text("Try AI Picks?")
                .font(.title2.bold())
                .foregroundColor(Theme.textPrimary)
            Text("Discover can send the titles in your lists, your Discover swipes, and your iPhone's country and language to Claude, Anthropic's AI, to pick films for you. Your name and email are never sent. You can change this any time in Settings.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                aiConsentAsked = true
                useAI = true
            } label: {
                Text("Allow AI Picks")
                    .font(.headline)
                    .foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accentGradient, in: Capsule())
            }
            Button("Use Classic Recommendations") {
                aiConsentAsked = true
                useAI = false
            }
            .foregroundColor(Theme.accent)
        }
        .padding(24)
        .frame(maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    var sourceDescription: String {
        if isUnder18 {
            return "Recommended by TMDb from your lists"
        }
        if !useAI {
            return "Recommended by TMDb from your lists"
        }
        return viewModel.aiAvailable ? "Picked by Claude from your lists and swipes" : "AI picks unavailable, using TMDb for now"
    }

    // Sparkles mark AI recommendations, so they only appear while AI Picks is the chosen source
    var showingAIPicks: Bool {
        useAI && !isUnder18
    }

    var profileDescription: String {
        let swipes = viewModel.profile.swipeCount
        guard swipes > 0 else { return "Swipe to teach Discover your taste" }
        return "Learned from \(swipes) \(swipes == 1 ? "swipe" : "swipes")"
    }

    // Which genres Discover is showing: the ones picked by the user, or what their swipes have taught it.
    // Tapping it opens the genre picker
    var tasteSummary: some View {
        Button {
            Haptics.tap()
            draftGenres = viewModel.genreFilter
            showGenrePicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showingAIPicks ? "sparkles" : viewModel.genreFilter.isEmpty ? "heart.fill" : "line.3.horizontal.decrease")
                    .foregroundStyle(Theme.accentGradient)
                Text(genreSummary)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.textTertiary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .animation(Theme.spring, value: genreSummary)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .accessibilityLabel("Genres: \(genreSummary)")
        .accessibilityHint("Choose which genres Discover shows")
    }

    var genreSummary: String {
        if !viewModel.genreFilter.isEmpty {
            return "Only " + Self.genreName(viewModel.genreFilter.sorted { Self.genreName($0) < Self.genreName($1) })
        }
        return favoriteGenreNames.isEmpty ? "All genres" : "Tuned to \(favoriteGenreNames.joined(separator: ", "))"
    }

    static func genreName(_ ids: [Int]) -> String {
        ids.map(genreName).joined(separator: ", ")
    }

    static func genreName(_ id: Int) -> String {
        TasteProfile.genreNames[id] ?? "Other"
    }

    // Every genre TMDb uses for films, alphabetically. TV Movie is left out, since Discover only deals feature films
    static let pickableGenres = TasteProfile.genreNames.keys.filter { $0 != 10770 }.sorted { genreName($0) < genreName($1) }

    var genrePicker: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        Haptics.tap()
                        draftGenres = []
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(Theme.accentGradient)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatic")
                                    .font(.headline)
                                    .foregroundColor(Theme.textPrimary)
                                Text(favoriteGenreNames.isEmpty ? "Learns your taste from your lists and swipes" : "Tuned to \(favoriteGenreNames.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            if draftGenres.isEmpty {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(Theme.accent)
                            }
                        }
                        .padding(14)
                        .cardStyle(cornerRadius: 16)
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.97))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("OR PICK GENRES")
                            .font(.caption2.weight(.heavy))
                            .tracking(1.2)
                            .foregroundColor(Theme.textSecondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(Self.pickableGenres, id: \.self) { genre in
                                genreOption(genre)
                            }
                        }
                        Text("Discover will only show films in at least one of the genres you pick.")
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Genres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showGenrePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.success()
                        showGenrePicker = false
                        withAnimation(Theme.spring) { viewModel.setGenreFilter(draftGenres) }
                    }
                    .bold()
                }
            }
        }
    }

    func genreOption(_ genre: Int) -> some View {
        let isSelected = draftGenres.contains(genre)
        return Button {
            Haptics.tap()
            if isSelected { draftGenres.remove(genre) } else { draftGenres.insert(genre) }
        } label: {
            Text(Self.genreName(genre))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(isSelected ? Theme.onAccent : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.clear : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            stamp("NOT NOW", color: Theme.accentSecondary, rotation: 14)
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
        HStack(spacing: 22) {
            circleButton(icon: "hand.thumbsdown", size: 48, style: AnyShapeStyle(Theme.textSecondary), filled: false) {
                notForMe()
            }
            .accessibilityLabel("Not for me")
            circleButton(icon: "xmark", size: 64, style: AnyShapeStyle(Theme.accentSecondary), filled: false) {
                swipeLeft()
            }
            .accessibilityLabel("Skip")
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
                .foregroundStyle(filled ? AnyShapeStyle(Theme.onAccent) : style)
                .frame(width: size, height: size)
                .background(filled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: Theme.shadow.opacity(0.4), radius: 12, y: 6)
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

    // Unlike a skip, this tells Discover the user doesn't want films like this one.
    // The card drops away instead of sliding left, so the two feel different
    func notForMe() {
        guard let movie = viewModel.topMovie else { return }
        Haptics.select()
        withAnimation(.easeIn(duration: 0.22)) {
            dragOffset = CGSize(width: 0, height: 900)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(Theme.spring) {
                viewModel.dislike(movie)
                dragOffset = .zero
                showDetails = false
            }
            showToast("Got it, fewer films like this")
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

    func toggle(_ list: CDMovieList) {
        Haptics.tap()
        if let index = selectedLists.firstIndex(of: list) {
            selectedLists.remove(at: index)
        } else {
            selectedLists.append(list)
        }
    }

    func addToSelectedLists() {
        guard let movie = pendingMovie, !selectedLists.isEmpty else { return }
        let lists = selectedLists
        Haptics.success()
        choseList = true
        showListPicker = false
        withAnimation(Theme.spring) {
            viewModel.add(movie, to: lists, context: context) { added in
                guard !added.isEmpty else {
                    showToast("Couldn't add \(movie.title). Try again.")
                    return
                }
                if added.count < lists.count {
                    showToast("Added to \(added.count) of \(lists.count) lists. Try the rest again.")
                } else if added.count > 1 {
                    showToast("Added to \(added.count) lists")
                }
                // New films land at the bottom, so ask where it belongs in each list that has other films
                rankingQueue = added.filter { $0.list.movies.count > 1 }
                if let first = rankingQueue.first {
                    rankingQueue.removeFirst()
                    startRanking(first.movie, in: first.list)
                } else if added.count == 1, let only = added.first {
                    showToast("Added to \(only.list.name ?? "your list") at #\(only.movie.rank)")
                }
            }
            dragOffset = .zero
            showDetails = false
        }
    }

    func startRanking(_ movie: CDMovie, in list: CDMovieList) {
        let model = ListViewModel(movieList: list, context: context)
        // Give the list picker time to finish closing before Compare appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(Theme.spring) { ranking = (model, movie) }
        }
    }

    // Moves on to placing the film in the next chosen list, if there is one
    func endRanking() {
        withAnimation(Theme.spring) { ranking = nil }
        guard let next = rankingQueue.first else { return }
        rankingQueue.removeFirst()
        startRanking(next.movie, in: next.list)
    }

    func rankingOverlay(model: ListViewModel, movie: CDMovie) -> some View {
        let listName = model.movieList.name ?? "your list"
        return CompareMovieView(
            movies: Binding(get: { model.movies }, set: { model.movies = $0 }),
            movie: .constant(movie),
            prompt: "Where does \(movie.title ?? "it") rank in \(listName)?",
            cancelTitle: "Skip — keep it at the bottom",
            onCancel: {
                endRanking()
                showToast("Added to \(listName) at #\(movie.rank)")
            }
        ) { rankedMovie, rank in
            model.updateMovieRanking(updatedMovie: rankedMovie, newRank: rank)
            endRanking()
            showToast("Ranked #\(rank) in \(listName)")
        }
    }

    func listPickerDismissed() {
        if !choseList {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                dragOffset = .zero
            }
        }
        choseList = false
        selectedLists = []
        pendingMovie = nil
        showNewListField = false
        newListName = ""
        createListFailed = false
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
                                    Text("ADD TO LISTS")
                                        .font(.caption.weight(.heavy))
                                        .tracking(2)
                                        .foregroundStyle(Theme.accentGradient)
                                    Text(movie.title)
                                        .font(.headline)
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        newListSection
                        ForEach(Array(listsByLastAdded.enumerated()), id: \.element) { index, list in
                            Button {
                                toggle(list)
                            } label: {
                                listRow(list)
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.98))
                            .appearAnimation(delay: Double(min(index, 8)) * 0.04)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 80)
                }
                if !movieLists.isEmpty {
                    VStack {
                        Spacer()
                        Button {
                            addToSelectedLists()
                        } label: {
                            Text(selectedLists.isEmpty ? "Choose Lists" : selectedLists.count == 1 ? "Add to \(selectedLists[0].name ?? "List")" : "Add to \(selectedLists.count) Lists")
                                .lineLimit(1)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(selectedLists.isEmpty)
                        .opacity(selectedLists.isEmpty ? 0.5 : 1)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle("Choose Lists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { showListPicker = false }
                }
            }
        }
    }

    // A "New List" button that opens into a name field. With no lists yet, the field shows straight away
    @ViewBuilder
    var newListSection: some View {
        if showNewListField || movieLists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "list.star")
                        .foregroundStyle(Theme.accentGradient)
                    TextField("New list name", text: $newListName)
                        .focused($newListFocused)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit(createListAndAdd)
                        .disabled(isCreatingList)
                }
                .padding(14)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if createListFailed {
                    Label("Couldn't create the list. Try again.", systemImage: "exclamationmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Theme.accentSecondary)
                        .transition(.opacity)
                }
                Button(action: createListAndAdd) {
                    HStack(spacing: 8) {
                        if isCreatingList {
                            ProgressView().tint(Theme.onAccent)
                        }
                        Text(isCreatingList ? "Creating…" : "Create List")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(trimmedNewListName.isEmpty || isCreatingList)
                .opacity(trimmedNewListName.isEmpty ? 0.5 : 1)
            }
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .onAppear { newListFocused = true }
        } else {
            Button {
                Haptics.tap()
                withAnimation(Theme.spring) { showNewListField = true }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.accentGradient)
                        .frame(width: 40, height: 60)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("New List")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                }
                .padding(12)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98))
        }
    }

    var trimmedNewListName: String {
        newListName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The film can only be added once the backend has given the list its id, so create the list first
    func createListAndAdd() {
        let name = trimmedNewListName
        guard !name.isEmpty, !isCreatingList, let userID = authViewModel.user?.uid else { return }
        isCreatingList = true
        withAnimation { createListFailed = false }
        APIService.shared.createList(userID: userID, name: name, overview: "", isRanked: true) { result in
            isCreatingList = false
            switch result {
            case .success(let serverList):
                let list = CDMovieList(id: serverList.id, name: serverList.name, overview: serverList.overview, context: context)
                do {
                    try context.save()
                } catch {
                    print("Error saving new list:", error)
                }
                // The new list is ticked along with any others, then Add puts the film in all of them
                withAnimation(Theme.spring) {
                    selectedLists.append(list)
                    showNewListField = false
                    newListName = ""
                }
                Haptics.success()
            case .failure(let error):
                print("Error creating list:", error.localizedDescription)
                Haptics.tap()
                withAnimation { createListFailed = true }
            }
        }
    }

    // The list a film was most recently added to comes first, since it's the likeliest pick again
    var listsByLastAdded: [CDMovieList] {
        movieLists.sorted { ($0.date_modified ?? .distantPast) > ($1.date_modified ?? .distantPast) }
    }

    func listRow(_ list: CDMovieList) -> some View {
        let top = list.movies.sorted { $0.rank < $1.rank }.first
        let isSelected = selectedLists.contains(list)
        return HStack(spacing: 14) {
            PosterImage(path: top?.poster_path, cornerRadius: 8, size: .small)
                .frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name ?? "No Name")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text("\(list.movies.count) \(list.movies.count == 1 ? "film" : "films")")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
        }
        .padding(12)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Lists
private extension DiscoverView {
    // TMDb ids of every film in any list; recommendations never include these
    var listedIDs: Set<Int64> {
        Set(movieLists.flatMap { list in list.movies.map { Int64($0.tmdb_id) } })
    }

    // Every film in every list, weighted by its rank within that list (#1 of n weighs n times the last),
    // so recommendations draw on the whole collection with favourites likelier
    var seedPool: [(id: Int64, weight: Double)] {
        var weights: [Int64: Double] = [:]
        for list in movieLists {
            let ranked = list.movies.sorted { $0.rank < $1.rank }
            for (index, movie) in ranked.enumerated() where movie.tmdb_id > 0 {
                let weight = Double(ranked.count - index) / Double(ranked.count)
                // A film in several lists counts with its best placing
                weights[Int64(movie.tmdb_id)] = max(weights[Int64(movie.tmdb_id)] ?? 0, weight)
            }
        }
        return weights.map { (id: $0.key, weight: $0.value) }
    }

    func syncWithLists() {
        viewModel.update(listedIDs: listedIDs, seedPool: seedPool)
    }
}

// MARK: - Card

private struct DiscoverCard: View {
    let movie: Movie
    let showDetails: Bool
    // Fetched the first time the card's details are opened
    @State private var providers: WatchProviders? = nil

    var body: some View {
        PosterImage(path: movie.poster_path, cornerRadius: 28, size: .xlarge)
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(alignment: .bottom) { info }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Theme.shadow.opacity(0.55), radius: 24, y: 12)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let rating = movie.vote_average, rating > 0 {
                    MetaChip(icon: "star.fill", text: String(format: "%.1f", rating), onPoster: true)
                }
                MetaChip(icon: "calendar", text: Theme.year(from: movie.release_date), onPoster: true)
                if !movie.original_language.isEmpty {
                    MetaChip(icon: "globe", text: movie.original_language.uppercased(), onPoster: true)
                }
            }
            Text(movie.title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.posterText)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            if let reason = movie.reason, !reason.isEmpty {
                Label(reason, systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Theme.posterText.opacity(0.9))
                    .lineLimit(showDetails ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showDetails, !movie.overview.isEmpty {
                Text(movie.overview)
                    .font(.subheadline)
                    .foregroundColor(Theme.posterText.opacity(0.85))
                    .lineLimit(9)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showDetails {
                streamingRow
                    .onAppear {
                        WatchProvidersStore.shared.load(tmdbID: movie.id) { loaded in
                            withAnimation(Theme.spring) { providers = loaded }
                        }
                    }
            } else {
                Label("Tap for details", systemImage: "hand.tap")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.posterText.opacity(0.62))
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

    // Streaming and free services only, since that's what decides "can I watch this tonight?"
    @ViewBuilder
    private var streamingRow: some View {
        if let providers {
            let services = providers.stream + providers.free
            if services.isEmpty {
                Label("Not streaming in \(Locale.current.localizedString(forRegionCode: providers.region) ?? providers.region)", systemImage: "tv.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.posterText.opacity(0.62))
            } else {
                HStack(spacing: 8) {
                    Text("Streaming on")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.posterText.opacity(0.75))
                    ForEach(services.prefix(5)) { provider in
                        ProviderLogo(provider: provider, size: 28)
                    }
                }
                .transition(.opacity)
            }
        } else {
            // Holds the row's place while loading, and gives onAppear something to fire on
            Color.clear.frame(height: 28)
        }
    }
}

struct DiscoverView_Previews: PreviewProvider {
    static var previews: some View {
        DiscoverView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
            .environmentObject(AuthenticationViewModel())
            .preferredColorScheme(.dark)
    }
}
