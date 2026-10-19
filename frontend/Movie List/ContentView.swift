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
    // Asked once; afterwards the username is set from the Profile tab or Settings
    @AppStorage("social.usernamePromptShown") private var usernamePromptShown = false
    @State private var showUsernameSetup = false

    // Sparkles mark Discover as AI-powered, so they only show while AI Picks is the chosen source
    private var discoverIcon: String {
        aiAllowed && useAI && ageRange != Personalization.under18 ? "sparkles" : "rectangle.on.rectangle.angled"
    }
    
    var body: some View {
        TabView {
            Home()
                .environmentObject(viewModel)
                .environmentObject(network)
                .environmentObject(db)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .tabItem {
                    Label("Lists", systemImage: "film.stack")
                }
                .toolbarBackground(Theme.background.opacity(0.92), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            DiscoverView()
                .environmentObject(viewModel)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .tabItem {
                    Label("Discover", systemImage: discoverIcon)
                }
                .toolbarBackground(Theme.background.opacity(0.92), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            UserProfileView()
                .environmentObject(viewModel)
                .environmentObject(network)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                }
                .toolbarBackground(Theme.background.opacity(0.92), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
        .onAppear {
            social.load()
            // The server keeps whether AI is allowed, for friends' Movie Nights. Sent at launch too, so it's
            // right for settings chosen before the server kept it
            Personalization.syncAIAllowed()
        }
        .onChange(of: aiAllowed) { _ in Personalization.syncAIAllowed() }
        .onChange(of: ageRange) { _ in Personalization.syncAIAllowed() }
        .onChange(of: social.hasLoaded) { loaded in
            if loaded && social.profile != nil && social.profile?.handle == nil && !usernamePromptShown {
                usernamePromptShown = true
                showUsernameSetup = true
            }
        }
        .sheet(isPresented: $showUsernameSetup) {
            UsernameSetupView()
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
