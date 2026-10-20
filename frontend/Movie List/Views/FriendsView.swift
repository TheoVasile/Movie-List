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
    // People asking to follow the user, and the @usernames the user is waiting on
    @Published private(set) var requests: [UserSummary] = []
    @Published private(set) var requested: Set<String> = []
    @Published private(set) var hasLoaded = false

    func load() {
        APIService.shared.fetchMyProfile { result in
            if case .success(let profile) = result { self.profile = profile }
            self.hasLoaded = true
        }
        APIService.shared.fetchFollowing { result in
            if case .success(let people) = result { self.following = people }
        }
        APIService.shared.fetchFollowRequests { result in
            if case .success(let loaded) = result {
                self.requests = loaded.incoming
                self.requested = Set(loaded.outgoing)
            }
        }
    }

    /// Accepts or declines someone's request, taking it off the list straight away
    func answer(_ person: UserSummary, accept: Bool) {
        let previous = requests
        requests.removeAll { $0.handle == person.handle }
        APIService.shared.answerFollowRequest(person.handle, accept: accept) { saved in
            if saved {
                self.load()
            } else {
                self.requests = previous
            }
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

    /// Sends a follow request, or unfollows / cancels a request, showing the change straight away and undoing
    /// it if the server says no. Following only starts once they accept
    func setFollowing(_ person: UserSummary, _ follow: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        let previous = (following, requested)
        if follow {
            requested.insert(person.handle)
        } else {
            following.removeAll { $0.handle == person.handle }
            requested.remove(person.handle)
        }
        APIService.shared.setFollowing(person.handle, follow) { result in
            switch result {
            case .success:
                self.load()
                completion(true)
            case .failure(let error):
                print("Error updating follow:", error)
                (self.following, self.requested) = previous
                completion(false)
            }
        }
    }

    func hasRequested(_ handle: String) -> Bool {
        requested.contains(handle)
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
            }
            if !social.requests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Follow Requests")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Theme.textSecondary)
                    ForEach(social.requests) { person in
                        FollowRequestRow(person: person)
                    }
                }
            }
            if social.hasLoaded && social.profile?.handle == nil {
                EmptyView()
            } else if social.following.isEmpty {
                Text("Follow friends to see their lists, rankings and what they thought of each film. They'll get a request to accept.")
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
            Avatar(name: person.display_name, handle: person.handle, version: person.avatar_version)
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

/// Follow, Requested (tap to cancel) or Following (tap to unfollow)
struct FollowButton: View {
    @ObservedObject private var social = SocialStore.shared
    let person: UserSummary

    var body: some View {
        let following = social.isFollowing(person.handle)
        let requested = !following && social.hasRequested(person.handle)
        let active = following || requested
        Button {
            Haptics.tap()
            social.setFollowing(person, !active)
        } label: {
            Text(following ? "Following" : requested ? "Requested" : "Follow")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(active ? Theme.textPrimary : Theme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(active ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(Theme.accentGradient))
                .clipShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
    }
}

/// Someone asking to follow the user, with Accept and Decline
struct FollowRequestRow: View {
    @ObservedObject private var social = SocialStore.shared
    let person: UserSummary

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: person.display_name, handle: person.handle, version: person.avatar_version)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.display_name)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("@\(person.handle) wants to follow you")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Haptics.tap()
                social.answer(person, accept: false)
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceRaised, in: Circle())
            }
            .accessibilityLabel("Decline")
            Button {
                Haptics.tap()
                social.answer(person, accept: true)
            } label: {
                Text("Accept")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.accentGradient, in: Capsule())
            }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .padding(12)
        .cardStyle(cornerRadius: 16)
    }
}

