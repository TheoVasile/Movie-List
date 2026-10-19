//
//  NotificationManager.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import SwiftUI
import UserNotifications
import FirebaseAuth
import FirebaseMessaging

/// Push notifications: asks for permission, keeps the server told which device to send to (a Firebase
/// Cloud Messaging token), shows notifications that arrive while the app is open, and opens the right
/// screen when one is tapped
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    /// Where a tapped notification should take the user
    enum Destination: Equatable {
        case profile
        case film(tmdbID: Int64)
    }

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published var destination: Destination? = nil

    private var fcmToken: String?

    /// Called once at launch, after Firebase is configured
    func configure(_ application: UIApplication) {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        application.registerForRemoteNotifications()
        refreshAuthorization()
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { self.authorization = settings.authorizationStatus }
        }
    }

    /// Shows the system prompt the first time; afterwards iOS only lets the user change it in Settings
    func requestPermission(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.refreshAuthorization()
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                completion?(granted)
            }
        }
    }

    /// Tells the server this device belongs to the signed-in user, so their notifications come here
    func registerDevice() {
        guard Auth.auth().currentUser != nil else { return }
        if let fcmToken {
            APIService.shared.registerDevice(token: fcmToken)
        } else {
            // A token deleted at sign-out is replaced the next time one is asked for
            Messaging.messaging().token { token, _ in
                guard let token else { return }
                self.fcmToken = token
                APIService.shared.registerDevice(token: token)
            }
        }
    }

    /// Stops this device getting the account's notifications. Called just before signing out, while the
    /// request can still be signed in; the token is also deleted, so it stops working even if that fails
    func unregisterDevice() {
        if let fcmToken {
            APIService.shared.unregisterDevice(token: fcmToken)
        }
        fcmToken = nil
        Messaging.messaging().deleteToken { _ in }
    }
}

extension NotificationManager: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        DispatchQueue.main.async {
            self.fcmToken = fcmToken
            self.registerDevice()
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    // Shown as a banner even while the app is open
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.userInfo["type"] as? String == "follow_request" {
            DispatchQueue.main.async { SocialStore.shared.load() }
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            switch info["type"] as? String {
            case "follow_request", "follow_accepted", "activity":
                SocialStore.shared.load()
                self.destination = .profile
            default:
                if let id = (info["tmdb_id"] as? String).flatMap(Int64.init) ?? (info["tmdb_id"] as? Int64) {
                    self.destination = .film(tmdbID: id)
                }
            }
            completionHandler()
        }
    }
}
