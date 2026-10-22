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
    @AppStorage(Personalization.aiAllowedKey) private var aiAllowed = false
    @AppStorage(Personalization.useAIKey) private var useAI = false
    @AppStorage(Personalization.aiConsentAskedKey) private var aiConsentAsked = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared

    @State private var dragOffset: CGSize = .zero
    @State private var showDetails = false
    // The film whose full info screen is open, as a temporary copy that isn't saved anywhere
    @State private var fullDetails: CDMovie? = nil
    // The film swiped right, waiting for the user to pick a list
    @State private var pendingMovie: Movie? = nil
    @State private var showListPicker = false
    @State private var choseList = false
    // Lists still waiting for the film to be placed with Compare, after the current one
    @State private var rankingQueue: [(list: CDMovieList, movie: CDMovie)] = []
    @State private var toast: String? = nil
    // Creating a new list from the list picker
    // Placing a film just added from Discover within its list, using the same head-to-head Compare
    @State private var ranking: (model: ListViewModel, movie: CDMovie)? = nil
    @State private var showGenrePicker = false
    // Genres ticked in the picker, applied when it closes with Done
    @State private var draftGenres: Set<Int> = []
    @State private var draftFilters = DiscoverFilters()
    // Streaming services in the user's country, loaded when the filters open
    @State private var services: [StreamingService] = []
    // Quick Add sends swiped-right films straight to one list, without asking which list or where they rank
    @AppStorage("discoverQuickAdd") private var quickAddOn = false
    @AppStorage("discoverQuickAddListID") private var quickAddListID = 0
    @State private var choosingQuickAddList = false

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
                // Top left, like dating apps: brings back the last skipped or "not for me" card
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.spring) {
                            viewModel.undo()
                            dragOffset = .zero
                            showDetails = false
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.body.weight(.semibold))
                    }
                    .disabled(!viewModel.canUndo)
                    .accessibilityLabel("Undo")
                    .accessibilityHint("Brings back the last card you skipped")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Section(sourceDescription) {
                            // Only offered once AI is allowed in Settings; until then it shows Classic
                            Picker("Recommendations", selection: Binding(get: { canUseAI && useAI }, set: { useAI = $0 })) {
                                Label("AI Picks", systemImage: "brain").tag(true)
                                Label("Classic (TMDb)", systemImage: "film.stack").tag(false)
                            }
                            .disabled(!canUseAI)
                        }
                        Section("Adding Films") {
                            Picker("When You Add a Film", selection: Binding(get: { quickAddList != nil }, set: setQuickAdd)) {
                                Label("Ask Each Time", systemImage: "list.bullet").tag(false)
                                Label(quickAddList.map { "Quick Add to \($0.name ?? "List")" } ?? "Quick Add…", systemImage: "bolt").tag(true)
                            }
                            if quickAddList != nil {
                                Button {
                                    choosingQuickAddList = true
                                } label: {
                                    Label("Change Quick Add List…", systemImage: "arrow.left.arrow.right")
                                }
                            }
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
            ListPickerSheet(title: pendingMovie?.title ?? "", posterPath: pendingMovie?.poster_path) { lists in
                addToSelectedLists(lists)
            }
            .environmentObject(authViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $choosingQuickAddList) {
            ListPickerSheet(title: "Films you add from Discover", posterPath: nil, singleChoice: true) { lists in
                guard let list = lists.first else { return }
                quickAddListID = Int(list.id)
                quickAddOn = true
                showToast("Quick Add to \(list.name ?? "your list") is on")
            }
            .environmentObject(authViewModel)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $fullDetails) { preview in
            // Add to Lists closes the info screen and carries on as if the card was swiped right
            MovieDetailView(movie: preview, onAddToLists: {
                fullDetails = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { swipeRight() }
            })
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
        .onChange(of: showingAIPicks) { _ in
            withAnimation(Theme.spring) { viewModel.sourceChanged() }
        }
        .onAppear(perform: syncWithLists)
        .onChange(of: listedIDs) { _ in syncWithLists() }
        .onChange(of: viewModel.filters.listIDs) { _ in syncWithLists() }
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
                    DiscoverCard(movie: movie, showDetails: index == 0 && showDetails) {
                        Haptics.tap()
                        fullDetails = PersistenceController.preview(of: movie)
                    }
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

    // The genres Automatic is choosing: learned from swipes, or the lists' top genres until there are enough
    var automaticGenreNames: [String] {
        viewModel.automaticGenres.compactMap { TasteProfile.genreNames[$0] }
    }

    var isUnder18: Bool {
        ageRange == Personalization.under18
    }

    // AI Picks can be chosen only while AI features are allowed in Settings
    var canUseAI: Bool {
        aiAllowed && !isUnder18
    }

    // Asked once, the first time Discover opens, before anything is sent to the AI
    var askForAIConsent: Binding<Bool> {
        Binding(get: { !aiConsentAsked && !aiAllowed && !isUnder18 }, set: { _ in })
    }

    var aiConsentSheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accentGradient)
            Text("Allow AI Features?")
                .font(.title2.bold())
                .foregroundColor(Theme.textPrimary)
            Text("AI Picks in Discover and Movie Night with friends send the titles in your lists, your Discover swipes, and your iPhone's country and language to a third-party AI provider. Your name and email are never sent. You can change this any time in Settings.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                aiConsentAsked = true
                aiAllowed = true
                useAI = true
            } label: {
                Text("Allow AI Features")
                    .font(.headline)
                    .foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accentGradient, in: Capsule())
            }
            Button("Not Now") {
                aiConsentAsked = true
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
        if !aiAllowed {
            return "Allow AI features in Settings to use AI Picks"
        }
        if !useAI {
            return "Recommended by TMDb from your lists"
        }
        return viewModel.aiAvailable ? "Picked by AI from your lists and swipes" : "AI picks unavailable, using TMDb for now"
    }

    // Sparkles mark AI recommendations, so they only appear while AI Picks is the chosen source
    var showingAIPicks: Bool {
        canUseAI && useAI
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
            draftFilters = viewModel.filters
            showGenrePicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showingAIPicks ? "sparkles" : viewModel.genreFilter.isEmpty ? "wand.and.stars" : "line.3.horizontal.decrease")
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
        var parts: [String] = []
        if !viewModel.filters.listNames.isEmpty { parts.append("From " + viewModel.filters.listNames.joined(separator: ", ")) }
        if !viewModel.genreFilter.isEmpty {
            parts.append(Self.genreName(viewModel.genreFilter.sorted { Self.genreName($0) < Self.genreName($1) }))
        }
        if !viewModel.filters.languages.isEmpty {
            parts.append(viewModel.filters.languages.map(DiscoverFilters.languageName).joined(separator: ", "))
        }
        if !viewModel.filters.services.isEmpty {
            parts.append("On " + viewModel.filters.services.map(\.name).joined(separator: ", "))
        }
        if viewModel.genreFilter.isEmpty && !automaticGenreNames.isEmpty {
            parts.append("Auto: " + automaticGenreNames.joined(separator: ", "))
        }
        return parts.isEmpty ? "All genres" : parts.joined(separator: " · ")
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
                VStack(alignment: .leading, spacing: 22) {
                    filterSection("BASED ON") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                            filterChip("All My Lists", selected: draftFilters.listIDs.isEmpty) {
                                draftFilters.listIDs = []
                                draftFilters.listNames = []
                            }
                            ForEach(movieLists.filter { !$0.movies.isEmpty }, id: \.id) { list in
                                filterChip(list.name ?? "List", selected: draftFilters.listIDs.contains(list.id)) {
                                    if let index = draftFilters.listIDs.firstIndex(of: list.id) {
                                        draftFilters.listIDs.remove(at: index)
                                        draftFilters.listNames.remove(at: index)
                                    } else {
                                        draftFilters.listIDs.append(list.id)
                                        draftFilters.listNames.append(list.name ?? "List")
                                    }
                                }
                            }
                        }
                        Text("Pick one or more lists to get recommendations like the films in them.")
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                    }

                    filterSection("GENRES") {
                        automaticGenresOption
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(Self.pickableGenres, id: \.self) { genre in
                                genreOption(genre)
                            }
                        }
                        Text(draftGenres.isEmpty
                             ? "Or pick genres yourself, and Discover will only show films in at least one of them."
                             : "Discover will only show films in at least one of the genres you picked.")
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                    }

                    filterSection("LANGUAGE") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(DiscoverFilters.commonLanguages, id: \.self) { code in
                                filterChip(DiscoverFilters.languageName(code), selected: draftFilters.languages.contains(code)) {
                                    if let index = draftFilters.languages.firstIndex(of: code) {
                                        draftFilters.languages.remove(at: index)
                                    } else {
                                        draftFilters.languages.append(code)
                                    }
                                }
                            }
                        }
                        Text("Only films originally made in one of these languages. None picked means any language.")
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                    }

                    filterSection("STREAMING ON") {
                        if services.isEmpty {
                            ProgressView()
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                                ForEach(services) { service in
                                    filterChip(service.name, selected: draftFilters.services.contains(service)) {
                                        if let index = draftFilters.services.firstIndex(of: service) {
                                            draftFilters.services.remove(at: index)
                                        } else {
                                            draftFilters.services.append(service)
                                        }
                                    }
                                }
                            }
                        }
                        Text("Only films you can stream on one of these, free or with your subscription, in your country.")
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .onAppear {
                guard services.isEmpty else { return }
                APIService.shared.fetchStreamingServices { result in
                    if case .success(let loaded) = result { services = loaded }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showGenrePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.success()
                        showGenrePicker = false
                        withAnimation(Theme.spring) {
                            // The new list's films have to be in place before the deck starts over
                            viewModel.update(listedIDs: listedIDs, seedPool: seedPool(for: draftFilters.listIDs))
                            viewModel.setFilters(draftFilters)
                            viewModel.setGenreFilter(draftGenres)
                        }
                    }
                    .bold()
                }
            }
        }
    }

    // Selected when no genres are picked. It names the genres Discover is choosing for the user, so it's clear
    // that Automatic still narrows things down
    var automaticGenresOption: some View {
        let isSelected = draftGenres.isEmpty
        let names = automaticGenreNames
        return Button {
            Haptics.tap()
            draftGenres = []
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(Theme.accentGradient)
                    Text("Automatic")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                }
                if names.isEmpty {
                    Text("Discover will pick genres for you once it knows your taste. Swipe a few cards, or add films to your lists.")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Text("Discover is choosing these genres for you:")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                    HStack(spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            Text(name)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.surfaceRaised, in: Capsule())
                        }
                    }
                    Text(viewModel.profile.favoriteGenres.isEmpty
                         ? "From the films you rank highest. Your swipes take over as you go."
                         : "From what you've liked and passed on in Discover. They change as you swipe.")
                        .font(.caption2)
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(cornerRadius: 16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.heavy))
                .tracking(1.2)
                .foregroundColor(Theme.textSecondary)
            content()
        }
    }

    func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(selected ? Theme.onAccent : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            circleButton(icon: quickAddList == nil ? "plus" : "bolt.fill", size: 64, style: AnyShapeStyle(Theme.accentGradient), filled: true) {
                swipeRight()
            }
            // With Quick Add on, touch and hold still lets one film go somewhere else
            .contextMenu {
                if let list = quickAddList {
                    Button {
                        swipeRight(forceAsk: true)
                    } label: {
                        Label("Choose Lists…", systemImage: "list.bullet")
                    }
                    Button {
                        setQuickAdd(false)
                    } label: {
                        Label("Stop Quick Adding to \(list.name ?? "List")", systemImage: "bolt.slash")
                    }
                }
            }
            .accessibilityLabel(quickAddList.map { "Add to \($0.name ?? "your list")" } ?? "Add to a list")
            .accessibilityHint(quickAddList == nil ? "" : "Touch and hold to choose lists")
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

    // The list Quick Add sends films to, while it's on and the list still exists
    var quickAddList: CDMovieList? {
        guard quickAddOn else { return nil }
        return movieLists.first { Int($0.id) == quickAddListID }
    }

    // Turning Quick Add on asks for its list the first time
    func setQuickAdd(_ on: Bool) {
        if !on {
            quickAddOn = false
        } else if movieLists.contains(where: { Int($0.id) == quickAddListID }) {
            quickAddOn = true
        } else {
            choosingQuickAddList = true
        }
    }

    // Flies the card off to the right and asks which list it goes in, unless Quick Add is on.
    // Cancelling brings the card back.
    func swipeRight(forceAsk: Bool = false) {
        guard let movie = viewModel.topMovie else { return }
        Haptics.select()
        pendingMovie = movie
        withAnimation(.easeIn(duration: 0.22)) {
            dragOffset = CGSize(width: 700, height: dragOffset.height)
        }
        if !forceAsk, let list = quickAddList {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                pendingMovie = nil
                quickAdd(movie, to: list)
            }
            return
        }
        // The Quick Add list was deleted, so go back to asking
        if !forceAsk && quickAddOn { quickAddOn = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showListPicker = true
        }
    }

    // Adds the film at the bottom of the Quick Add list, without the list picker or Compare
    func quickAdd(_ movie: Movie, to list: CDMovieList) {
        withAnimation(Theme.spring) {
            viewModel.add(movie, to: [list], context: context) { added in
                if let only = added.first {
                    showToast("Added to \(only.list.name ?? "your list") at #\(only.movie.rank)")
                } else {
                    showToast("Couldn't add \(movie.title). Try again.")
                }
            }
            dragOffset = .zero
            showDetails = false
        }
    }

    func addToSelectedLists(_ lists: [CDMovieList]) {
        guard let movie = pendingMovie, !lists.isEmpty else { return }
        choseList = true
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
            },
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