/// The first letter of someone's name in a circle
struct Avatar: View {
    let name: String
    var size: CGFloat = 40
    // Whose profile picture to show (nil for the signed-in user's own) and when it last changed; with no
    // version there's no picture, so the first letter of their name is shown
    var handle: String? = nil
    var version: Double? = nil

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(name.first ?? "?").uppercased())
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.accentGradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: version) {
            guard let version else {
                image = nil
                return
            }
            image = await AvatarStore.shared.image(handle: handle, version: version)
        }
    }
}

/// Profile pictures fetched this session, by person and version, so each is downloaded once
final class AvatarStore {
    static let shared = AvatarStore()
    private let cache = NSCache<NSString, UIImage>()

    @MainActor
    func image(handle: String?, version: Double) async -> UIImage? {
        let key = "\(handle ?? "me")-\(Int64(version))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await withCheckedContinuation { continuation in
            APIService.shared.fetchAvatar(handle: handle, version: version) { continuation.resume(returning: $0) }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Shrinks a photo to a 256-point square from its centre, as a JPEG small enough to upload
    static func profileJPEG(from photo: UIImage) -> Data? {
        let side = min(photo.size.width, photo.size.height)
        guard side > 0 else { return nil }
        let target = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let squared = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let scale = target.width / side
            let drawn = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
            photo.draw(in: CGRect(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
        return squared.jpegData(compressionQuality: 0.8)
    }
}

// MARK: - Find people

/// Someone's followers or the people they follow, as rows that open each person's profile
struct ConnectionsView: View {
    // nil for the signed-in user's own
    let handle: String?
    let followers: Bool
    @State private var people: [UserSummary] = []
    @State private var isLoading = true
    @State private var message: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if isLoading {
                    ProgressView().padding(.top, 40)
                } else if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 40)
                }
                ForEach(people) { person in
                    if person.handle == SocialStore.shared.profile?.handle {
                        PersonRow(person: person, showsFollowButton: false)
                    } else {
                        NavigationLink {
                            FriendProfileView(person: person)
                        } label: {
                            PersonRow(person: person)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.98))
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(followers ? "Followers" : "Following")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .refreshable { load() }
    }

    private func load() {
        APIService.shared.fetchConnections(handle: handle, followers: followers) { result in
            isLoading = false
            switch result {
            case .success(let loaded):
                people = loaded
                message = loaded.isEmpty ? (followers ? "No followers yet." : "Not following anyone yet.") : nil
            case .failure(let error):
                message = (error as NSError).code == 403
                    ? "Follow them to see who they follow and who follows them."
                    : "Couldn't load this list. Pull down to try again."
            }
        }
    }
}

/// "12 followers · 30 following", each opening that list
struct ConnectionCounts: View {
    let handle: String?
    let followers: Int
    let following: Int

