//
//  GroupMovieNightView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-21.
//

import Foundation
import SwiftUI
import CoreData

/// A movie night group's shortlist: films recommended for the group and films people in it suggested, which
/// everyone likes or dislikes. A film everyone dislikes leaves for good; refreshing swaps the recommendations
/// nobody liked for new ones. A vote picks tonight's film from the liked ones, one vote each
struct GroupMovieNightView: View {
    // Whether everyone, the user included, allows AI features, which AI Picks need
    let canUseAI: Bool

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @ObservedObject private var social = SocialStore.shared

    // The group as it is now, after anyone is added or removed
    @State private var group: MovieGroup
    @State private var picks: [GroupPick] = []
    @State private var poll: GroupPoll? = nil
    @State private var usesAI: Bool
    @State private var filters = MovieNightFilters()
    @State private var hasLoaded = false
    @State private var refreshing = false
    @State private var errorMessage: String? = nil
    // Films whose like or dislike is being saved
    @State private var reacting: Set<Int64> = []
    @State private var startingVote = false
    @State private var alertMessage: String? = nil
    // The film waiting for the user to choose lists, and the films already added
    @State private var adding: Movie? = nil
    @State private var added: Set<Int64> = []
    // The film whose info screen is open, as a temporary copy that isn't saved anywhere, and the film it shows
    @State private var details: CDMovie? = nil
    @State private var detailsMovie: Movie? = nil
    @State private var showMembers = false
    @State private var showFilters = false
    @State private var showSuggest = false
    @State private var reporting: ReportTarget? = nil

    init(group: MovieGroup, canUseAI: Bool) {
        _group = State(initialValue: group)
        self.canUseAI = canUseAI
        _usesAI = State(initialValue: canUseAI)
    }

