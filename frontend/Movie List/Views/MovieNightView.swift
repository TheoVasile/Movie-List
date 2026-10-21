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
/// that can be added straight to the user's lists. AI Picks come from the AI reading everyone's lists, and are
/// only offered when everyone allows AI; Classic picks come from TMDb's recommendations for everyone's
/// favourites, plus films on several people's watchlists. Either can be narrowed by genre, language and
/// streaming service
struct MovieNightView: View {
    // Everyone coming besides the user
    @State private var people: [UserSummary]
    // A saved group, when it's for one
    var groupID: Int64? = nil
    var groupName: String? = nil
    // The group as it is now, after anyone is added or removed
    @State private var group: MovieGroup?
    @State private var showMembers = false
    @ObservedObject private var social = SocialStore.shared
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

    init(people: [UserSummary], groupID: Int64? = nil, groupName: String? = nil, group: MovieGroup? = nil, canUseAI: Bool) {
        _people = State(initialValue: people)
        self.groupID = groupID ?? group?.id
        self.groupName = groupName ?? group?.name
        _group = State(initialValue: group)
        self.canUseAI = canUseAI
        _usesAI = State(initialValue: canUseAI)
    }

    // "Sam", "Sam and Ana", "Sam, Ana and Lee"
    private var names: String {
        let all = people.map(\.display_name)
        guard all.count > 1 else { return all.first ?? "" }
        return all.dropLast().joined(separator: ", ") + " and " + (all.last ?? "")
    }

    private var title: String {
        groupName ?? "Movie Night with \(names)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let group {
                    membersCard(group)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
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
            .sheet(isPresented: $showMembers) {
                if let current = group {
                    GroupMembersSheet(group: current) { updated in
                        let changed = Set(updated.members.map(\.handle)) != Set(people.map(\.handle))
                        group = updated
                        people = updated.members
                        // New picks for the new line-up, unless a vote is going on
                        if changed && !pollIsOpen { load() }
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
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
                 ? "Picked by AI from your lists and \(names)'s. None of these are in anyone's lists yet."
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

    // Groups only: everyone in it, so it's clear who the picks are for. Opens the full list, where the person who
    // made the group can add and remove people
    private func membersCard(_ group: MovieGroup) -> some View {
        Button {
            Haptics.tap()
            showMembers = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("WHO'S IN · \(group.members.count + 1)")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text(group.is_owner ? "Add or Remove" : "See All")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accentGradient)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        memberBubble(label: "You", name: social.profile?.display_name ?? "You", handle: social.profile?.handle,
                                     version: social.profile?.avatar_version, isOwner: group.is_owner)
                        ForEach(group.members) { person in
                            memberBubble(label: "@\(person.handle)", name: person.display_name, handle: person.handle,
                                         version: person.avatar_version, isOwner: person.is_owner == true)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .padding(12)
            .cardStyle(cornerRadius: 16)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .accessibilityLabel("Who's in: You, \(group.members.map { "@\($0.handle)" }.joined(separator: ", "))")
    }

    private func memberBubble(label: String, name: String, handle: String?, version: Double?, isOwner: Bool) -> some View {
        VStack(spacing: 4) {
            Avatar(name: name, size: 44, handle: handle, version: version)
                .overlay(alignment: .topTrailing) {
                    if isOwner {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .padding(4)
                            .background(Theme.accentGradient, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 64)
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
                            Text((["You"] + group.members.map { "@\($0.handle)" }).joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(2)
                            Label("\(group.members.count + 1) people · made by \(group.is_owner ? "you" : group.members.first { $0.is_owner == true }.map { "@\($0.handle)" } ?? "a friend")",
                                  systemImage: "person.2.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(Theme.textTertiary)
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
            MovieNightView(people: group.members, group: group,
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

/// Everyone in a group, with who made it. The person who made it can add people they follow and remove anyone
struct GroupMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var social = SocialStore.shared
    @State var group: MovieGroup
    let onChange: (MovieGroup) -> Void
    @State private var busy: Set<String> = []
    @State private var failed = false

    private static let maxMembers = 7

    // People the user follows who aren't in the group yet
    private var addable: [UserSummary] {
        let inGroup = Set(group.members.map(\.handle))
        return social.following.filter { !inGroup.contains($0.handle) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(name: social.profile?.display_name ?? "You", handle: social.profile?.handle, version: social.profile?.avatar_version,
                        isMe: true, isOwner: group.is_owner)
                    ForEach(group.members) { person in
                        row(name: person.display_name, handle: person.handle, version: person.avatar_version,
                            isMe: false, isOwner: person.is_owner == true)
                            .swipeActions {
                                if group.is_owner {
                                    Button("Remove", role: .destructive) { remove(person) }
                                }
                            }
                    }
                } header: {
                    Text("In This Group · \(group.members.count + 1)")
                } footer: {
                    if group.is_owner {
                        Text("Swipe left on someone to remove them.")
                    } else {
                        Text("Only the person who made the group can add or remove people.")
                    }
                }
                .listRowBackground(Theme.surface)

                if group.is_owner {
                    Section {
                        if addable.isEmpty {
                            Text("Everyone you follow is already in this group.")
                                .foregroundColor(Theme.textSecondary)
                        }
                        ForEach(addable) { person in
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
                                if busy.contains(person.handle) {
                                    ProgressView()
                                } else {
                                    Button {
                                        add(person)
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(Theme.accentGradient)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(group.members.count >= Self.maxMembers)
                                    .accessibilityLabel("Add @\(person.handle)")
                                }
                            }
                        }
                    } header: {
                        Text("Add People You Follow")
                    } footer: {
                        Text(group.members.count >= Self.maxMembers
                             ? "Groups can have up to \(Self.maxMembers + 1) people, you included."
                             : "They'll get a notification that they're in.")
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
            .alert("Couldn't change the group", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
            }
            .onAppear {
                if social.following.isEmpty { social.load() }
            }
        }
    }

    private func row(name: String, handle: String?, version: Double?, isMe: Bool, isOwner: Bool) -> some View {
        HStack(spacing: 12) {
            Avatar(name: name, size: 36, handle: handle, version: version)
            VStack(alignment: .leading, spacing: 1) {
                let shown = handle.map { "@\($0)" } ?? name
                Text(isMe ? "\(shown) (you)" : shown)
                    .foregroundColor(Theme.textPrimary)
                if handle != nil {
                    Text(name)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            Spacer()
            if busy.contains(handle ?? "") {
                ProgressView()
            } else if isOwner {
                Label("Made the group", systemImage: "crown.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentGradient)
            }
        }
    }

    private func add(_ person: UserSummary) {
        Haptics.tap()
        busy.insert(person.handle)
        APIService.shared.addGroupMembers(group.id, handles: [person.handle]) { result in
            busy.remove(person.handle)
            apply(result)
        }
    }

    private func remove(_ person: UserSummary) {
        busy.insert(person.handle)
        APIService.shared.removeGroupMember(group.id, handle: person.handle) { result in
            busy.remove(person.handle)
            apply(result)
        }
    }

    private func apply(_ result: Result<MovieGroup, Error>) {
        switch result {
        case .success(let updated):
            Haptics.success()
            withAnimation(Theme.spring) { group = updated }
            onChange(updated)
        case .failure:
            failed = true
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
                                    Text(person.display_name)
                                        .foregroundColor(Theme.textPrimary)
                                    Text("@\(person.handle)")
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
