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
    
    var body: some View {
        TabView {
            Home()
                .environmentObject(viewModel)
                .environmentObject(network)
                .environmentObject(db)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
            UserProfileView()
                .environmentObject(viewModel)
                .environmentObject(network)
                .tabItem {
                    Label("Account", systemImage: "person.fill")
                }
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