    private var pollIsOpen: Bool { poll.map { !$0.closed } ?? false }
    private var likedCount: Int { picks.filter { $0.likes > 0 }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    membersCard
                    MovieNightSourcePicker(usesAI: $usesAI, canUseAI: canUseAI, isLoading: refreshing, people: group.members)
                        .padding(.horizontal, -16)
                        .onChange(of: usesAI) { _ in refresh() }
                    if let binding = Binding($poll) {
                        PollCard(groupID: group.id, poll: binding, onAddWinner: { adding = $0 }, onShowDetails: showDetails) {
                            withAnimation(Theme.spring) { poll = nil }
                        }
                        .transition(.opacity)
                    }
                    voteStarter
                    shortlist
                }
                .padding(16)
            }
            .refreshable { await fetchAll() }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(group.name)
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
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(refreshing)
                    .accessibilityLabel("New Picks")
                    .accessibilityHint("Replaces the picks nobody has liked")
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
            .sheet(item: $details) { preview in
                // Add to Lists closes the info screen and asks which lists
                MovieDetailView(movie: preview, onAddToLists: {
                    let film = detailsMovie
                    details = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { adding = film }
                })
            }
            .sheet(isPresented: $showMembers) {
                GroupMembersSheet(group: group) { updated in
                    group = updated
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFilters) {
                MovieNightFiltersSheet(filters: filters) { chosen in
                    filters = chosen
                    refresh()
                }
                .presentationDetents([.large])
            }
            .sheet(item: $reporting) { target in
                ReportSheet(target: target)
            }
            .sheet(isPresented: $showSuggest) {
                SuggestFilmSheet(alreadyIn: Set(picks.map(\.tmdb_id))) { movie in
                    suggest(movie)
                }
                .presentationDetents([.large])
            }
            .alert("Couldn't do that", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
        .task {
            guard !hasLoaded else { return }
            await fetchAll()
            hasLoaded = true
            // A new group, or one whose shortlist ran out, starts with recommendations
            if picks.isEmpty && errorMessage == nil { refresh() }
        }
    }

    // MARK: Who's in

    // Everyone in the group, so it's clear who the picks are for. Opens the full list, where the person who made
    // the group can add and remove people
    private var membersCard: some View {
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
                .frame(maxWidth: 64)
        }
    }

    // MARK: Vote

    // A vote between the liked films, once there are at least two
    private var voteStarter: some View {
        Menu {
            Section("Closes After") {
                ForEach(PollLength.allCases) { length in
                    Button(length.label) { startVote(hours: length.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                if startingVote {
                    ProgressView()
                } else {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accentGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pollIsOpen ? "Start a New Vote" : "Ready to Decide? Start a Vote")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Theme.textPrimary)
                    Text(likedCount < 2
                         ? "Like at least 2 films below, then everyone votes for one."
                         : "Everyone votes for one of the \(likedCount) liked films.")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(12)
            .cardStyle(cornerRadius: 16)
            .opacity(likedCount < 2 ? 0.6 : 1)
        }
        .disabled(likedCount < 2 || startingVote)
    }

    private func startVote(hours: Int) {
        startingVote = true
        APIService.shared.startPoll(groupID: group.id, hours: hours) { result in
            startingVote = false
            switch result {
            case .success(let started):
                Haptics.success()
                withAnimation(Theme.spring) { poll = started }
            case .failure:
                alertMessage = "Couldn't start the vote. Check your connection and try again."
            }
        }
    }

    // MARK: Shortlist

    @ViewBuilder
    private var shortlist: some View {
        HStack {
            Text("SHORTLIST")
                .font(.caption2.weight(.heavy))
                .tracking(1.2)
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Button {
                Haptics.tap()
                showSuggest = true
            } label: {
                Label("Suggest a Film", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentGradient)
            }
        }
        .padding(.top, 4)
        Text(usesAI
             ? "Picked by AI from everyone's lists, plus films people here suggested. Like the ones you'd watch: anything everyone passes on goes, and New Picks swaps out the ones nobody liked."
             : "Recommended by TMDb from everyone's favourites, plus films people here suggested. Like the ones you'd watch: anything everyone passes on goes, and New Picks swaps out the ones nobody liked.")
            .font(.caption)
            .foregroundColor(Theme.textTertiary)
        if refreshing {
            HStack(spacing: 10) {
                ProgressView()
                Text(group.members.count > 1 ? "Finding films you'll all enjoy…" : "Finding films you'll both enjoy…")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        if let errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                Button("Try Again", action: refresh)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentGradient)
            }
        }
        ForEach(picks) { pick in
            pickRow(pick)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    private func pickRow(_ pick: GroupPick) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(path: pick.poster_path, cornerRadius: 10, size: .small)
                .frame(width: 70, height: 105)
            VStack(alignment: .leading, spacing: 6) {
                Text(pick.title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Text(Theme.year(from: pick.release_date ?? ""))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                if let by = pick.suggested_by {
                    Label(by == social.profile?.handle ? "You suggested this" : "Suggested by @\(by)", systemImage: "person.fill")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                } else if let reason = pick.reason {
                    // Sparkles only mark the AI's picks; Classic reasons come from TMDb and the watchlists
                    Label(reason, systemImage: pick.ai == true ? "sparkles" : "film.stack")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !pick.liked_by.isEmpty {
                    Text("Liked by " + pick.liked_by.map { $0 == social.profile?.handle ? "you" : "@\($0)" }.joined(separator: ", "))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accentGradient)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    reactionButton(pick, value: 1)
                    reactionButton(pick, value: -1)
                    AddToListsButton(added: added.contains(pick.tmdb_id)) { adding = pick.movie }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardStyle(cornerRadius: 18)
        // Tapping anywhere but the buttons opens the film's info
        .contentShape(Rectangle())
        .onTapGesture { showDetails(pick.movie) }
        .accessibilityAction(named: "Show Details") { showDetails(pick.movie) }
        .contextMenu {
            // Whoever suggested a film, or the group's owner, can take it off
            if let by = pick.suggested_by, by == social.profile?.handle || group.is_owner {
                Button(role: .destructive) {
                    remove(pick)
                } label: {
                    Label("Remove Suggestion", systemImage: "trash")
                }
            }
            // Someone else's suggestion can be reported
            if let by = pick.suggested_by, by != social.profile?.handle {
                Button {
                    reporting = ReportTarget(handle: by, kind: .group, contentID: "\(group.id)/\(pick.tmdb_id)")
                } label: {
                    Label("Report Suggestion", systemImage: "flag")
                }
            }
        }
    }

    // 👍 or 👎 with how many people chose it; tapping the one already chosen takes it back
    private func reactionButton(_ pick: GroupPick, value: Int) -> some View {
        let chosen = pick.my_reaction == value
        let count = value > 0 ? pick.likes : pick.dislikes
        return Button {
            Haptics.select()
            react(pick, chosen ? 0 : value)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: value > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                if count > 0 { Text("\(count)").monospacedDigit() }
            }
            .font(.caption.weight(.bold))
            .foregroundColor(chosen ? Theme.onAccent : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if chosen {
                    Capsule().fill(value > 0 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.red.opacity(0.8)))
                } else {
                    Capsule().fill(Theme.surfaceRaised)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(reacting.contains(pick.tmdb_id))
        .accessibilityLabel(value > 0 ? "Like, \(pick.likes) so far" : "Dislike, \(pick.dislikes) so far")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: Actions

    private func showDetails(_ movie: Movie) {
        Haptics.tap()
        detailsMovie = movie
        details = PersistenceController.preview(of: movie)
    }

    private func fetchAll() async {
        await withCheckedContinuation { continuation in
            let done = DispatchGroup()
            done.enter()
            APIService.shared.fetchPoll(groupID: group.id) { result in
                if case .success(let current) = result { poll = current }
                done.leave()
            }
            done.enter()
            APIService.shared.fetchGroupPicks(groupID: group.id) { result in
                switch result {
                case .success(let loaded): picks = loaded
                case .failure: errorMessage = "Couldn't load the shortlist. Check your connection and try again."
                }
                done.leave()
            }
            done.notify(queue: .main) { continuation.resume() }
        }
    }

    /// New recommendations in place of the ones nobody liked
    private func refresh() {
        refreshing = true
        errorMessage = nil
        APIService.shared.refreshGroupPicks(groupID: group.id, usesAI: usesAI && canUseAI, filters: filters) { result in
            refreshing = false
            switch result {
            case .success(let loaded):
                if usesAI && canUseAI { AppAnalytics.log(.aiPickUsed(.movieNight)) }
                withAnimation(Theme.spring) { picks = loaded }
                if loaded.isEmpty {
                    errorMessage = MovieNightMessages.empty(filtered: !filters.isEmpty, usesAI: usesAI)
                }
            case .failure(let error):
                errorMessage = MovieNightMessages.failure(error)
            }
        }
    }

    private func react(_ pick: GroupPick, _ value: Int) {
        reacting.insert(pick.tmdb_id)
        APIService.shared.reactToPick(groupID: group.id, tmdbID: pick.tmdb_id, reaction: value) { result in
            reacting.remove(pick.tmdb_id)
            switch result {
            case .success(let loaded):
                withAnimation(Theme.spring) { picks = loaded }
            case .failure:
                alertMessage = "Couldn't save that. Check your connection and try again."
            }
        }
    }

    private func suggest(_ movie: Movie) {
        APIService.shared.suggestPick(groupID: group.id, movie: movie) { result in
            switch result {
            case .success(let loaded):
                Haptics.success()
                withAnimation(Theme.spring) { picks = loaded }
            case .failure:
                alertMessage = "Couldn't suggest \(movie.title). Check your connection and try again."
            }
        }
    }

    private func remove(_ pick: GroupPick) {
        APIService.shared.removePick(groupID: group.id, tmdbID: pick.tmdb_id) { result in
            switch result {
            case .success(let loaded):
                withAnimation(Theme.spring) { picks = loaded }
            case .failure:
                alertMessage = "Couldn't remove \(pick.title)."
            }
        }
    }

    private func add(_ movie: Movie, to lists: [CDMovieList]) {
        guard !lists.isEmpty else { return }
        added.insert(movie.id)
        AppAnalytics.log(.filmAdded(.movieNight))
        for list in lists {
            list.addMovie(movie, context: context) { saved in
                if saved == nil {
                    added.remove(movie.id)
                }
            }
        }
    }
}

/// Searches TMDb for a film to suggest to a group
struct SuggestFilmSheet: View {
    // Films already on the shortlist, which can't be suggested again
    let alreadyIn: Set<Int64>
    let onPick: (Movie) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Movie] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty && !query.isEmpty && !searching {
                    Text("No films found.")
                        .foregroundColor(Theme.textSecondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(results) { movie in
                    Button {
                        Haptics.tap()
                        onPick(movie)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PosterImage(path: movie.poster_path, cornerRadius: 6, size: .small)
                                .frame(width: 40, height: 60)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movie.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(2)
                                Text(Theme.year(from: movie.release_date))
                                    .font(.caption)
                                    .foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            if alreadyIn.contains(movie.id) {
                                Text("On the list")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                    .disabled(alreadyIn.contains(movie.id))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a film")
            .onSubmit(of: .search, search)
            .onChange(of: query) { _ in
                // Searches shortly after typing stops
                let typed = query
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if typed == query { search() }
                }
            }
            .navigationTitle("Suggest a Film")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func search() {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { results = []; return }
        searching = true
        APIService.shared.searchMovies(name: typed) { result in
            searching = false
            if typed == query.trimmingCharacters(in: .whitespaces), case .success(let found) = result {
                results = found
            }
        }
    }
}
