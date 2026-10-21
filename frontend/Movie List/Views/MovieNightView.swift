//
//  MovieNightView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import SwiftUI
import CoreData

/// Films the user and the people they're watching with would all enjoy, each saying why it suits the group,
/// that can be added straight to the user's lists. AI Picks come from Claude reading everyone's lists, and are
/// only offered when everyone allows AI; Classic picks come from TMDb's recommendations for everyone's
/// favourites, plus films on several people's watchlists. Either can be narrowed by genre, language and
/// streaming service
struct MovieNightView: View {
    // Everyone coming besides the user
    let people: [UserSummary]
    // A saved group, when it's for one
    var groupID: Int64? = nil
    var groupName: String? = nil
    // Whether everyone, the user included, allows AI features, which AI Picks need
    let canUseAI: Bool

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authViewModel: AuthenticationViewModel

    @State private var usesAI: Bool
    @State private var filters = MovieNightFilters()
    @State private var showFilters = false
    @State private var picks: [Movie] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    // The film waiting for the user to choose lists, and the films already added
    @State private var adding: Movie? = nil
    @State private var added: Set<Int64> = []
    // Groups only: the vote that's open or just closed, and films being picked for a new one
    @State private var poll: GroupPoll? = nil
    @State private var choosingVote = false
    @State private var chosenForVote: [Int64] = []
    @State private var pollLength = PollLength.threeHours
    @State private var sendingVote = false
    @State private var voteFailed = false

    private var pollIsOpen: Bool { poll.map { !$0.closed } ?? false }

    init(people: [UserSummary], groupID: Int64? = nil, groupName: String? = nil, canUseAI: Bool) {
        self.people = people
        self.groupID = groupID
        self.groupName = groupName
        self.canUseAI = canUseAI
        _usesAI = State(initialValue: canUseAI)
    }

    // "@sam", "@sam and @ana", "@sam, @ana and @lee"
    private var names: String {
        let all = people.map { "@\($0.handle)" }
        guard all.count > 1 else { return all.first ?? "" }
        return all.dropLast().joined(separator: ", ") + " and " + (all.last ?? "")
    }

