//
//  DiscoverReactionSync.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-28.
//

import Foundation

/// Keeps the user's Discover likes and dislikes (Not for Me) with their account, so the server can tailor
/// recommendations and they follow the user to other devices. Swipes don't wait on it: a change that can't be sent
/// (offline, server down) waits in a small queue on this device, one per account, and is tried again the next time
/// Discover loads or the app opens. The account's copy is the one that counts
final class DiscoverReactionSync {
    static let shared = DiscoverReactionSync()

    private struct Pending: Codable {
        // clearSkips is from older builds' Show Skipped Again, and is only still here so their queue can be read
        enum Kind: String, Codable { case react, remove, clear, clearSkips }
        let kind: Kind
        var tmdbID: Int64? = nil
        var reaction: String? = nil
        var source: String? = nil
        var date: Date? = nil
    }

    // Both are followed by the account they belong to. Earlier builds kept one of each for the whole device
    private static let pendingKey = "discover.pendingReactions"
    // Set once the likes and dislikes kept on this device before reactions were synced have been uploaded
    private static let migratedKey = "discoverReactionsMigrated"
    // The account the Discover data on this device belongs to
    private static let ownerKey = "discover.owner"
    // The server takes at most this many in one bulk upload
    private static let bulkLimit = 2000
    // Plenty for a long time offline; past it the oldest changes are dropped
    private static let pendingLimit = 1000
    // A change that waited longer than this is sent with when it was made, so it can't replace a newer one from
    // another device
    private static let lateAfter: TimeInterval = 60

    private var uid: String? = nil
    private var pending: [Pending] = []
    private var isFlushing = false
    // Told, once the flush under way ends, whether everything was sent
    private var flushWaiters: [(Bool) -> Void] = []
    private var isSyncing = false
    // Counts changes made here, so an answer asked for before one isn't taken as the latest
    private var changeCount = 0

    private init() {}

    /// Whether any change is still waiting to be sent
    var hasPending: Bool { !pending.isEmpty }

    /// How a reaction is named to the server
    static func name(_ reaction: DiscoverReaction) -> String {
        switch reaction {
        case .liked: return "like"
        case .disliked: return "dislike"
        }
    }

    // MARK: Account

    /// Call with who is signed in, before any screen that uses Discover. Data kept for a different account is
    /// cleared, and this account's waiting changes are picked up again
    func use(_ uid: String?) {
        guard uid != self.uid || uid == nil else { return }
        let defaults = UserDefaults.standard
        let owner = defaults.string(forKey: Self.ownerKey)
        guard let uid else {
            self.uid = nil
            pending = []
            // Left behind by an earlier build, which didn't clear anything when signing out
            if owner == nil { clearDevice() }
            return
        }
        if let owner {
            if owner != uid { clearDevice() }
        } else {
            // From before this was kept for each account: it belongs to whoever is already signed in
            if let data = defaults.data(forKey: Self.pendingKey) { defaults.set(data, forKey: Self.key(Self.pendingKey, uid)) }
            if defaults.bool(forKey: Self.migratedKey) { defaults.set(true, forKey: Self.key(Self.migratedKey, uid)) }
            defaults.removeObject(forKey: Self.pendingKey)
            defaults.removeObject(forKey: Self.migratedKey)
        }
        defaults.set(uid, forKey: Self.ownerKey)
        self.uid = uid
        pending = (defaults.data(forKey: Self.key(Self.pendingKey, uid))
            .flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? [])
            // Skips are sent again (see recordSkip); clearing them is no longer offered
            .filter { $0.kind != .clearSkips }
        save()
    }

    /// Signed out: clears what Discover kept on this device. Changes still waiting stay, for when this account signs
    /// in again
    func signedOut() {
        uid = nil
        pending = []
        clearDevice()
    }

    /// The account was deleted: its waiting changes go too. Call before signing out
    func forgetAccount() {
        guard let uid = uid ?? UserDefaults.standard.string(forKey: Self.ownerKey) else { return }
        pending = []
        UserDefaults.standard.removeObject(forKey: Self.key(Self.pendingKey, uid))
        UserDefaults.standard.removeObject(forKey: Self.key(Self.migratedKey, uid))
    }

    private static func key(_ key: String, _ uid: String) -> String { "\(key).\(uid)" }