// MARK: - Lists
private extension DiscoverView {
    // TMDb ids of every film in any list; recommendations never include these
    var listedIDs: Set<Int64> {
        Set(movieLists.flatMap { list in list.movies.map { Int64($0.tmdb_id) } })
    }

    // Every film in every list, weighted by its rank within that list (#1 of n weighs n times the last),
    // so recommendations draw on the whole collection with favourites likelier
    var seedPool: [(id: Int64, weight: Double)] {
        seedPool(for: viewModel.filters.listIDs)
    }

    // Every film in the lists Discover is based on, weighted by rank: just the chosen list, or all of them
    func seedPool(for listIDs: [Int64]) -> [(id: Int64, weight: Double)] {
        var weights: [Int64: Double] = [:]
        let lists = listIDs.isEmpty ? Array(movieLists) : movieLists.filter { listIDs.contains($0.id) }
        for list in lists {
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
        // Automatic leans on the lists' top genres until swipes teach it more; their genres come from TMDb
        let ids = seedPool.map(\.id)
        viewModel.updateListGenres(for: ids)
        MovieInfoCache.shared.fetchMissing(ids, onBatch: { viewModel.updateListGenres(for: ids) }, completion: { viewModel.updateListGenres(for: ids) })
    }
}

// MARK: - Card

private struct DiscoverCard: View {
    let movie: Movie
    let showDetails: Bool
    // Opens the film's full info screen: TMDb score, age rating, Where to Watch, friends' takes and IMDb
    var onFullDetails: () -> Void = {}
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
                HStack(spacing: 8) {
                    TrailerButton(tmdbID: movie.id, title: movie.title, onPoster: true)
                    Button(action: onFullDetails) {
                        Label("Full Details", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Theme.posterText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.94))
                }
                .transition(.opacity)
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
