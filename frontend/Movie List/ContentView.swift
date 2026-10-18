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
    @AppStorage(Personalization.useAIKey) private var useAI = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared

    // Sparkles mark Discover as AI-powered, so they only show while AI Picks is the chosen source
    private var discoverIcon: String {
        useAI && ageRange != Personalization.under18 ? "sparkles" : "rectangle.on.rectangle.angled"
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
