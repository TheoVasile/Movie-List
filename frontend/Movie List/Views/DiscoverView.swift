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
    @AppStorage(Personalization.birthdayKey) private var birthday = ""

    @State private var dragOffset: CGSize = .zero
    @State private var showDetails = false
    // The film whose full info screen is open, as a temporary copy that isn't saved anywhere
    @State private var fullDetails: CDMovie? = nil
    // The film being added, while the user picks its lists
    @State private var adding: Movie? = nil
    // From picking lists until the film is in them and ranked
    @State private var isAdding = false
    // While a card is flying away, so a second tap or drag can't act on it again
    @State private var isSwiping = false
    @State private var toast: String? = nil
    @State private var showGenrePicker = false
    // Genres ticked in the picker, applied when it closes with Done
    @State private var draftGenres: Set<Int> = []
    @State private var draftFilters = DiscoverFilters()
    @State private var draftKind = DiscoverKind.all
    // Streaming services in the user's country, loaded when the filters open
    @State private var services: [StreamingService] = []
    @State private var showReactions = false
    @State private var confirmReset = false
    // What swiping does, shown once: earlier builds' swipes did something else
    @AppStorage(DiscoverReactions.gesturesSeenKey) private var gesturesSeen = false
    @State private var showIntro = false
    @ObservedObject private var social = SocialStore.shared

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
            }
            .overlay(alignment: .top) { toastView }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    undoButton
                }
                // ••• and + in one item, so they never collapse into an overflow menu, with + in the corner
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        optionsMenu
                        addButton
                    }
                    .fixedSize()
                }
            }
        }
        // The same list picker and Compare as adding anywhere else, over the whole screen so nothing else can be
        // tapped meanwhile
        .addToListFlow(movie: $adding, source: .discover, isBusy: $isAdding) { movie, added in
            viewModel.didAdd(movie, to: added)
        }
        // The picker closed without choosing any lists
        .onChange(of: adding?.id) { id in
            if id == nil && !isAdding { viewModel.finishAdding() }
        }
        // Added and ranked, or it couldn't be added
        .onChange(of: isAdding) { busy in
            guard !busy else { return }
            withAnimation(Theme.spring) {
                viewModel.finishAdding()
                showDetails = false
            }
        }
        .sheet(item: $fullDetails) { preview in
            // Add to Lists closes the info screen and asks which lists
            MovieDetailView(movie: preview, onAddToLists: {
                fullDetails = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { addTopMovie() }
            })
        }
        .sheet(isPresented: $showIntro, onDismiss: { gesturesSeen = true }) {
            introSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Reset Taste Profile?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Taste Profile", role: .destructive) {
                withAnimation(Theme.spring) { viewModel.resetProfile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every film in Liked & Not for Me and what Discover has learned from them. Your lists aren't changed.")
        }
        .sheet(isPresented: $showReactions) {
            NavigationStack {
                DiscoverReactionsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showReactions = false }
                        }
                    }
            }
            .environmentObject(authViewModel)
            .environment(\.managedObjectContext, context)
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
        .onAppear {
            syncWithLists()
            showIntroIfNeeded()
            viewModel.logImpressionIfNeeded()
            // Sends any reactions still waiting and brings in ones kept with the account; never holds Discover up
            DiscoverReactionSync.shared.sync()
        }
        // The intro waits for the AI question to be answered first
        .onChange(of: aiConsentAsked) { _ in showIntroIfNeeded() }
        .onChange(of: aiAllowed) { _ in showIntroIfNeeded() }
        .onChange(of: isPastGate) { _ in showIntroIfNeeded() }
        .onChange(of: viewModel.notice) { notice in
            guard let notice else { return }
            showToast(notice)
            viewModel.notice = nil
        }
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
                    cardActions(index: index, card(movie, index: index))
                        .zIndex(Double(3 - index))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    func card(_ movie: Movie, index: Int) -> some View {
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
                toggleDetails()
            }
    }

    func toggleDetails() {
        guard !isBlocked else { return }
        Haptics.tap()
        withAnimation(Theme.spring) { showDetails.toggle() }
    }

    // Everything the top card does, for VoiceOver and Switch Control. The cards behind it can't be reached
    func cardActions<Card: View>(index: Int, _ card: Card) -> some View {
        card
            .accessibilityElement(children: .combine)
            .accessibilityHidden(index != 0)
            .accessibilityAction(named: "Like") { if index == 0 { rate(.liked) } }
            .accessibilityAction(named: "Not for Me") { if index == 0 { rate(.disliked) } }
            .accessibilityAction(named: "Add to a List") { if index == 0 { addTopMovie() } }
            .accessibilityAction(named: showDetails ? "Hide Details" : "Show Details") { if index == 0 { toggleDetails() } }
    }

    var favoriteGenreNames: [String] {
        viewModel.profile.favoriteGenres.compactMap { TasteProfile.genreNames[$0] }
    }

    // The genres Automatic is choosing: learned from swipes, or the lists' top genres until there are enough
    var automaticGenreNames: [String] {
        viewModel.automaticGenres.compactMap { TasteProfile.genreNames[$0] }
    }

    var isUnder18: Bool {
        Personalization.ageRange(birthday: birthday, legacy: ageRange) == Personalization.under18
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
                .accessibilityHidden(true)
            Text("Allow AI Features?")
                .font(.title2.bold())
                .foregroundColor(Theme.textPrimary)
            Text("AI Picks in Discover, Smart Placement and Movie Night with friends send titles in your lists to a third-party AI provider. AI Picks and Smart Placement also send films you liked or marked Not for Me in Discover, and AI Picks and Movie Night your iPhone's country and language. Your name and email are never sent. You can change this any time in Settings.")
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

    // The account is known, and has nothing to do first, like agreeing to new terms (see ContentView's gate)
    var isPastGate: Bool {
        guard let profile = social.profile else { return false }
        return !profile.needsTermsAcceptance && profile.handle != nil
    }

    // Shown once the AI question, if any, is out of the way. Waits a moment so it doesn't try to open while that
    // sheet is still closing
    func showIntroIfNeeded() {
        guard !gesturesSeen, isPastGate, !askForAIConsent.wrappedValue else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !gesturesSeen, isPastGate, !askForAIConsent.wrappedValue, !isBlocked else { return }
            showIntro = true
        }
    }

    var introSheet: some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("How Discover Works")
                        .font(.title2.bold())
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                    introRow("heart.fill", "Swipe Right to Like", "Discover recommends more films like it.")
                    introRow("hand.thumbsdown.fill", "Swipe Left for Not for Me", "Discover shows fewer films like it.")
                    introRow("plus", "Tap + to Add to a List", "Choose where it goes. Adding doesn't rate the film.")
                    Text("See what you've rated any time in ••• under Liked & Not for Me.")
                        .font(.caption)
                        .foregroundColor(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
            }
            Button("Got It") {
                Haptics.tap()
                showIntro = false
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    func introRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
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
        guard viewModel.aiAvailable else { return "AI picks unavailable, using TMDb for now" }
        switch viewModel.kind {
        case .movie: return "Picked by AI from your lists and swipes"
        case .all: return "Films picked by AI, TV shows by TMDb"
        case .tv: return "AI Picks are films only, so TV shows come from TMDb"
        }
    }

    // Sparkles mark AI recommendations, so they only appear while AI Picks is the chosen source
    var showingAIPicks: Bool {
        canUseAI && useAI
    }

    // Switches between AI Picks and Classic. Until AI is allowed, choosing AI Picks asks for that first
    func setAIPicks(_ on: Bool) {
        guard on != showingAIPicks else { return }
        Haptics.tap()
        guard canUseAI else {
            if on { aiConsentAsked = false }
            return
        }
        useAI = on
        showToast(useAI ? "AI Picks on" : "Classic recommendations from TMDb")
    }

    // Everything else Discover offers, in one menu: where recommendations come from, and what it has learned
    var optionsMenu: some View {
        Menu {
            // Under-18s only ever get Classic, so the choice isn't shown to them
            if !isUnder18 {
                Section("Recommendations") {
                    Picker("Recommendations", selection: Binding(get: { showingAIPicks }, set: setAIPicks)) {
                        Label("AI Picks", systemImage: "sparkles").tag(true)
                        Label("Classic", systemImage: "film").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            }
            Section(profileDescription) {
                Button {
                    showReactions = true
                } label: {
                    Label("Liked & Not for Me", systemImage: "heart.text.square")
                }
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Reset Taste Profile", systemImage: "trash")
                }
                .disabled(!viewModel.hasLearned)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(isBlocked)
        .accessibilityLabel("Discover Options")
        .accessibilityHint(sourceDescription)
    }

    // Counts films liked and marked Not for Me. Adding a film to a list teaches Discover nothing by itself
    var profileDescription: String {
        let films = viewModel.profile.swipeCount
        guard films > 0 else { return "Like films or mark them Not for Me to teach Discover your taste" }
        return "Learned from \(films) \(films == 1 ? "film" : "films")"
    }

    // Which genres Discover is showing: the ones picked by the user, or what their swipes have taught it.
    // Tapping it opens the genre picker
    var tasteSummary: some View {
        Button {
            openFilters()
        } label: {
            HStack(spacing: 8) {
                // Sparkles only while the AI is actually picking, not after falling back to TMDb
                Image(systemName: showingAIPicks && viewModel.usesAI ? "sparkles" : viewModel.genreFilter.isEmpty ? "wand.and.stars" : "line.3.horizontal.decrease")
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
        .disabled(isBlocked)
        .accessibilityLabel("Genres: \(genreSummary)")
        .accessibilityHint("Choose which genres Discover shows")
    }

    func openFilters() {
        Haptics.tap()
        draftGenres = viewModel.genreFilter
        draftFilters = viewModel.filters
        draftKind = viewModel.kind
        showGenrePicker = true
    }

    var genreSummary: String {
        var parts: [String] = []
        if viewModel.kind != .all { parts.append(viewModel.kind.title) }
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
                    filterSection("SHOW") {
                        Picker("Show", selection: $draftKind) {
                            ForEach(DiscoverKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    filterSection("BASED ON") {
                        FlowLayout(spacing: 8) {
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
                        FlowLayout(spacing: 8) {
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
                        FlowLayout(spacing: 8) {
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
                            FlowLayout(spacing: 8) {
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
                            viewModel.setKind(draftKind)
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
                         : "From what you've liked and disliked in Discover. They change as you swipe.")
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
            // Always full size: the tag grows to fit its text, and the tags wrap onto new rows
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundColor(selected ? Theme.onAccent : Theme.textPrimary)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
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
                .foregroundColor(isSelected ? Theme.onAccent : Theme.textPrimary)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
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

    // Fade in as the card is dragged, so it's clear which way likes the film and which way is Not for Me
    var swipeStamps: some View {
        ZStack {
            stamp("LIKE", icon: "heart.fill", color: Theme.accent, rotation: -14)
                .opacity(Double(max(dragOffset.width, 0) / swipeThreshold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            stamp("NOT FOR ME", icon: "hand.thumbsdown.fill", color: Theme.accentSecondary, rotation: 14)
                .opacity(Double(max(-dragOffset.width, 0) / swipeThreshold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(28)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    func stamp(_ text: String, icon: String, color: Color, rotation: Double) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 30, weight: .black, design: .rounded))
            .tracking(2)
            .lineLimit(1)
            // Long text shrinks rather than running off the card
            .minimumScaleFactor(0.4)
            .foregroundColor(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 4))
            .frame(maxWidth: 230, alignment: .leading)
            .rotationEffect(.degrees(rotation))
    }

    var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isBlocked else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isSwiping else { return }
                // A quick flick counts even if the card hasn't travelled far
                let projected = value.predictedEndTranslation.width
                if !isBlocked && (value.translation.width > swipeThreshold || projected > swipeThreshold * 3) {
                    rate(.liked)
                } else if !isBlocked && (value.translation.width < -swipeThreshold || projected < -swipeThreshold * 3) {
                    rate(.disliked)
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    // While a card is flying away, being added, or coming back out of its lists, nothing else can be done to the deck
    var isBlocked: Bool {
        isSwiping || isAdding || adding != nil || viewModel.isUndoing
    }

    // What swiping does, as buttons, so nothing is gesture-only. Add and Undo are in the navigation bar
    var actionButtons: some View {
        HStack(alignment: .top, spacing: 48) {
            circleButton(icon: "hand.thumbsdown.fill", size: 64, style: AnyShapeStyle(Theme.accentSecondary), caption: "Not for Me") {
                rate(.disliked)
            }
            .accessibilityLabel("Not for Me")
            .accessibilityHint("Same as swiping left. Shows fewer films like this")
            circleButton(icon: "heart.fill", size: 64, style: AnyShapeStyle(Theme.accentGradient), caption: "Like") {
                rate(.liked)
            }
            .accessibilityLabel("Like")
            .accessibilityHint("Same as swiping right. Shows more films like this")
        }
        // Nothing to act on while the first batch loads
        .disabled(isBlocked || viewModel.topMovie == nil)
    }

    // Brings back the last card liked, marked Not for Me or added. An added film is taken back out of its lists, with
    // a spinner while that's done
    var undoButton: some View {
        Button {
            Haptics.tap()
            withAnimation(Theme.spring) {
                viewModel.undo { removed, failed in
                    if !failed.isEmpty {
                        showToast("Couldn't take it out of \(failed.joined(separator: ", ")). Try again.")
                    } else if !removed.isEmpty {
                        showToast("Taken back out of \(removed.joined(separator: ", "))")
                    }
                }
                dragOffset = .zero
                showDetails = false
            }
        } label: {
            if viewModel.isUndoing {
                ProgressView()
                    .tint(Theme.accent)
            } else {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        .disabled(!viewModel.canUndo || isBlocked)
        .accessibilityLabel(viewModel.isUndoing ? "Undoing" : "Undo")
        .accessibilityHint("Brings back the last card you liked, marked Not for Me or added. An added film is taken back out of its lists")
    }

    // Always asks which lists, the one added to most recently first
    var addButton: some View {
        Button {
            Haptics.tap()
            addTopMovie()
        } label: {
            Image(systemName: "plus")
        }
        .disabled(isBlocked || viewModel.topMovie == nil)
        .accessibilityLabel("Add to a List")
        .accessibilityHint("Choose lists for this film. Adding doesn't rate it")
    }

    func circleButton(icon: String, size: CGFloat, style: AnyShapeStyle, caption: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.36, weight: .heavy))
                    .foregroundStyle(style)
                    .frame(width: size, height: size)
                    .background(Theme.surface)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                    .shadow(color: Theme.shadow.opacity(0.4), radius: 12, y: 6)
                if let caption {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 84)
                }
            }
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
            VStack(spacing: 0) {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: "You're all caught up",
                    message: "You've seen every recommendation for now. Other genres, languages or services may have more.",
                    actionTitle: "Change Filters"
                ) {
                    openFilters()
                }
                Button("Refresh") {
                    Haptics.tap()
                    withAnimation(Theme.spring) { viewModel.sourceChanged() }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
            }
        } else {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Finding films for you…")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Swipe actions
private extension DiscoverView {
    // Flies the top card away: off to the right for Like, to the left for Not for Me
    func rate(_ reaction: DiscoverReaction) {
        guard !isBlocked, let movie = viewModel.topMovie else { return }
        isSwiping = true
        if reaction == .liked { Haptics.success() } else { Haptics.tap() }
        withAnimation(.easeIn(duration: 0.22)) {
            dragOffset = CGSize(width: reaction == .liked ? 700 : -700, height: dragOffset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(Theme.spring) {
                // Gone already if it was rated or added elsewhere meanwhile
                if viewModel.topMovie?.id == movie.id { viewModel.rate(movie, reaction) }
                dragOffset = .zero
                showDetails = false
            }
            isSwiping = false
        }
    }

    // Asks which lists the top card goes in. It stays until it's been added and ranked, then the next card comes up
    func addTopMovie() {
        guard !isBlocked, let movie = viewModel.topMovie else { return }
        let alreadyIn = movieLists.filter { list in list.movies.contains { Int64($0.tmdb_id) == movie.id } }
        viewModel.startAdding(movie, alreadyIn: Set(alreadyIn.map(\.id)))
        adding = movie
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

    // The films recommendations are based on, weighted by how much each says about the user's taste
    var seedPool: [(id: Int64, weight: Double)] {
        seedPool(for: viewModel.filters.listIDs)
    }

    // The films in the lists Discover is based on (just the chosen ones, or all of them). In a ranked list each
    // weighs exp(-rank/10), so the top few count most and the long tail still gets a turn, and half as much again
    // once watched. An unranked list, like a watchlist, says little about taste: only its watched films count,
    // and only a little
    func seedPool(for listIDs: [Int64]) -> [(id: Int64, weight: Double)] {
        var weights: [Int64: Double] = [:]
        let lists = listIDs.isEmpty ? Array(movieLists) : movieLists.filter { listIDs.contains($0.id) }
        for list in lists {
            let isRanked = ListRanking.isRanked(list.id)
            let ranked = list.movies.sorted { $0.rank < $1.rank }
            for (index, movie) in ranked.enumerated() where movie.tmdb_id != 0 {
                let weight: Double
                if isRanked {
                    weight = exp(-Double(index) / 10) * (movie.watched ? 1.5 : 1)
                } else if movie.watched {
                    weight = 0.1
                } else {
                    continue
                }
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
    // How long it runs, like "2h 14m", loaded with the details
    @State private var length: String? = nil

    var body: some View {
        // Every card is as wide as the screen allows and as tall as the space left, whatever the poster's
        // shape, so cards never change size from one film to the next
        PosterImage(path: movie.poster_path, cornerRadius: 28, size: .xlarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { info }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Theme.shadow.opacity(0.55), radius: 24, y: 12)
    }

    // A film a friend recommended, with who it was
    private var friendBadge: some View {
        let handle = movie.recommended_by?.handle
        return MetaChip(icon: "person.fill", text: handle.map { "Recommended by @\($0)" } ?? "Recommended by a friend", onPoster: true)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Wraps onto a second row rather than spilling past the card's edges
            FlowLayout(spacing: 6) {
                if movie.isTV {
                    MetaChip(icon: "tv", text: "TV Series", onPoster: true)
                }
                if let rating = movie.vote_average, rating > 0 {
                    MetaChip(icon: "star.fill", text: String(format: "%.1f", rating), onPoster: true)
                }
                MetaChip(icon: "calendar", text: Theme.year(from: movie.release_date), onPoster: true)
                if showDetails, let length {
                    MetaChip(icon: "clock", text: length, onPoster: true)
                        .accessibilityLabel(movie.isTV ? "Episodes run \(length)" : "Runs \(length)")
                        .transition(.opacity)
                }
                if !movie.original_language.isEmpty {
                    MetaChip(icon: "globe", text: movie.original_language.uppercased(), onPoster: true)
                }
            }
            Text(movie.title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.posterText)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            if movie.source == "friend" {
                friendBadge
            }
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
                        let tmdbID = movie.id
                        length = MovieInfoCache.shared.info(for: tmdbID)?.length
                        MovieInfoCache.shared.fetchMissing([tmdbID], onBatch: {}, completion: {
                            withAnimation(Theme.spring) { length = MovieInfoCache.shared.info(for: tmdbID)?.length }
                        })
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