    private func clearDevice() {
        // First, so an open Discover doesn't save any of it again
        DiscoverReactions.shared.cleared.send()
        let defaults = UserDefaults.standard
        for key in DiscoverReactions.deviceKeys + [Self.pendingKey, Self.migratedKey, Self.ownerKey] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Changes

    /// A swipe, sent in the background
    func record(_ movie: Movie, _ reaction: DiscoverReaction) {
        enqueue(Pending(kind: .react, tmdbID: movie.id, reaction: Self.name(reaction), source: movie.source, date: Date()))
    }

    /// Skip in Discover, sent in the background. It's no rating: the server only keeps the film out of Discover for
    /// a while (30 days), and it teaches nothing about taste. A like or dislike later replaces it
    func recordSkip(_ movie: Movie) {
        enqueue(Pending(kind: .react, tmdbID: movie.id, reaction: "skip", source: movie.source, date: Date()))
    }

    /// Takes back one film's reaction, e.g. after Undo
    func remove(_ tmdbID: Int64) {
        enqueue(Pending(kind: .remove, tmdbID: tmdbID))
    }

    /// Changes one film's reaction, or takes it back when nil, and calls back with whether the account has it now.
    /// Nothing is queued when it can't be sent, so the screen can put it back the way it was
    func change(_ tmdbID: Int64, to reaction: DiscoverReaction?, source: String? = nil, completion: @escaping (Bool) -> Void) {
        // Anything waiting goes first, so an older swipe on the film can't land after this
        flush { [weak self] allSent in
            guard let self, allSent, let uid = self.uid else { return completion(false) }
            let done = { (status: Int) in
                guard (200...299).contains(status), self.uid == uid else { return completion(false) }
                self.changeCount += 1
                completion(true)
            }
            if let reaction {
                APIService.shared.sendDiscoverReaction(tmdbID: tmdbID, reaction: Self.name(reaction), source: source, completion: done)
            } else {
                APIService.shared.deleteDiscoverReactions(tmdbID: tmdbID, completion: done)
            }
        }
    }

    /// Forgets every reaction, for Reset Taste Profile. Nothing on this device is left to upload either. Calls back
    /// once that has been sent, or couldn't be and waits in the queue
    func clearAll(completion: @escaping () -> Void = {}) {
        guard let uid else { return completion() }
        changeCount += 1
        pending = [Pending(kind: .clear)]
        UserDefaults.standard.set(true, forKey: Self.key(Self.migratedKey, uid))
        save()
        flush { _ in completion() }
    }

    /// Uploads what's waiting (and, the first time, the likes and dislikes kept on this device), then makes this
    /// device's likes and dislikes the account's, so ones made, changed or taken back elsewhere count here too
    func sync() {
        guard !isSyncing, let uid else { return }
        isSyncing = true
        migrateIfNeeded(uid) { [weak self] migrated in
            self?.flush { allSent in
                guard let self else { return }
                guard migrated, allSent, self.uid == uid else {
                    self.isSyncing = false
                    return
                }
                let changes = self.changeCount
                APIService.shared.fetchDiscoverReactions { result in
                    self.isSyncing = false
                    // Anything changed since it was asked for is brought in next time
                    if case .success(let records) = result, self.uid == uid, self.changeCount == changes, self.pending.isEmpty {
                        self.adopt(records)
                    }
                }
            }
        }
    }

    // MARK: Queue

    private func enqueue(_ change: Pending) {
        guard uid != nil else { return }
        changeCount += 1
        // Only a film's latest change matters
        if let id = change.tmdbID {
            pending.removeAll { $0.tmdbID == id }
        }
        pending.append(change)
        if pending.count > Self.pendingLimit {
            pending.removeFirst(pending.count - Self.pendingLimit)
        }
        save()
        flush { [weak self] allSent in
            if !allSent && self?.pending.isEmpty == false { DiscoverReactions.shared.delayed.send() }
        }
    }

    private func save() {
        guard let uid else { return }
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.key(Self.pendingKey, uid))
        }
    }

    /// Sends the queue in order. Stops at the first change that can't be sent now, keeping it and the rest for
    /// later; one the server turns down for good is dropped. Calls back with whether the queue is now empty. A flush
    /// already under way also sends what was queued after it started, so this waits for that one
    func flush(completion: @escaping (Bool) -> Void = { _ in }) {
        flushWaiters.append(completion)
        guard !isFlushing else { return }
        isFlushing = true
        sendNext()
    }

    private func endFlush(allSent: Bool) {
        isFlushing = false
        let waiters = flushWaiters
        flushWaiters = []
        waiters.forEach { $0(allSent) }
    }

    private func sendNext() {
        guard let uid, let next = pending.first else { return endFlush(allSent: uid != nil) }
        send(next) { [weak self] status in
            guard let self else { return }
            // Someone else has signed in since; their queue has its own flush
            guard self.uid == uid else { return self.endFlush(allSent: false) }
            let retryLater = status == 0 || status == 401 || status == 408 || status == 429 || status >= 500
            if retryLater { return self.endFlush(allSent: false) }
            // Sent, or refused for good. Changes queued meanwhile for the same film already replaced it
            if let first = self.pending.first, first.kind == next.kind, first.tmdbID == next.tmdbID, first.reaction == next.reaction {
                self.pending.removeFirst()
                self.save()
                if next.kind == .react, let id = next.tmdbID, !(200...299).contains(status) {
                    DiscoverReactions.shared.rejected.send(id)
                }
            }
            self.sendNext()
        }
    }

    private func send(_ change: Pending, completion: @escaping (Int) -> Void) {
        let api = APIService.shared
        switch change.kind {
        case .react:
            guard let id = change.tmdbID, let reaction = change.reaction else { return completion(200) }
            let late = change.date.flatMap { Date().timeIntervalSince($0) > Self.lateAfter ? $0 : nil }
            api.sendDiscoverReaction(tmdbID: id, reaction: reaction, source: change.source, at: late, completion: completion)
        case .remove:
            guard let id = change.tmdbID else { return completion(200) }
            api.deleteDiscoverReactions(tmdbID: id, completion: completion)
        case .clear:
            api.deleteDiscoverReactions(tmdbID: nil, completion: completion)
        case .clearSkips:
            completion(200)
        }
    }

    // MARK: First upload

    /// Uploads the likes and dislikes kept on this device before they were synced, in chunks the server accepts.
    /// Marked done only once every chunk has gone, so a failure tries again next time. Calls back with whether it's
    /// done
    private func migrateIfNeeded(_ uid: String, completion: @escaping (Bool) -> Void) {
        let defaults = UserDefaults.standard
        let doneKey = Self.key(Self.migratedKey, uid)
        guard !defaults.bool(forKey: doneKey) else {
            DiscoverReactions.forgetOldHistory()
            return completion(true)
        }
        let formatter = ISO8601DateFormatter()
        let dates = DiscoverReactions.oldHistoryDates()
        let record = { (id: Int, reaction: String) -> [String: Any] in
            var item: [String: Any] = ["tmdb_id": id, "reaction": reaction]
            if let date = dates[Int64(id)] { item["at"] = formatter.string(from: date) }
            return item
        }
        let liked = (defaults.array(forKey: DiscoverViewModel.likedKey) as? [Int] ?? []).map { record($0, "like") }
        let disliked = (defaults.array(forKey: DiscoverViewModel.dislikedKey) as? [Int] ?? []).map { record($0, "dislike") }
        let all = liked + disliked
        let chunks = stride(from: 0, to: all.count, by: Self.bulkLimit).map { Array(all[$0..<min($0 + Self.bulkLimit, all.count)]) }

        func upload(_ index: Int) {
            guard self.uid == uid else { return completion(false) }
            guard index < chunks.count else {
                defaults.set(true, forKey: doneKey)
                DiscoverReactions.forgetOldHistory()
                return completion(true)
            }
            APIService.shared.sendDiscoverReactions(chunks[index]) { status in
                if (200...299).contains(status) {
                    upload(index + 1)
                } else {
                    completion(false)
                }
            }
        }
        upload(0)
    }

    // MARK: From the account

    /// Makes the likes and dislikes on this device the account's. Skips are left out: the server keeps those films
    /// out of Discover itself
    private func adopt(_ records: [APIService.DiscoverReactionRecord]) {
        let defaults = UserDefaults.standard
        // Newest first from the server, oldest first on this device
        let ids = { (reaction: String, limit: Int) in
            Array(records.filter { $0.reaction == reaction }.map { Int($0.tmdb_id) }.prefix(limit).reversed())
        }
        let liked = ids("like", DiscoverViewModel.likedLimit)
        let disliked = ids("dislike", DiscoverViewModel.dislikedLimit)
        let before = [DiscoverViewModel.likedKey, DiscoverViewModel.dislikedKey].map { defaults.array(forKey: $0) as? [Int] ?? [] }
        guard before[0] != liked || before[1] != disliked else { return }
        defaults.set(liked, forKey: DiscoverViewModel.likedKey)
        defaults.set(disliked, forKey: DiscoverViewModel.dislikedKey)
        var profile = DiscoverReactions.savedProfile
        profile.setLiked(liked.reversed().map(Int64.init))
        DiscoverReactions.save(profile)
        DiscoverReactions.shared.changed.send(nil)
    }
}