    var body: some View {
        HStack(spacing: 6) {
            NavigationLink {
                ConnectionsView(handle: handle, followers: true)
            } label: {
                Text("\(followers) \(followers == 1 ? "follower" : "followers")")
            }
            Text("·")
            NavigationLink {
                ConnectionsView(handle: handle, followers: false)
            } label: {
                Text("\(following) following")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(Theme.textTertiary)
    }
}

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
    @State private var showMovieNight = false
    @AppStorage(Personalization.aiAllowedKey) private var aiAllowed = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Avatar(name: person.display_name, size: 64, handle: person.handle,
                           version: lists?.avatar_version ?? person.avatar_version)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.display_name)
                            .font(.title2.weight(.heavy))
                            .foregroundColor(Theme.textPrimary)
                        Text("@\(person.handle)")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                        // Only followers can open these lists
                        if social.isFollowing(person.handle), let lists, let followers = lists.follower_count,
                           let following = lists.following_count {
                            ConnectionCounts(handle: person.handle, followers: followers, following: following)
                        }
                    }
                    Spacer()
                    FollowButton(person: person)
                }

                if social.hasRequested(person.handle) && !social.isFollowing(person.handle) {
                    Text("Request sent. You'll see \(person.display_name)'s lists, rankings and watched films once they accept.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                } else if !social.isFollowing(person.handle) {
                    Text("Follow \(person.display_name) to see their lists, rankings and watched films. They'll get a request to accept.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                } else if let lists {
                    movieNightButton(friendAllowsAI: lists.ai_allowed ?? false)
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

                // Lists they've made public can be seen and followed without following them
                if !social.isFollowing(person.handle), let lists, !lists.lists.isEmpty {
                    Text("Public Lists")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                        .padding(.top, 6)
                    ForEach(lists.lists) { list in
                        NavigationLink {
                            FriendListView(list: list, owner: person.display_name)
                        } label: {
                            friendListCard(list)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.98))
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("@\(person.handle)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMovieNight) {
            MovieNightView(person: person, canUseAI: aiAllowed && ageRange != Personalization.under18 && (lists?.ai_allowed ?? false))
        }
        .onAppear(perform: load)
        .onChange(of: social.isFollowing(person.handle)) { _ in load() }
    }

    // Always available to people who follow each other. AI Picks need both of them to allow AI features;
    // otherwise it uses Classic recommendations
    @ViewBuilder
    private func movieNightButton(friendAllowsAI: Bool) -> some View {
        let iAllowAI = aiAllowed && ageRange != Personalization.under18
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Haptics.tap()
                showMovieNight = true
            } label: {
                Label("Plan a Movie Night", systemImage: "ticket.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            if !iAllowAI {
                Text("Uses Classic recommendations. Allow AI features in Settings for AI Picks.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            } else if !friendAllowsAI {
                Text("Uses Classic recommendations, since \(person.display_name) hasn't allowed AI features.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private func load() {
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
    // nil until loaded from the list, then whatever the user last chose
    @State private var followed: Bool? = nil
    @State private var saving = false

    private var isFollowed: Bool { followed ?? list.followed ?? false }

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
        .toolbar {
            // Following a list adds films added to it to the daily digest
            if list.owner_handle != SocialStore.shared.profile?.handle {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        toggleFollow()
                    } label: {
                        Label(isFollowed ? "Following" : "Follow List", systemImage: isFollowed ? "bell.fill" : "bell")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(saving)
                    .accessibilityHint("Get updates in your daily digest when films are added")
                }
            }
        }
    }

    private func toggleFollow() {
        Haptics.tap()
        let wanted = !isFollowed
        followed = wanted
        saving = true
        APIService.shared.setListFollowed(list.id, wanted) { saved in
            saving = false
            if saved {
                FollowedListsStore.shared.load()
            } else {
                followed = !wanted
            }
        }
    }
}

/// Other people's lists the user follows, shared by the screens that show them
final class FollowedListsStore: ObservableObject {
    static let shared = FollowedListsStore()
    @Published private(set) var lists: [FriendLists.List] = []

    func load() {
        APIService.shared.fetchFollowedLists { result in
            if case .success(let loaded) = result { self.lists = loaded }
        }
    }
}

/// "Lists You Follow" on Profile
struct FollowedListsSection: View {
    @ObservedObject private var store = FollowedListsStore.shared

    var body: some View {
        Group {
            if !store.lists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Lists You Follow")
                        .font(.title3.weight(.bold))
                        .foregroundColor(Theme.textPrimary)
                    ForEach(store.lists) { list in
                        NavigationLink {
                            FriendListView(list: list, owner: list.owner_name ?? "")
                        } label: {
                            HStack(spacing: 12) {
                                PosterImage(path: list.movies.first?.poster_path, cornerRadius: 6, size: .small)
                                    .frame(width: 40, height: 60)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.name)
                                        .font(.headline)
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text("by \(list.owner_name ?? "someone") · \(list.movies.count) films")
                                        .font(.caption)
                                        .foregroundColor(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .padding(12)
                            .cardStyle(cornerRadius: 16)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.98))
                    }
                }
            }
        }
        .onAppear { store.load() }
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
                            Avatar(name: take.display_name, size: 34, handle: take.handle, version: take.avatar_version)
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
