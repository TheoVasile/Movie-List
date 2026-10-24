//
//  ReviewPrompter.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-24.
//

import Foundation
import SwiftUI
import StoreKit

/// Asks for an App Store rating, only just after something went well: the 10th and 50th head-to-head ranking, the
/// last Year in Review slide, a finished import. Never in the first 3 days, before the 3rd time the app is opened,
/// or within 120 days of the last ask (iOS also shows it at most 3 times a year). The counts are kept per device,
/// not per account, so deleting the account leaves them
enum ReviewPrompter {
    enum Trigger: String { case ranking, yearInReview = "year_in_review", importCompleted = "import" }

    private static let firstSessionKey = "reviewPrompt.firstSession"
    private static let lastSessionKey = "reviewPrompt.lastSession"
    private static let sessionsKey = "reviewPrompt.sessions"
    private static let rankingsKey = "reviewPrompt.rankings"
    private static let lastAskedKey = "reviewPrompt.lastAsked"

    private static let day: TimeInterval = 24 * 60 * 60
    // Coming back within half an hour is still the same session
    private static let sessionGap: TimeInterval = 30 * 60

    /// Called whenever the app comes to the front
    static func recordSession() {
        let defaults = UserDefaults.standard
        let now = Date()
        if defaults.object(forKey: firstSessionKey) == nil { defaults.set(now, forKey: firstSessionKey) }
        if let last = defaults.object(forKey: lastSessionKey) as? Date, now.timeIntervalSince(last) < sessionGap {
            defaults.set(now, forKey: lastSessionKey)
            return
        }
        defaults.set(now, forKey: lastSessionKey)
        defaults.set(defaults.integer(forKey: sessionsKey) + 1, forKey: sessionsKey)
    }

    /// Counts a finished head-to-head ranking, and asks on the 10th and the 50th
    static func rankingFinished(_ requestReview: RequestReviewAction) {
        let defaults = UserDefaults.standard
        let rankings = defaults.integer(forKey: rankingsKey) + 1
        defaults.set(rankings, forKey: rankingsKey)
        if rankings == 10 || rankings == 50 { ask(requestReview, after: .ranking) }
    }

    /// Asks after a moment, so whatever just finished has settled, if the rules above allow it
    static func ask(_ requestReview: RequestReviewAction, after trigger: Trigger) {
        // Not while the Terms or username screen is still to come
        guard let profile = SocialStore.shared.profile, !profile.needsTermsAcceptance, profile.handle != nil else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        guard let first = defaults.object(forKey: firstSessionKey) as? Date, now.timeIntervalSince(first) >= 3 * day,
              defaults.integer(forKey: sessionsKey) >= 3 else { return }
        if let last = defaults.object(forKey: lastAskedKey) as? Date, now.timeIntervalSince(last) < 120 * day { return }
        defaults.set(now, forKey: lastAskedKey)
        AppAnalytics.log(.reviewPromptShown(trigger))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            requestReview()
        }
    }
}
