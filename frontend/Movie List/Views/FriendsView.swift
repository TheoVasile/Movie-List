//
//  FriendsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-18.
//

import Foundation
import SwiftUI

// MARK: - Store

/// The signed-in user's @username and who they follow, shared by every friends screen
final class SocialStore: ObservableObject {
    static let shared = SocialStore()

    @Published private(set) var profile: UserProfile? = nil
    @Published private(set) var following: [UserSummary] = []
    @Published private(set) var hasLoaded = false

    func load() {
        APIService.shared.fetchMyProfile { result in
            if case .success(let profile) = result { self.profile = profile }
            self.hasLoaded = true
        }
        APIService.shared.fetchFollowing { result in
            if case .success(let people) = result { self.following = people }
        }
    }

    /// Calls back with nil on success, or a message to show
    func setHandle(_ handle: String, completion: @escaping (String?) -> Void) {
        APIService.shared.setHandle(handle) { result in
            switch result {
            case .success:
                self.load()
                completion(nil)
            case .failure(let error):
                switch (error as NSError).code {
                case 409: completion("That username is taken.")
                case 400: completion("Usernames are 3 to 20 letters, numbers, underscores or dots.")
                default: completion("Couldn't save your username. Check your connection and try again.")
                }
            }
        }
    }

    /// Follows or unfollows, showing the change straight away and undoing it if the server says no
    func setFollowing(_ person: UserSummary, _ follow: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        let previous = following
        if follow {
            if !following.contains(where: { $0.handle == person.handle }) {
                var followed = person
                followed.following = true
                following.insert(followed, at: 0)
            }
        } else {
            following.removeAll { $0.handle == person.handle }
        }
        APIService.shared.setFollowing(person.handle, follow) { result in
            switch result {
            case .success:
                self.load()
                completion(true)
            case .failure(let error):
                print("Error updating follow:", error)
                self.following = previous
                completion(false)
            }
        }
    }

    func isFollowing(_ handle: String) -> Bool {
        following.contains { $0.handle == handle }
    }
}

// MARK: - Username

/// Picks or changes the user's @username, which is how friends find them
struct UsernameSetupView: View {
    @ObservedObject private var social = SocialStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var errorMessage: String? = nil
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private var cleaned: String {
        handle.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
    }

    // Same rule as the server: 3-20 of a-z, 0-9, _ and ., no leading, trailing or doubled dots
    private var isValid: Bool {
        cleaned.range(of: #"^(?!\.)(?!.*\.\.)(?!.*\.$)[a-z0-9_.]{3,20}$"#, options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Friends find you by your username, and you find them by theirs.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                HStack(spacing: 4) {
                    Text("@")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.accentGradient)
                    TextField("username", text: $handle)
                        .font(.title3.weight(.semibold))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                }
                .padding(16)
                .cardStyle(cornerRadius: 14)
                Text(errorMessage ?? "3 to 20 letters, numbers, underscores or dots.")
                    .font(.caption)
                    .foregroundColor(errorMessage == nil ? Theme.textTertiary : Theme.accentSecondary)
                Text("People who follow you can see your lists, rankings, watched films and notes.")
                    .font(.caption)
                    .foregroundColor(Theme.textTertiary)
                Spacer()
            }
            .padding(20)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(social.profile?.handle == nil ? "Choose a Username" : "Change Username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(social.profile?.handle == nil ? "Not Now" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .bold()
                            .disabled(!isValid || cleaned == social.profile?.handle)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            handle = social.profile?.handle ?? ""
            focused = true
        }
        .onChange(of: handle) { _ in errorMessage = nil }
    }

    private func save() {
        guard isValid else { return }
        isSaving = true
        social.setHandle(cleaned) { message in
            isSaving = false
            if let message {
                errorMessage = message
            } else {
                Haptics.success()
                dismiss()
            }
        }
    }
}

// MARK: - Following (on the Profile tab)

struct FollowingSection: View {
    @ObservedObject private var social = SocialStore.shared
    @State private var showUsernameSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Following")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if social.profile?.handle != nil {
                    NavigationLink {
                        FindPeopleView()
                    } label: {
                        Label("Find People", systemImage: "person.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentGradient)
                    }
                }
            }
            if social.hasLoaded && social.profile?.handle == nil {
                Button {
                    Haptics.tap()
                    showUsernameSetup = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "at")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.accentGradient)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose a username")
                                .font(.headline)
                                .foregroundColor(Theme.textPrimary)
                            Text("You need one to find and follow friends.")
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(14)
                    .cardStyle(cornerRadius: 16)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.98))
            } else if social.following.isEmpty {
                Text("Follow friends to see their lists, rankings and what they thought of each film.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            } else {
                ForEach(social.following) { person in
                    NavigationLink {
                        FriendProfileView(person: person)
                    } label: {
                        PersonRow(person: person, showsFollowButton: false)
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.98))
                }
            }
        }
        .sheet(isPresented: $showUsernameSetup) {
            UsernameSetupView()
        }
    }
}

/// A person with their @username, and optionally a Follow button
struct PersonRow: View {
    @ObservedObject private var social = SocialStore.shared
    let person: UserSummary
    var showsFollowButton = true

    private var detail: String {
        if let lists = person.list_count, let films = person.film_count {
            return "@\(person.handle) · \(lists) \(lists == 1 ? "list" : "lists") · \(films) films"
        }
        return "@\(person.handle)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: person.display_name)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.display_name)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if showsFollowButton {
                FollowButton(person: person)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(12)
        .cardStyle(cornerRadius: 16)
    }
}

