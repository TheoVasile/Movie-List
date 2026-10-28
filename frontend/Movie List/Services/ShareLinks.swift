//
//  ShareLinks.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-28.
//

import Foundation
import SwiftUI

/// Marquee's public links: the web pages for lists, profiles and films, invite links, and the universal links that
/// open them in the app instead
enum ShareLinks {
    // The ONE place the app's public address is set. To move to a new domain (e.g. https://onmarquee.app):
    //   1. change baseURL below,
    //   2. add `applinks:onmarquee.app` to "Movie List.entitlements" (keep the onrender.com entry so old links
    //      still open the app),
    //   3. set PUBLIC_BASE_URL=https://onmarquee.app on the backend (Render).
    static let baseURL = URL(string: "https://movie-list-backend-dgct.onrender.com")!

    /// Hosts whose links the app opens itself: the current one, plus any older ones still in people's messages.
    /// When the domain changes, add the old host here so links already shared keep working
    static let linkHosts: Set<String> = [baseURL.host ?? "", "movie-list-backend-dgct.onrender.com"]

    /// The address without its scheme, for share cards: "onmarquee.app"
    static var shortDomain: String { baseURL.host ?? "" }

    static func list(publicID: String) -> URL { baseURL.appendingPathComponent("l").appendingPathComponent(publicID) }
    static func profile(handle: String) -> URL { baseURL.appendingPathComponent("u").appendingPathComponent(handle) }
    static func film(tmdbID: Int64) -> URL { baseURL.appendingPathComponent("f").appendingPathComponent(String(tmdbID)) }
    static func personalInvite(handle: String) -> URL { baseURL.appendingPathComponent("i").appendingPathComponent(handle) }
    static func groupInvite(token: String) -> URL {
        baseURL.appendingPathComponent("join").appendingPathComponent("group").appendingPathComponent(token)
    }

    /// The signed-in user's own link: their profile page, or their invite link when their profile is private (a
    /// private profile has no public page). nil until they have an @username
    static var myLink: URL? {
        guard let profile = SocialStore.shared.profile, let handle = profile.handle else { return nil }
        return profile.is_private == true ? personalInvite(handle: handle) : self.profile(handle: handle)
    }

    /// The footer on share images: "@sam · onmarquee.app"
    static var cardFooter: String {
        SocialStore.shared.profile?.handle.map { "@\($0) · \(shortDomain)" } ?? shortDomain
    }
}

/// The small footer on every image Marquee makes for sharing, so people can find the user
struct ShareCardFooter: View {
    var body: some View {
        Label(ShareLinks.cardFooter, systemImage: "film.stack")
            .font(.caption.weight(.bold))
            .foregroundColor(Theme.textTertiary)
            .lineLimit(1)
    }
}

// MARK: - Links the app opens

/// Something a link points to: https://<host>/l/<id> (a universal link) or marquee://l/<id>; cinelist://film/<id>
/// from the widgets
enum DeepLink: Equatable {
    case list(publicID: String)
    case profile(handle: String)
    case film(tmdbID: Int64)
    case groupInvite(token: String)
    case personalInvite(handle: String)

    /// For analytics: the kind of link, never the link itself
    var kind: String {
        switch self {
        case .list: return "list"
        case .profile: return "profile"
        case .film: return "film"
        case .groupInvite: return "group_invite"
        case .personalInvite: return "personal_invite"
        }
    }

    init?(url: URL) {
        let parts: [String]
        switch url.scheme?.lowercased() {
        case "https", "http":
            guard let host = url.host?.lowercased(), ShareLinks.linkHosts.contains(host) else { return nil }
            parts = url.pathComponents.filter { $0 != "/" }
        case "marquee", "cinelist":
            parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        default:
            return nil
        }
        guard let first = parts.first else { return nil }
        switch (first, parts.count) {
        case ("l", 2):
            guard UUID(uuidString: parts[1]) != nil else { return nil }
            self = .list(publicID: parts[1].lowercased())
        case ("u", 2):
            self = .profile(handle: parts[1].lowercased())
        case ("i", 2):
            self = .personalInvite(handle: parts[1].lowercased())
        case ("f", 2), ("film", 2):
            guard let id = Int64(parts[1]), id != 0 else { return nil }
            self = .film(tmdbID: id)
        case ("join", 3) where parts[1] == "group":
            guard parts[2].range(of: "^[A-Za-z0-9_-]{22,64}$", options: .regularExpression) != nil else { return nil }
            self = .groupInvite(token: parts[2])
        default:
            return nil
        }
    }
}

/// Links opened from outside the app wait here until the app is ready for them (signed in, with an @username and
/// the current terms accepted). A group invite is also kept on the phone, so it survives signing up: the join
/// sheet shows once the new account is ready
final class LinkRouter: ObservableObject {
    static let shared = LinkRouter()
    private static let pendingInviteKey = "links.pendingGroupInvite"

    @Published var pending: DeepLink? = nil

    /// Takes a link the app was opened with. false when it isn't one of Marquee's
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        AppAnalytics.log(.linkOpened(link.kind))
        if case .groupInvite(let token) = link {
            UserDefaults.standard.set(token, forKey: Self.pendingInviteKey)
        }
        pending = link
        return true
    }

    /// The link to open now, if any: the latest one, or a group invite saved before signing in
    func take() -> DeepLink? {
        if let pending {
            self.pending = nil
            return pending
        }
        return UserDefaults.standard.string(forKey: Self.pendingInviteKey).map { .groupInvite(token: $0) }
    }

    /// The saved invite has been dealt with (joined, declined or no longer working)
    func finishInvite() {
        UserDefaults.standard.removeObject(forKey: Self.pendingInviteKey)
    }
}

// MARK: - Server replies

/// A list's public link. shareable is false unless anyone can open it (a public list on a profile that isn't private)
struct ListLink: Decodable {
    let url: String
    let public_id: String
    let shareable: Bool
}

/// A list opened from a link: the user's own (open their copy by id), or someone else's they can see, read-only
struct LinkedList: Decodable {
    let mine: Bool
    let id: Int64
    let list: FriendLists.List?
}

/// A film opened from a link
struct LinkedFilm: Decodable {
    let tmdb_id: Int64
    let title: String
    let release_date: String
    let overview: String
    let poster_path: String?

    var movie: Movie {
        Movie(id: tmdb_id, title: title, release_date: release_date, overview: overview, poster_path: poster_path,
              original_language: "", popularity: 0)
    }
}

/// A movie night group's invite link
struct GroupInvite: Decodable {
    let token: String
    let url: String
    let expires_at: String?
}

/// What an invite link leads to
struct GroupInvitePreview: Decodable {
    let group_id: Int64
    let group_name: String
    let member_count: Int
    let inviter_handle: String?
}

struct GroupInviteAcceptance: Decodable {
    let joined: Bool
    let already_member: Bool
    let group_id: Int64
    let group_name: String?
}
