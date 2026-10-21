//
//  ContentView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-07.
//

import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var network: NetworkService
    @EnvironmentObject var db: DatabaseService
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @State var showingPopup = false
    @AppStorage(Personalization.aiAllowedKey) private var aiAllowed = false
    @AppStorage(Personalization.useAIKey) private var useAI = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared
    @ObservedObject private var social = SocialStore.shared
    // Everyone needs an @username, which is how people know each other here. Accounts without one (Google
    // sign-ins, accounts from before usernames, or a sign-up whose username was taken) pick one before going on
    private var needsUsername: Binding<Bool> {
        Binding(get: { social.hasLoaded && social.profile != nil && social.profile?.handle == nil }, set: { _ in })
    }
    @State private var tab = Tab.lists
    @ObservedObject private var notifications = NotificationManager.shared

    enum Tab { case lists, discover, profile }
    // A film opened from a Home Screen widget
    @State private var linkedMovie: CDMovie? = nil

    // Sparkles mark Discover as AI-powered, so they only show while AI Picks is the chosen source
    private var discoverIcon: String {
        aiAllowed && useAI && ageRange != Personalization.under18 ? "sparkles" : "rectangle.on.rectangle.angled"
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
                // Follow requests waiting to be answered
                .badge(social.requests.count)
                .tag(Tab.profile)
                .toolbarBackground(Theme.background.opacity(0.92), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
        .onAppear {
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
        .onChange(of: aiAllowed) { _ in Personalization.syncAIAllowed() }
        .onChange(of: ageRange) { _ in Personalization.syncAIAllowed() }
        .fullScreenCover(isPresented: needsUsername) {
            UsernameSetupView(required: true) { viewModel.signOut() }
        }
        .sheet(item: $linkedMovie) { movie in
            MovieDetailView(movie: movie)
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
            case nil:
                break
            }
            notifications.destination = nil
        }
    }

    /// Handles cinelist://film/<TMDb id> from the widgets by opening that film's info screen
    private func openLink(_ url: URL) {
        guard url.scheme == "cinelist", url.host == "film", let tmdbID = Int32(url.lastPathComponent) else { return }
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