struct FollowButton: View {
    @ObservedObject private var social = SocialStore.shared
    let person: UserSummary

    var body: some View {
        let following = social.isFollowing(person.handle)
        Button {
            Haptics.tap()
            social.setFollowing(person, !following)
        } label: {
            Text(following ? "Following" : "Follow")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(following ? Theme.textPrimary : Theme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(following ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(Theme.accentGradient))
                .clipShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
    }
}

/// The first letter of someone's name in a circle
struct Avatar: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Text(String(name.first ?? "?").uppercased())
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundColor(Theme.onAccent)
            .frame(width: size, height: size)
            .background(Theme.accentGradient)
            .clipShape(Circle())
    }
}

// MARK: - Find people

struct FindPeopleView: View {
    @State private var query = ""
    @State private var results: [UserSummary] = []
    @State private var isSearching = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if query.count < 2 {
                    Text("Search for a friend by their @username.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 40)
                } else if results.isEmpty && !isSearching {
                    Text("No one with a username starting with \"\(query)\".")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 40)
                }
                ForEach(results) { person in
                    NavigationLink {
                        FriendProfileView(person: person)
                    } label: {
                        PersonRow(person: person)
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.98))
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Find People")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "@username")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        // Search as the user types, after a short pause
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
            guard trimmed.count >= 2 else {
                results = []
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            APIService.shared.searchUsers(trimmed) { result in
                isSearching = false
                if case .success(let people) = result { results = people }
            }
        }
    }
}

// MARK: - A person's profile and lists

struct FriendProfileView: View {
    @ObservedObject private var social = SocialStore.shared
    let person: UserSummary
    @State private var lists: FriendLists? = nil
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Avatar(name: person.display_name, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.display_name)
                            .font(.title2.weight(.heavy))
                            .foregroundColor(Theme.textPrimary)
                        Text("@\(person.handle)")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    FollowButton(person: person)
                }

                if !social.isFollowing(person.handle) {
                    Text("Follow \(person.display_name) to see their lists, rankings and watched films.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                } else if let lists {
                    if lists.lists.isEmpty {
                        Text("No lists yet.")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    }
                    ForEach(lists.lists) { list in
                        NavigationLink {
                            FriendListView(list: list, owner: person.display_name)
                        } label: {
                            friendListCard(list)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.98))
                    }
                } else if loadFailed {
                    Text("Couldn't load their lists.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("@\(person.handle)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: social.isFollowing(person.handle)) { _ in load() }
    }

    private func load() {
        guard social.isFollowing(person.handle) else { return }
        loadFailed = false
        APIService.shared.fetchFriendLists(person.handle) { result in
            switch result {
            case .success(let loaded): lists = loaded
            case .failure: loadFailed = true
            }
        }
    }

    private func friendListCard(_ list: FriendLists.List) -> some View {
        HStack(spacing: 14) {
            ZStack {
                ForEach(Array(list.movies.prefix(3).enumerated().reversed()), id: \.offset) { index, film in
                    PosterImage(path: film.poster_path, cornerRadius: 6, size: .small)
                        .frame(width: 44, height: 66)
                        .offset(x: CGFloat(index) * 10)
                }
            }
            .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(list.movies.count) films · \(list.movies.filter(\.watched).count) watched")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(Theme.textTertiary)
        }
        .padding(12)
        .cardStyle(cornerRadius: 16)
    }
}

/// A friend's list, read-only: their ranking and which films they've watched
struct FriendListView: View {
    let list: FriendLists.List
    let owner: String

    var body: some View {
        List {
            if !list.overview.isEmpty {
                Text(list.overview)
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(list.movies) { film in
                HStack(spacing: 12) {
                    Text("\(film.rank)")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(film.rank <= 3 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                        .frame(width: 40)
                        .minimumScaleFactor(0.5)
                    PosterImage(path: film.poster_path, cornerRadius: 6, size: .small)
                        .frame(width: 40, height: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(film.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                        Text(Theme.year(from: film.release_date))
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    if film.watched {
                        Image(systemName: "eye.fill")
                            .foregroundColor(Theme.accent)
                            .accessibilityLabel("\(owner) has watched this")
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(list.name)
    }
}

// MARK: - Friends on a film (info screen)

/// What the people the user follows think of this film: their note, whether they've watched it, and
/// where they ranked it. Shown only when at least one of them has it
struct FriendTakesSection: View {
    let takes: [FriendTake]

    var body: some View {
        Group {
            if !takes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Friends", systemImage: "person.2.fill")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    ForEach(takes) { take in
                        HStack(alignment: .top, spacing: 12) {
                            Avatar(name: take.display_name, size: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(take.display_name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(Theme.textPrimary)
                                    if take.watched {
                                        Label("Watched", systemImage: "eye.fill")
                                            .labelStyle(.titleAndIcon)
                                            .font(.caption2.weight(.bold))
                                            .foregroundColor(Theme.accent)
                                    } else {
                                        Text("Not watched yet")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(Theme.textTertiary)
                                    }
                                }
                                if let ranking = take.ranking {
                                    Text("#\(ranking.rank) of \(ranking.list_size) in \(ranking.list_name)")
                                        .font(.caption)
                                        .foregroundColor(Theme.textSecondary)
                                }
                                if let note = take.note {
                                    Text("\u{201C}\(note)\u{201D}")
                                        .font(.subheadline)
                                        .foregroundColor(Theme.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
                .transition(.opacity)
            }
        }
    }
}
