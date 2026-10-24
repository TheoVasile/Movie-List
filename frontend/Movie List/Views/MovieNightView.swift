//
//  MovieNightView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import SwiftUI
import CoreData

/// Films the user and the people they're watching with would all enjoy, each saying why it suits them, that can
/// be added straight to the user's lists. For people the user follows, without a saved group (groups have their
/// own shortlist: GroupMovieNightView). AI Picks come from the AI reading everyone's lists, and are only offered
/// when everyone allows AI; Classic picks come from TMDb's recommendations for everyone's favourites, plus films on
/// several people's watchlists. Either can be narrowed by genre, language and streaming service
struct MovieNightView: View {
    // Everyone coming besides the user
    let people: [UserSummary]
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
    // The film whose info screen is open, as a temporary copy that isn't saved anywhere
    @State private var details: CDMovie? = nil

    init(people: [UserSummary], canUseAI: Bool) {
        self.people = people
        self.canUseAI = canUseAI
        _usesAI = State(initialValue: canUseAI)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MovieNightSourcePicker(usesAI: $usesAI, canUseAI: canUseAI, isLoading: isLoading, people: people)
                    .onChange(of: usesAI) { _ in load() }
                ZStack {
                    Theme.background.ignoresSafeArea()
                    if isLoading {
                        VStack(spacing: 14) {
                            ProgressView()
                                .tint(Theme.accent)
                            Text(people.count > 1 ? "Finding films you'll all enjoy…" : "Finding films you'll both enjoy…")
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        }
                    } else if let errorMessage {
                        EmptyStateView(icon: "ticket", title: "Couldn't plan a movie night", message: errorMessage,
                                       actionTitle: "Try Again", action: load)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(usesAI
                                     ? "Picked by AI from your lists and \(MovieNightNames.of(people))'s. None of these are in anyone's lists yet."
                                     : "Recommended by TMDb from your favourites and \(MovieNightNames.of(people))'s, plus anything on more than one watchlist.")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.textSecondary)
                                ForEach(Array(picks.enumerated()), id: \.element.id) { index, movie in
                                    pickRow(movie)
                                        .appearAnimation(delay: Double(min(index, 8)) * 0.05)
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Movie Night with \(MovieNightNames.of(people))")
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
            .sheet(item: $details) { preview in
                // Add to Lists closes the info screen and asks which lists
                MovieDetailView(movie: preview, onAddToLists: {
                    let film = picks.first { $0.id == Int64(preview.tmdb_id) }
                    details = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { adding = film }
                })
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
            if picks.isEmpty { load() }
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
                    // Sparkles only mark the AI's picks; Classic reasons come from TMDb and the watchlists
                    Label(reason, systemImage: movie.ai == true ? "sparkles" : "film.stack")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AddToListsButton(added: added.contains(movie.id)) { adding = movie }
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardStyle(cornerRadius: 18)
        // Tapping anywhere but the button opens the film's info
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            details = PersistenceController.preview(of: movie)
        }
        .accessibilityAction(named: "Show Details") { details = PersistenceController.preview(of: movie) }
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        APIService.shared.movieNight(handles: people.map(\.handle), usesAI: usesAI && canUseAI, filters: filters) { result in
            isLoading = false
            switch result {
            case .success(let movies):
                if usesAI && canUseAI { AppAnalytics.log(.aiPickUsed(.movieNight)) }
                picks = movies
                if movies.isEmpty {
                    errorMessage = MovieNightMessages.empty(filtered: !filters.isEmpty, usesAI: usesAI)
                }
            case .failure(let error):
                errorMessage = MovieNightMessages.failure(error)
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

/// "@sam", "@sam and @ana", "@sam, @ana and @lee"
enum MovieNightNames {
    static func of(_ people: [UserSummary]) -> String {
        let all = people.map { "@\($0.handle)" }
        guard all.count > 1 else { return all.first ?? "" }
        return all.dropLast().joined(separator: ", ") + " and " + (all.last ?? "")
    }
}

/// What to say when a movie night finds nothing or fails, for friends and groups alike
enum MovieNightMessages {
    static func empty(filtered: Bool, usesAI: Bool) -> String {
        filtered ? "Nothing fits these filters this time. Try fewer of them."
            : usesAI ? "The AI didn't find anything new for everyone this time."
            : "Not enough to go on yet. Movie Night works best when everyone has ranked a few films."
    }

    static func failure(_ error: Error) -> String {
        switch (error as NSError).code {
        case 403: return (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
            ?? "Everyone needs to allow AI features for AI Picks."
        case 429: return "You've used today's AI picks. Try again tomorrow."
        case 503: return "AI picks aren't available right now."
        default: return "Something went wrong. Check your connection and try again."
        }
    }
}

/// AI Picks or Classic, like Discover. AI Picks only when everyone allows AI
struct MovieNightSourcePicker: View {
    @Binding var usesAI: Bool
    let canUseAI: Bool
    let isLoading: Bool
    let people: [UserSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Recommendations", selection: $usesAI) {
                Text("AI Picks").tag(true)
                Text("Classic").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!canUseAI || isLoading)
            if !canUseAI {
                Text(people.count > 1
                     ? "AI Picks need everyone in the group to allow AI features in Settings."
                     : "AI Picks need you and \(MovieNightNames.of(people)) to both allow AI features in Settings.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// "Add to Lists", or "Added" once it's in one
struct AddToListsButton: View {
    let added: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(added ? "Added" : "Add to Lists", systemImage: added ? "checkmark" : "plus")
                .font(.caption.weight(.bold))
                .foregroundColor(added ? Theme.textSecondary : Theme.onAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(added ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(Theme.accentGradient), in: Capsule())
        }
        .buttonStyle(.borderless)
        .disabled(added)
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
            FlowLayout(spacing: 8) {
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
            // Same as Discover's filters: full-size text, with the tag growing to fit
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
            GroupMovieNightView(group: group,
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
    @State private var reporting: ReportTarget? = nil

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
                            .contextMenu {
                                Button {
                                    reporting = ReportTarget(handle: person.handle, kind: .group, contentID: String(group.id))
                                } label: {
                                    Label("Report @\(person.handle)", systemImage: "flag")
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
            .sheet(item: $reporting) { target in
                ReportSheet(target: target)
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
