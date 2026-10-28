//
//  Analytics.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import CoreData
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
        case movieNight = "movie_night", checkIn = "check_in", moreLikeThis = "more_like_this"
    }
    enum RankMethod: String { case compare, setRank = "set_rank", drag }
    enum WatchSource: String { case list, diary, checkIn = "check_in" }
    enum AIFeature: String { case discover, movieNight = "movie_night", smartPlacement = "smart_placement" }
    enum ShareFormat: String { case image, export }
    enum ShareKind: String { case listImage = "list_image", yearInReview = "year_in_review", stats, export, milestone }
    enum ImportSource: String { case letterboxd, excel, csv }

    enum Event {
        case signUp(SignUpMethod)
        case termsAccepted
        case listCreated(ranked: Bool)
        case filmAdded(FilmSource)
        case filmRanked(RankMethod)
        case filmWatched(WatchSource)
        case aiPickUsed(AIFeature)
        // A Discover card added to a list, marked Not for Me or skipped, and whether AI Picks was choosing the cards.
        // With the film's TMDb id, why it was recommended (seed, taste, explore, friend, trending, ai or unknown) and
        // where in the session's deck it was dealt
        case discoverSwipe(DiscoverReaction, ai: Bool, tmdbID: Int64, source: String, position: Int)
        // A Discover card reaching the top of the deck, with the same details
        case discoverImpression(tmdbID: Int64, source: String, position: Int, ai: Bool)
        case recommendationSent(recipients: Int)
        case theatreCheckInOpened
        case moreLikeThisOpened
        case reportSubmitted(contentType: String, reason: String)
        case shareList(ShareFormat)
        // Once per device, alongside the first list_created and film_ranked, for the sign-up funnel
        case firstListCreated
        case firstRanking
        case signIn(SignUpMethod)
        case pushPermission(granted: Bool)
        case reviewPromptShown(ReviewPrompter.Trigger)
        // Whether the share sheet was finished (sent, saved, ...) or closed
        case shareCompleted(ShareKind, completed: Bool)
        case importCompleted(ImportSource, films: Int)
        // A film-count milestone (films_10, films_100, ...) reached for the first time, and its card shared
        case milestoneReached(String)
        case milestoneShared(String)
        // Not logged yet: Phase 1 (onboarding, links and invites) wires these
        case onboardingStep(String)
        case linkOpened(String)
        case inviteSent
        case inviteAccepted

        var name: String {
            switch self {
            case .signUp: return AnalyticsEventSignUp
            case .termsAccepted: return "terms_accepted"
            case .listCreated: return "list_created"
            case .filmAdded: return "film_added"
            case .filmRanked: return "film_ranked"
            case .filmWatched: return "film_watched"
            case .aiPickUsed: return "ai_pick_used"
            case .discoverSwipe: return "discover_swipe"
            case .discoverImpression: return "discover_impression"
            case .recommendationSent: return "recommendation_sent"
            case .theatreCheckInOpened: return "theatre_checkin_opened"
            case .moreLikeThisOpened: return "more_like_this_opened"
            case .reportSubmitted: return "report_submitted"
            case .shareList: return "share_list"
            case .firstListCreated: return "first_list_created"
            case .firstRanking: return "first_ranking"
            case .signIn: return "sign_in"
            case .pushPermission: return "push_permission"
            case .reviewPromptShown: return "review_prompt_shown"
            case .shareCompleted: return "share_completed"
            case .importCompleted: return "import_completed"
            case .milestoneReached: return "milestone_reached"
            case .milestoneShared: return "milestone_shared"
            case .onboardingStep: return "onboarding_step"
            case .linkOpened: return "link_opened"
            case .inviteSent: return "invite_sent"
            case .inviteAccepted: return "invite_accepted"
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
            case .discoverSwipe(let reaction, let ai, let tmdbID, let source, let position):
                let direction: String
                switch reaction {
                case .liked: direction = "add"
                case .disliked: direction = "dislike"
                case .skipped: direction = "skip"
                }
                return ["direction": direction, "ai": ai ? "true" : "false", "tmdb_id": tmdbID, "source": source, "position": position]
            case .discoverImpression(let tmdbID, let source, let position, let ai):
                return ["tmdb_id": tmdbID, "source": source, "position": position, "ai": ai ? "true" : "false"]
            // Capped, so it's a rough size rather than a count of the user's friends
            case .recommendationSent(let recipients): return ["recipients": min(recipients, 10)]
            // The report form's fixed choices (user, list, …; spam, harassment, …), never what was reported
            case .reportSubmitted(let contentType, let reason): return ["content_type": contentType, "reason": reason]
            case .shareList(let format): return ["format": format.rawValue]
            case .signIn(let method): return [AnalyticsParameterMethod: method.rawValue]
            case .pushPermission(let granted): return ["granted": granted ? "true" : "false"]
            case .reviewPromptShown(let trigger): return ["trigger": trigger.rawValue]
            case .shareCompleted(let kind, let completed): return ["kind": kind.rawValue, "completed": completed ? "true" : "false"]
            // A size band rather than the count
            case .importCompleted(let source, let films):
                return ["source": source.rawValue, "count": films <= 10 ? "1-10" : films <= 100 ? "11-100" : "100+"]
            // One of the fixed milestone ids, never the exact count
            case .milestoneReached(let milestone), .milestoneShared(let milestone): return ["milestone": milestone]
            // A fixed step or link kind, never the link itself
            case .onboardingStep(let step): return ["step": step]
            case .linkOpened(let kind): return ["kind": kind]
            case .termsAccepted, .theatreCheckInOpened, .moreLikeThisOpened, .firstListCreated, .firstRanking, .inviteSent, .inviteAccepted: return nil
            }
        }
    }

    static func log(_ event: Event) {
        Analytics.logEvent(event.name, parameters: event.parameters)
        switch event {
        // Lists sync down after a reinstall, so a list made while others are already there isn't the first
        case .listCreated:
            let lists = (try? PersistenceController.shared.container.viewContext.count(for: CDMovieList.fetch())) ?? 0
            logOnce(.firstListCreated, key: "analytics.firstListCreated", skip: lists > 1)
        case .filmRanked: logOnce(.firstRanking, key: "analytics.firstRanking")
        default: break
        }
    }

    // Logged the first time only; a skipped one is marked done too, so it can't come later
    private static func logOnce(_ event: Event, key: String, skip: Bool = false) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !skip { log(event) }
    }
}
