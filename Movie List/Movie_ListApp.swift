//
//  Movie_ListApp.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-07.
//

import Foundation
import SwiftUI
import FirebaseCore
import GoogleSignIn
import GoogleSignInSwift

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    FirebaseApp.configure()

    return true
    }
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}

@main
struct Movie_ListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var network = NetworkService()
    @StateObject private var db = DatabaseService()
    let persistenceController = PersistenceController.shared
    
    var body: some Scene {
        WindowGroup {
            AuthenticatedView {
                Image(systemName: "number.circle.fill")
                    .resizable()
                    .frame(width: 100 , height: 100)
                    .foregroundColor(Color(.systemPink))
                    .aspectRatio(contentMode: .fit)
                    .clipShape(Circle())
                    .clipped()
                    .padding(4)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                  Text("Welcome to CineList!")
                    .font(.title)
                  Text("You need to be logged in to use this app.")
            } content: {
                ContentView()
                    .environmentObject(network)
                    .environmentObject(db)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
            }
        }
    }
}
