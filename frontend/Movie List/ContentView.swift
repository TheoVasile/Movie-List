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
    // A film opened from a Home Screen widget
    @State private var linkedMovie: CDMovie? = nil
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
            // Sends Discover reactions left waiting while offline, and brings in the account's, in the background
            DiscoverReactionSync.shared.sync()
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
        .sheet(item: $theatreVisit) { visit in
            TheatreCheckInSheet(theatre: visit.theatre)
                .environmentObject(viewModel)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
        .onOpenURL(perform: openLink)
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
                if let url = URL(string: "cinelist://film/\(tmdbID)") { openLink(url) }
            case .theatreVisit(let theatre):
                theatreVisit = TheatreVisit(theatre: theatre)
            case nil:
                break
            }
            notifications.destination = nil
        }
    }

    /// Handles cinelist://film/<TMDb id> from the widgets (or marquee://film/<TMDb id>) by opening that film's info screen
    private func openLink(_ url: URL) {
        // The return from Firebase's reCAPTCHA page while verifying a phone number
        if Auth.auth().canHandle(url) { return }
        guard url.scheme == "cinelist" || url.scheme == "marquee", url.host == "film", let tmdbID = Int32(url.lastPathComponent) else { return }
        let request = CDMovie.fetchRequest()
        request.predicate = NSPredicate(format: "tmdb_id == %d", tmdbID)
        request.fetchLimit = 1
        linkedMovie = try? PersistenceController.shared.container.viewContext.fetch(request).first
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
