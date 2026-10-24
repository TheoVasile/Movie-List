//
//  Analytics.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import FirebaseAnalytics

/// Counts how Marquee is used, with Firebase Analytics (the version without the advertising ID). Only the events
/// below are sent, each with a few fixed values: never titles, names, handles or anything the user typed. The
/// user ID is never set, so events aren't tied to the account
enum AppAnalytics {
    /// Device setting (not per account), on unless the user turns it off in Settings
    static let enabledKey = "analytics.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Applies the Settings choice; called at launch and whenever it changes. Firebase remembers it too
    static func applySetting() {
        Analytics.setAnalyticsCollectionEnabled(isEnabled)
    }

    enum SignUpMethod: String { case email, google, apple }
    enum FilmSource: String {
        case search, discover, otherList = "other_list", friend, recommendation, collection
        case movieNight = "movie_night", checkIn = "check_in"
    }
    enum RankMethod: String { case compare, setRank = "set_rank", drag }
    enum WatchSource: String { case list, diary, checkIn = "check_in" }
    enum AIFeature: String { case discover, movieNight = "movie_night", smartPlacement = "smart_placement" }
    enum ShareFormat: String { case image, export }

    enum Event {
        case signUp(SignUpMethod)
        case termsAccepted
        case listCreated(ranked: Bool)
        case filmAdded(FilmSource)
        case filmRanked(RankMethod)
        case filmWatched(WatchSource)
        case aiPickUsed(AIFeature)
        case recommendationSent(recipients: Int)
        case theatreCheckInOpened
        case reportSubmitted(contentType: String, reason: String)
        case shareList(ShareFormat)

        var name: String {
            switch self {
            case .signUp: return AnalyticsEventSignUp
            case .termsAccepted: return "terms_accepted"
            case .listCreated: return "list_created"
            case .filmAdded: return "film_added"
            case .filmRanked: return "film_ranked"
            case .filmWatched: return "film_watched"
            case .aiPickUsed: return "ai_pick_used"
            case .recommendationSent: return "recommendation_sent"
            case .theatreCheckInOpened: return "theatre_checkin_opened"
            case .reportSubmitted: return "report_submitted"
            case .shareList: return "share_list"
            }
        }

        var parameters: [String: Any]? {
            switch self {
            case .signUp(let method): return [AnalyticsParameterMethod: method.rawValue]
            case .listCreated(let ranked): return ["kind": ranked ? "ranked" : "unranked"]
            case .filmAdded(let source): return ["source": source.rawValue]
            case .filmRanked(let method): return [AnalyticsParameterMethod: method.rawValue]
            case .filmWatched(let source): return ["source": source.rawValue]
            case .aiPickUsed(let feature): return ["feature": feature.rawValue]
            // Capped, so it's a rough size rather than a count of the user's friends
            case .recommendationSent(let recipients): return ["recipients": min(recipients, 10)]
            // The report form's fixed choices (user, list, …; spam, harassment, …), never what was reported
            case .reportSubmitted(let contentType, let reason): return ["content_type": contentType, "reason": reason]
            case .shareList(let format): return ["format": format.rawValue]
            case .termsAccepted, .theatreCheckInOpened: return nil
            }
        }
    }

    static func log(_ event: Event) {
        Analytics.logEvent(event.name, parameters: event.parameters)
    }
}
