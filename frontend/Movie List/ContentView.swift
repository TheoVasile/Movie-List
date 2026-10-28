//
//  ContentView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-07.
//

import Foundation
import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @EnvironmentObject var network: NetworkService
    @EnvironmentObject var db: DatabaseService
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @State var showingPopup = false
    @AppStorage(Personalization.aiAllowedKey) private var aiAllowed = false
    @AppStorage(Personalization.useAIKey) private var useAI = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared
    @AppStorage(Personalization.birthdayKey) private var birthday = ""
    @ObservedObject private var social = SocialStore.shared
    // What has to be done before using the app, one at a time. First, agreeing to the current Terms of
    // Service, whenever the agreed version isn't the current one. Then an @username, which is how people
    // know each other here: accounts without one (Google sign-ins, accounts from before usernames, or a
    // sign-up whose username was taken) pick one before going on. Nothing is asked until the profile has
    // loaded, so a server that can't be reached doesn't lock anyone out, and a request that failed is never
    // taken to mean the account has no username
    private var gate: Binding<Gate?> {
        Binding(get: {
            guard social.hasLoaded, let profile = social.profile else { return nil }
            if profile.needsTermsAcceptance { return .terms }
            return profile.handle == nil ? .username : nil
        }, set: { _ in })
    }

    // One cover that switches between them, so finishing one can't collide with presenting the next
    enum Gate: Identifiable {
        case terms, username
        var id: Self { self }
    }
    @State private var tab = Tab.lists
    @ObservedObject private var notifications = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    enum Tab { case lists, discover, profile }
    // A film opened from a Home Screen widget or a shared link
    @State private var linkedMovie: CDMovie? = nil
    // Opened from shared links (see LinkRouter): a person's profile, a list (the user's own, or someone else's
    // read-only), and a group invite to join. linkLoading covers the screen while one is fetched
    @ObservedObject private var links = LinkRouter.shared
    @State private var linkedPerson: UserSummary? = nil
    @State private var linkedList: LinkedListSheet? = nil
    @State private var joinInvite: JoinInvite? = nil
    @State private var linkLoading = false
    @State private var linkError: String? = nil

    struct LinkedListSheet: Identifiable {
        let id = UUID()
        let own: CDMovieList?
        let other: FriendLists.List?
    }

    struct JoinInvite: Identifiable {
        let token: String
        var id: String { token }
    }

    /// Whether links can be opened: signed in, with an @username and the current terms accepted
    private var readyForLinks: Bool {
        guard social.hasLoaded, let profile = social.profile else { return false }
        return profile.handle != nil && !profile.needsTermsAcceptance
    }
    // The theatre the user just left, from a check-in notification, while they say what they saw there
    @State private var theatreVisit: TheatreVisit? = nil

    struct TheatreVisit: Identifiable {
        let theatre: String
        let id = UUID()
    }

    // Sparkles mark Discover as AI-powered, so they only show while AI Picks is the chosen source
    private var discoverIcon: String {
        aiAllowed && useAI && Personalization.ageRange(birthday: birthday, legacy: ageRange) != Personalization.under18 ? "sparkles" : "rectangle.on.rectangle.angled"
    }
    
    var body: some View {
        TabView(selection: $tab) {
            Home()
                .environmentObject(viewModel)
                .environmentObject(network)
                .environmentObject(db)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .tabItem {
                    Label("Lists", systemImage: "film.stack")
                }
                .tag(Tab.lists)
                .toolbarBackground(Theme.background.opacity(0.92), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            DiscoverView()
                .environmentObject(viewModel)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .tabItem {
                    Label("Discover", systemImage: discoverIcon)
                }
                .tag(Tab.discover)
                .toolbarBackground(Theme.background.opacity(0.92), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            UserProfileView()
                .environmentObject(viewModel)
                .environmentObject(network)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                }
                // Follow requests waiting to be answered, and films friends sent that haven't been looked at
                .badge(social.requests.count + (social.profile?.recommendations_unseen ?? 0))
                .tag(Tab.profile)
                .toolbarBackground(Theme.background.opacity(0.92), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
        .onAppear {
            ReviewPrompter.recordSession()
            social.load()
            notifications.registerDevice()
            // Asked once, shortly after the user first gets into the app
            if notifications.authorization == .notDetermined {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if notifications.authorization == .notDetermined {
                        notifications.requestPermission()
                    }
                }
            }
            // The server keeps whether AI is allowed, for friends' Movie Nights. Sent at launch too, so it's
            // right for settings chosen before the server kept it
            Personalization.syncAIAllowed()
        }
        // Coming back to the app is a good moment to try again, e.g. once the network is back
        .onChange(of: scenePhase) { phase in
            if phase == .active { ReviewPrompter.recordSession() }
            if phase == .active && social.profileFailed { social.retry() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if social.profileFailed {
                // Still usable without it (lists are saved on the phone); it keeps trying in the background
                Button {
                    Haptics.tap()
                    social.retry()
                } label: {
                    Label("Couldn't load your profile · Retry", systemImage: "wifi.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.surfaceRaised, in: Capsule())
                        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Theme.background)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: social.profileFailed)
        .onChange(of: aiAllowed) { _ in Personalization.syncAIAllowed() }
        .onChange(of: ageRange) { _ in Personalization.syncAIAllowed() }
        .onChange(of: birthday) { _ in Personalization.syncAIAllowed() }
        .fullScreenCover(item: gate) { gate in
            switch gate {
            case .terms:
                TermsAcceptanceView { viewModel.signOut() }
            case .username:
                UsernameSetupView(required: true) { viewModel.signOut() }
            }
        }
        .sheet(item: $linkedMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .sheet(item: $linkedPerson) { person in
            NavigationStack {
                FriendProfileView(person: person)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { linkedPerson = nil }
                        }
                    }
            }
            .environmentObject(viewModel)
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
        .sheet(item: $linkedList) { sheet in
            NavigationStack {
                Group {
                    if let own = sheet.own {
                        ListView(movieList: own, context: PersistenceController.shared.container.viewContext)
                    } else if let other = sheet.other {
                        FriendListView(list: other, owner: other.owner_handle.map { "@\($0)" } ?? "")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { linkedList = nil }
                    }
                }
            }
            .environmentObject(viewModel)
            .environmentObject(network)
            .environmentObject(db)
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
        // However it closes, the saved invite has been seen, so it isn't shown again at the next launch
        .sheet(item: $joinInvite, onDismiss: { LinkRouter.shared.finishInvite() }) { invite in
            JoinGroupSheet(token: invite.token) { groupID in
                // Opens the group once this sheet has closed
                tab = .profile
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { notifications.openGroupID = groupID }
            }
        }
        .overlay {
            if linkLoading { LinkLoadingOverlay() }
        }
        .alert("Couldn't open that link", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
        .onAppear(perform: openPendingLink)
        .onChange(of: links.pending) { _ in openPendingLink() }
        .onChange(of: readyForLinks) { _ in openPendingLink() }
        .sheet(item: $theatreVisit) { visit in
            TheatreCheckInSheet(theatre: visit.theatre)
                .environmentObject(viewModel)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
        .onChange(of: notifications.destination) { destination in
            switch destination {
            case .profile:
                tab = .profile
            case .group(let id):
                tab = .profile
                notifications.openGroupID = id
            case .lists:
                tab = .lists
            case .film(let tmdbID):
                open(.film(tmdbID: tmdbID))
            case .theatreVisit(let theatre):
                theatreVisit = TheatreVisit(theatre: theatre)
            case nil:
                break
            }
            notifications.destination = nil
        }
    }

    /// Opens the link waiting in LinkRouter, once the app is ready for it
    private func openPendingLink() {
        guard readyForLinks, !linkLoading, let link = links.take() else { return }
        open(link)
    }

    /// Opens what a link points to: a film's info, a person's profile, a list, or a group invite
    private func open(_ link: DeepLink) {
        switch link {
        case .film(let tmdbID):
            let request = CDMovie.fetchRequest()
            request.predicate = NSPredicate(format: "tmdb_id == %d", Int32(clamping: tmdbID))
            request.fetchLimit = 1
            if let saved = try? PersistenceController.shared.container.viewContext.fetch(request).first {
                linkedMovie = saved
                return
            }
            // Not in the user's lists: fetched, and shown from a copy that isn't saved
            linkLoading = true
            APIService.shared.fetchFilm(tmdbID: tmdbID) { result in
                linkLoading = false
                switch result {
                case .success(let film): linkedMovie = PersistenceController.preview(of: film.movie)
                case .failure: linkError = "That film couldn't be found. Check your connection and try again."
                }
            }
        case .profile(let handle), .personalInvite(let handle):
            if handle == social.profile?.handle {
                tab = .profile
                return
            }
            linkLoading = true
            APIService.shared.fetchFriendLists(handle) { result in
                linkLoading = false
                switch result {
                case .success(let person):
                    linkedPerson = UserSummary(handle: person.handle, display_name: person.display_name, following: person.following,
                                               list_count: nil, film_count: nil, avatar_version: person.avatar_version)
                case .failure:
                    linkError = "@\(handle) couldn't be found."
                }
            }
        case .list(let publicID):
            linkLoading = true
            APIService.shared.openListLink(publicID: publicID) { result in
                linkLoading = false
                switch result {
                case .success(let linked) where linked.mine:
                    let request = CDMovieList.fetch(predicate: NSPredicate(format: "id == %lld", linked.id))
                    request.fetchLimit = 1
                    if let own = try? PersistenceController.shared.container.viewContext.fetch(request).first {
                        tab = .lists
                        linkedList = LinkedListSheet(own: own, other: nil)
                    } else {
                        linkError = "That list hasn't reached this iPhone yet. Try again in a moment."
                    }
                case .success(let linked):
                    if let list = linked.list {
                        linkedList = LinkedListSheet(own: nil, other: list)
                    } else {
                        linkError = "That list is private or no longer exists."
                    }
                case .failure(let error):
                    linkError = (error as NSError).code == 404
                        ? "That list is private or no longer exists."
                        : "Check your connection and try again."
                }
            }
        case .groupInvite(let token):
            joinInvite = JoinInvite(token: token)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(NetworkService())
            .environmentObject(DatabaseService())
            .environmentObject(AuthenticationViewModel())
    }
}