    private var title: String {
        groupName ?? "Movie Night with \(names)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourcePicker
                ZStack {
                    Theme.background.ignoresSafeArea()
                    if isLoading && poll == nil {
                        VStack(spacing: 14) {
                            ProgressView()
                                .tint(Theme.accent)
                            Text(people.count > 1 ? "Finding films you'll all enjoy…" : "Finding films you'll both enjoy…")
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        }
                    } else if let errorMessage, poll == nil {
                        EmptyStateView(icon: "ticket", title: "Couldn't plan a movie night", message: errorMessage,
                                       actionTitle: "Try Again", action: load)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                if let groupID, let binding = Binding($poll) {
                                    PollCard(groupID: groupID, poll: binding, onAddWinner: { adding = $0 }) {
                                        withAnimation(Theme.spring) { poll = nil }
                                        if picks.isEmpty { load() }
                                    }
                                    .transition(.opacity)
                                }
                                picksSection
                            }
                            .padding(16)
                        }
                        .safeAreaInset(edge: .bottom) {
                            if choosingVote { sendVoteBar }
                        }
                    }
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filters")
                    Button {
                        load()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("New Picks")
                }
            }
            .sheet(item: $adding) { movie in
                ListPickerSheet(title: movie.title, posterPath: movie.poster_path) { lists in
                    add(movie, to: lists)
                }
                .environmentObject(authViewModel)
                .environment(\.managedObjectContext, context)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFilters) {
                MovieNightFiltersSheet(filters: filters) { chosen in
                    filters = chosen
                    load()
                }
                .presentationDetents([.large])
            }
        }
        .onAppear {
            guard picks.isEmpty else { return }
            guard let groupID else { return load() }
            // A group with a vote going on opens on the vote, without spending a request on new picks
            APIService.shared.fetchPoll(groupID: groupID) { result in
                if case .success(let current) = result { poll = current }
                if !pollIsOpen { load() } else { isLoading = false }
            }
        }
        .alert("Couldn't send the vote", isPresented: $voteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    @ViewBuilder
    private var picksSection: some View {
        if isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding more films…")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else if let errorMessage {
            Text(errorMessage)
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
        } else if picks.isEmpty {
            if pollIsOpen {
                Button("See More Picks", action: load)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentGradient)
                    .frame(maxWidth: .infinity)
            }
        } else {
            Text(usesAI
                 ? "Picked by Claude from your lists and \(names)'s. None of these are in anyone's lists yet."
                 : "Recommended by TMDb from your favourites and \(names)'s, plus anything on more than one watchlist.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
            if groupID != nil {
                startVoteButton
            }
            ForEach(Array(picks.enumerated()), id: \.element.id) { index, movie in
                pickRow(movie)
                    .appearAnimation(delay: Double(min(index, 8)) * 0.05)
            }
        }
    }

    // Groups only: picks 2 to 5 of these films for everyone to vote on
    private var startVoteButton: some View {
        Button {
            Haptics.tap()
            withAnimation(Theme.spring) {
                choosingVote.toggle()
                chosenForVote = []
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: choosingVote ? "xmark" : "checkmark.seal.fill")
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choosingVote ? "Cancel Vote" : pollIsOpen ? "Start a New Vote" : "Can't Decide? Start a Vote")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Theme.textPrimary)
                    Text(choosingVote ? "Tap 2 to 5 films below." : "Pick 2 to 5 of these and everyone votes 👍 or 👎.")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(12)
            .cardStyle(cornerRadius: 16)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
    }

    private var sendVoteBar: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Closes After", selection: $pollLength) {
                    ForEach(PollLength.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label(pollLength.label, systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.surfaceRaised, in: Capsule())
            }
            Button(action: sendVote) {
                Group {
                    if sendingVote {
                        ProgressView().tint(Theme.onAccent)
                    } else {
                        Text(chosenForVote.count < 2 ? "Pick \(2 - chosenForVote.count) More" : "Send Vote · \(chosenForVote.count) Films")
                    }
                }
                .font(.subheadline.weight(.bold))
                .foregroundColor(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accentGradient, in: Capsule())
                .opacity(chosenForVote.count < 2 ? 0.5 : 1)
            }
            .disabled(chosenForVote.count < 2 || sendingVote)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func toggleForVote(_ movie: Movie) {
        Haptics.tap()
        if let index = chosenForVote.firstIndex(of: movie.id) {
            chosenForVote.remove(at: index)
        } else if chosenForVote.count < 5 {
            chosenForVote.append(movie.id)
        }
    }

    private func sendVote() {
        guard let groupID else { return }
        let films = chosenForVote.compactMap { id in picks.first { $0.id == id } }
        sendingVote = true
        APIService.shared.startPoll(groupID: groupID, films: films, hours: pollLength.rawValue) { result in
            sendingVote = false
            switch result {
            case .success(let started):
                Haptics.success()
                withAnimation(Theme.spring) {
                    poll = started
                    choosingVote = false
                    chosenForVote = []
                }
            case .failure:
                voteFailed = true
            }
        }
    }

    private func pickRow(_ movie: Movie) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(path: movie.poster_path, cornerRadius: 10, size: .small)
                .frame(width: 70, height: 105)
            VStack(alignment: .leading, spacing: 6) {
                Text(movie.title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Text(Theme.year(from: movie.release_date))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                if let reason = movie.reason {
                    Label(reason, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Haptics.tap()
                    adding = movie
                } label: {
                    Label(added.contains(movie.id) ? "Added" : "Add to Lists",
                          systemImage: added.contains(movie.id) ? "checkmark" : "plus")
                        .font(.caption.weight(.bold))
                        .foregroundColor(added.contains(movie.id) ? Theme.textSecondary : Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(added.contains(movie.id) ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(Theme.accentGradient),
                                    in: Capsule())
                }
                .disabled(added.contains(movie.id))
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            if choosingVote {
                let chosen = chosenForVote.contains(movie.id)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(chosen ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(14)
        .cardStyle(cornerRadius: 18)
        .contentShape(Rectangle())
        .onTapGesture {
            if choosingVote { toggleForVote(movie) }
        }
        .accessibilityAddTraits(choosingVote && chosenForVote.contains(movie.id) ? .isSelected : [])
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        APIService.shared.movieNight(handles: people.map(\.handle), groupID: groupID, usesAI: usesAI && canUseAI, filters: filters) { result in
            isLoading = false
            switch result {
            case .success(let movies):
                picks = movies
                if movies.isEmpty {
                    errorMessage = !filters.isEmpty
                        ? "Nothing fits these filters this time. Try fewer of them."
                        : usesAI
                        ? "The AI didn't find anything new for everyone this time."
                        : "Not enough to go on yet. Movie Night works best when everyone has ranked a few films."
                }
            case .failure(let error):
                switch (error as NSError).code {
                case 403: errorMessage = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                    ?? "Everyone needs to allow AI features for AI Picks."
                case 429: errorMessage = "You've used today's AI picks. Try again tomorrow."
                case 503: errorMessage = "AI picks aren't available right now."
                default: errorMessage = "Something went wrong. Check your connection and try again."
                }
            }
        }
    }

    // AI Picks or Classic, like Discover. AI Picks only when everyone allows AI
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Recommendations", selection: $usesAI) {
                Text("AI Picks").tag(true)
                Text("Classic").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!canUseAI || isLoading)
            .onChange(of: usesAI) { _ in load() }
            if !canUseAI {
                Text(people.count > 1
                     ? "AI Picks need everyone in the group to allow AI features in Settings."
                     : "AI Picks need you and \(names) to both allow AI features in Settings.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func add(_ movie: Movie, to lists: [CDMovieList]) {
        guard !lists.isEmpty else { return }
        added.insert(movie.id)
        for list in lists {
            list.addMovie(movie, context: context) { saved in
                if saved == nil {
                    added.remove(movie.id)
                }
            }
        }
    }
}

/// Genres, languages and streaming services a movie night's picks have to fit
struct MovieNightFiltersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var filters: MovieNightFilters
    let onApply: (MovieNightFilters) -> Void
    @State private var services: [StreamingService] = []

    init(filters: MovieNightFilters, onApply: @escaping (MovieNightFilters) -> Void) {
        _filters = State(initialValue: filters)
        self.onApply = onApply
    }

    private static let genres = TasteProfile.genreNames.keys.filter { $0 != 10770 }
        .sorted { (TasteProfile.genreNames[$0] ?? "") < (TasteProfile.genreNames[$1] ?? "") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("GENRE", note: "Any of these. None picked means any genre.") {
                        ForEach(Self.genres, id: \.self) { genre in
                            chip(TasteProfile.genreNames[genre] ?? "Other", selected: filters.genres.contains(genre)) {
                                if filters.genres.contains(genre) { filters.genres.remove(genre) } else { filters.genres.insert(genre) }
                            }
                        }
                    }
                    section("LANGUAGE", note: "Films originally made in one of these. None picked means any language.") {
                        ForEach(DiscoverFilters.commonLanguages, id: \.self) { code in
                            chip(DiscoverFilters.languageName(code), selected: filters.languages.contains(code)) {
                                if let i = filters.languages.firstIndex(of: code) { filters.languages.remove(at: i) } else { filters.languages.append(code) }
                            }
                        }
                    }
                    section("STREAMING ON", note: "Films you can stream on one of these in your country.") {
                        if services.isEmpty {
                            ProgressView()
                        }
                        ForEach(services) { service in
                            chip(service.name, selected: filters.services.contains(service)) {
                                if let i = filters.services.firstIndex(of: service) { filters.services.remove(at: i) } else { filters.services.append(service) }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { filters = MovieNightFilters() }
                        .disabled(filters.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.success()
                        onApply(filters)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                APIService.shared.fetchStreamingServices { result in
                    if case .success(let loaded) = result { services = loaded }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.heavy))
                .tracking(1.2)
                .foregroundColor(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                content()
            }
            Text(note)
                .font(.caption)
                .foregroundColor(Theme.textTertiary)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
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
                .padding(.horizontal, 6)
                .background(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Movie Night Groups" on Profile: the user's groups, each opening a movie night, and a way to make new ones
struct MovieNightGroupsSection: View {
    @ObservedObject private var social = SocialStore.shared
    @AppStorage(Personalization.aiAllowedKey) private var aiAllowed = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared
    @State private var groups: [MovieGroup] = []
    @State private var openGroup: MovieGroup? = nil
    @State private var showNewGroup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Movie Night Groups")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if !social.following.isEmpty {
                    Button {
                        Haptics.tap()
                        showNewGroup = true
                    } label: {
                        Label("New Group", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentGradient)
                    }
                }
            }
            if groups.isEmpty {
                Text(social.following.isEmpty
                     ? "Follow some friends, then make a group to find films you'll all enjoy."
                     : "Make a group with people you follow to find films you'll all enjoy.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
            ForEach(groups) { group in
                Button {
                    Haptics.tap()
                    openGroup = group
                } label: {
                    HStack(spacing: 12) {
                        // Up to three faces, overlapping
                        HStack(spacing: -12) {
                            ForEach(group.members.prefix(3)) { person in
                                Avatar(name: person.display_name, size: 34, handle: person.handle, version: person.avatar_version)
                                    .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.headline)
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            Text(group.members.map(\.display_name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if group.needs_my_vote == true {
                            Text("Vote Now")
                                .font(.caption.weight(.heavy))
                                .foregroundColor(Theme.onAccent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.accentGradient, in: Capsule())
                        } else if group.poll_open == true {
                            Label("Voting", systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            Image(systemName: "ticket.fill")
                                .foregroundStyle(Theme.accentGradient)
                        }
                    }
                    .padding(12)
                    .cardStyle(cornerRadius: 16)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.98))
                .contextMenu {
                    Button(role: .destructive) {
                        leave(group)
                    } label: {
                        Label(group.is_owner ? "Delete Group" : "Leave Group", systemImage: group.is_owner ? "trash" : "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .onAppear(perform: load)
        // A vote notification opens its group
        .onReceive(NotificationManager.shared.$openGroupID) { id in
            guard let id else { return }
            NotificationManager.shared.openGroupID = nil
            APIService.shared.fetchGroups { result in
                guard case .success(let loaded) = result else { return }
                groups = loaded
                openGroup = loaded.first { $0.id == id }
            }
        }
        .sheet(item: $openGroup, onDismiss: load) { group in
            MovieNightView(people: group.members, groupID: group.id, groupName: group.name,
                           canUseAI: group.ai_possible && aiAllowed && ageRange != Personalization.under18)
        }
        .sheet(isPresented: $showNewGroup, onDismiss: load) {
            NewGroupSheet()
        }
    }

    private func load() {
        APIService.shared.fetchGroups { result in
            if case .success(let loaded) = result { groups = loaded }
        }
    }

    private func leave(_ group: MovieGroup) {
        groups.removeAll { $0.id == group.id }
        APIService.shared.leaveGroup(group.id) { left in
            if !left { load() }
        }
    }
}

/// Names a new group and picks who's in it, from the people the user follows
struct NewGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var social = SocialStore.shared
    @State private var name = ""
    @State private var chosen: Set<String> = []
    @State private var isSaving = false
    @State private var failed = false

    private static let maxMembers = 7

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Friday Crew", text: $name)
                }
                .listRowBackground(Theme.surface)
                Section {
                    ForEach(social.following) { person in
                        Button {
                            Haptics.tap()
                            if chosen.contains(person.handle) {
                                chosen.remove(person.handle)
                            } else if chosen.count < Self.maxMembers {
                                chosen.insert(person.handle)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(name: person.display_name, size: 32, handle: person.handle, version: person.avatar_version)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("@\(person.handle)")
                                        .foregroundColor(Theme.textPrimary)
                                    Text(person.display_name)
                                        .font(.caption)
                                        .foregroundColor(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: chosen.contains(person.handle) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(person.handle) ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                            }
                        }
                    }
                } header: {
                    Text("Who's In")
                } footer: {
                    Text("Pick up to \(Self.maxMembers) people you follow. Everyone in the group can see it and plan a movie night for it.")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Create", action: create)
                            .bold()
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || chosen.isEmpty)
                    }
                }
            }
            .alert("Couldn't create the group", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
            }
        }
    }

    private func create() {
        isSaving = true
        APIService.shared.createGroup(name: name.trimmingCharacters(in: .whitespaces), handles: Array(chosen)) { created in
            isSaving = false
            if created {
                Haptics.success()
                dismiss()
            } else {
                failed = true
            }
        }
    }
}
