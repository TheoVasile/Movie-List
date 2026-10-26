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
        case group(id: Int64)
        case lists
        case film(tmdbID: Int64)
        // Asks which film was just seen at this theatre
        case theatreVisit(theatre: String)
    }

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published var destination: Destination? = nil
    // A movie night group to open once Profile is showing, from a vote notification
    @Published var openGroupID: Int64? = nil

    // Film suggestions are scheduled on this phone, so the switch for them is kept here too
    static let suggestionsKey = "notify.suggestions"
    private static let suggestionPrefix = "suggestion-"
    // Tuesday, Friday and Sunday evenings (weekday 1 is Sunday)
    private static let suggestionDays: [(weekday: Int, title: String)] = [(3, "Movie night?"), (6, "Friday film?"), (1, "Sunday film?")]
    private static let suggestionHour = 19

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

    var suggestionsEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.suggestionsKey) as? Bool ?? true
    }

    /// Replaces the scheduled film suggestions with fresh ones: the next Tuesday, Friday and Sunday evening,
    /// each a different unwatched film from the watchlist (or from any list without one). Called after each
    /// sync, so the picks follow the lists. Scheduled on the phone, so nothing is sent anywhere
    func scheduleSuggestions() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.suggestionPrefix) })
            DispatchQueue.main.async {
                guard self.suggestionsEnabled, [.authorized, .provisional, .ephemeral].contains(self.authorization) else { return }
                let candidates = PersistenceController.shared.suggestionCandidates()
                guard !candidates.isEmpty else { return }
                let calendar = Calendar.current
                let now = Date()
                for (index, day) in Self.suggestionDays.enumerated() {
                    guard let date = calendar.nextDate(after: now, matching: DateComponents(hour: Self.suggestionHour, weekday: day.weekday),
                                                       matchingPolicy: .nextTime) else { continue }
                    // A different film each evening, and different ones from week to week
                    let week = calendar.component(.weekOfYear, from: date)
                    let pick = candidates[(week * Self.suggestionDays.count + index) % candidates.count]
                    let content = UNMutableNotificationContent()
                    content.title = day.title
                    content.body = pick.fromWatchlist
                        ? "How about \(pick.label)? It's on your watchlist."
                        : "How about \(pick.label)? You haven't watched it yet."
                    content.sound = .default
                    content.userInfo = ["type": "suggestion", "tmdb_id": String(pick.tmdbID)]
                    let trigger = UNCalendarNotificationTrigger(
                        dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
                    center.add(UNNotificationRequest(identifier: Self.suggestionPrefix + String(day.weekday), content: content, trigger: trigger))
                }
            }
        }
    }

    func cancelSuggestions() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.suggestionPrefix) })
        }
    }

    /// Shows the system prompt the first time; afterwards iOS only lets the user change it in Settings
    func requestPermission(completion: ((Bool) -> Void)? = nil) {
        // Logged only when the system prompt is actually shown
        let firstAsk = authorization == .notDetermined
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if firstAsk { AppAnalytics.log(.pushPermission(granted: granted)) }
                self.refreshAuthorization()
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                    // authorization is refreshed asynchronously, so give it a moment before scheduling
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scheduleSuggestions() }
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
        cancelSuggestions()
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
        switch notification.request.content.userInfo["type"] as? String {
        case "follow_request", "recommendation":
            DispatchQueue.main.async { SocialStore.shared.load() }
        case "list_invite":
            // The new shared list shows up straight away
            DispatchQueue.main.async { ListSharing.shared.refresh() }
        default:
            break
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            switch info["type"] as? String {
            case "follow_request", "follow_accepted", "follow_new", "activity", "recommendation":
                SocialStore.shared.load()
                self.destination = .profile
            case "poll_started", "poll_result", "group_added", "group_suggestion":
                if let id = (info["group_id"] as? String).flatMap(Int64.init) {
                    self.destination = .group(id: id)
                }
            case "list_invite":
                ListSharing.shared.refresh()
                self.destination = .lists
            case "theatre_visit":
                self.destination = .theatreVisit(theatre: info["theatre"] as? String ?? "the theatre")
            default:
                if let id = (info["tmdb_id"] as? String).flatMap(Int64.init) ?? (info["tmdb_id"] as? Int64) {
                    self.destination = .film(tmdbID: id)
                }
            }
            completionHandler()
        }
    }
}
