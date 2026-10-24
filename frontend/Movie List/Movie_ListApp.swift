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
import FirebaseAppCheck
import FirebaseMessaging
import FirebaseAuth

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    // App Check's provider has to be chosen before Firebase starts, or the default is used. Debug builds use the
    // debug provider, since the simulator can't attest; release builds keep the default (DeviceCheck)
    #if DEBUG
    AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
    #endif
    FirebaseApp.configure()
    // Usage analytics are on unless turned off in Settings
    AppAnalytics.applySetting()
    Personalization.migrateGenderToPronouns()
    Personalization.migrateAIConsent()

    NotificationManager.shared.configure(application)
    // Region events relaunch the app in the background, so the location manager has to be ready at launch
    TheatreCheckIns.shared.configure()
    return true
    }

    // Firebase needs Apple's push token to turn it into its own
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        // Firebase also uses it to check a phone number is being verified from this app, without a reCAPTCHA
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
    }

    // Firebase's silent notification for phone verification
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if Auth.auth().canHandleNotification(userInfo) {
            completionHandler(.noData)
            return
        }
        completionHandler(.newData)
    }
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if Auth.auth().canHandle(url) { return true }
        return GIDSignIn.sharedInstance.handle(url)
    }
}

@main
struct Movie_ListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var network = NetworkService()
    @StateObject private var db = DatabaseService()
    let persistenceController = PersistenceController.shared
    @ObservedObject private var appearance = AppearanceSettings.shared
    
    var body: some Scene {
        WindowGroup {
            AuthenticatedView {
                WelcomeView()
            } content: {
                ContentView()
                    .environmentObject(network)
                    .environmentObject(db)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    // Colours are fixed once a view is drawn, so a new colour theme builds the app's screens again
                    .id(appearance.colorTheme)
            }
            .tint(Theme.accent)
            // Light or dark is set on the window, so pop-ups and sheets follow it too
            .onAppear { AppearanceSettings.shared.apply() }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @State private var glow = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 120, height: 120)
                    .blur(radius: glow ? 40 : 24)
                    .opacity(glow ? 0.8 : 0.45)
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 96, height: 96)
                    .overlay(Circle().stroke(Theme.accentGradient, lineWidth: 2))
                Image(systemName: "film.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
            }
            .scaleEffect(glow ? 1.04 : 0.98)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    glow = true
                }
            }
            .appearAnimation()

            Text("Marquee")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .appearAnimation(delay: 0.1)
            Text("Rank every film you love.\nHead to head, one pick at a time.")
                .font(.body)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .appearAnimation(delay: 0.2)
        }
    }
}
