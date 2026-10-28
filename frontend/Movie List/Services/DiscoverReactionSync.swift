//
//  DiscoverReactionSync.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-28.
//

import Foundation

/// Keeps the user's Discover likes, dislikes (Not for Me) and skips with their account, so the server can tailor
/// recommendations and dislikes survive a reinstall. Everything here is best effort: nothing waits on it, and a
/// change that can't be sent (offline, signed out) waits in a small queue on this device and is tried again the
/// next time Discover loads or the app opens
final class DiscoverReactionSync {
    static let shared = DiscoverReactionSync()

    private struct Pending: Codable {
        enum Kind: String, Codable { case react, remove, clear, clearSkips }
        let kind: Kind
        var tmdbID: Int64? = nil
        var reaction: String? = nil
        var source: String? = nil
    }

    private static let pendingKey = "discover.pendingReactions"
    // Set once the likes and dislikes kept on this device before reactions were synced have been uploaded
    static let migratedKey = "discoverReactionsMigrated"
    // The server takes at most this many in one bulk upload
    private static let bulkLimit = 2000
    // Plenty for a long time offline; past it the oldest changes are dropped
    private static let pendingLimit = 1000

    private var pending: [Pending]
    private var isFlushing = false
    private var isSyncing = false

    private init() {
        pending = UserDefaults.standard.data(forKey: Self.pendingKey)
            .flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
    }

    /// How a reaction is named to the server
    static func name(_ reaction: DiscoverReaction) -> String {
        switch reaction {
        case .liked: return "like"
        case .disliked: return "dislike"
        case .skipped: return "skip"
        }
    }

    func record(_ movie: Movie, _ reaction: DiscoverReaction) {
        enqueue(Pending(kind: .react, tmdbID: movie.id, reaction: Self.name(reaction), source: movie.source))
    }

    /// Takes back one film's reaction, e.g. after Undo
    func remove(_ tmdbID: Int64) {
        enqueue(Pending(kind: .remove, tmdbID: tmdbID))
    }

    /// Forgets every reaction, for Reset Taste Profile. Nothing on this device is left to upload either
    func clearAll() {
        pending = [Pending(kind: .clear)]
        UserDefaults.standard.set(true, forKey: Self.migratedKey)
        save()
        flush()
    }

    /// Forgets every skip, for Show Skipped Again, so the server offers those films again. Calls back once the
    /// change has been sent or queued for later, so the next batch is asked for after it
    func clearSkips(completion: @escaping () -> Void = {}) {
        // Skips still waiting to be sent would only be deleted again
        pending.removeAll { $0.kind == .react && $0.reaction == "skip" }
        pending.removeAll { $0.kind == .clearSkips }
        pending.append(Pending(kind: .clearSkips))
        save()
        flush { _ in completion() }
    }

    /// Uploads what's waiting (and, the first time, the likes and dislikes kept on this device), then merges the
    /// account's reactions into this device's, so films disliked before a reinstall stay hidden
    func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        migrateIfNeeded { [weak self] in
            self?.flush { allSent in
                guard let self else { return }
                guard allSent else {
                    self.isSyncing = false
                    return
                }
                APIService.shared.fetchDiscoverReactions { result in
                    if case .success(let records) = result {
                        self.merge(records)
                    }
                    self.isSyncing = false
                }
            }
        }
    }

    // MARK: Queue

    private func enqueue(_ change: Pending) {
        // Only a film's latest change matters
        if let id = change.tmdbID {
            pending.removeAll { $0.tmdbID == id }
        }
        pending.append(change)
        if pending.count > Self.pendingLimit {
            pending.removeFirst(pending.count - Self.pendingLimit)
        }
        save()
        flush()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.pendingKey)
        }
    }

    /// Sends the queue in order. Stops at the first change that can't be sent now, keeping it and the rest for
    /// later; one the server turns down for good is dropped. Calls back with whether the queue is now empty
    private func flush(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isFlushing else { return completion(false) }
        guard let next = pending.first else { return completion(true) }
        isFlushing = true
        send(next) { [weak self] status in
            guard let self else { return }
            self.isFlushing = false
            let retryLater = status == 0 || status == 401 || status == 408 || status == 429 || status >= 500
            if retryLater {
                completion(false)
                return
            }
            // Sent, or refused for good. Changes queued meanwhile for the same film already replaced it
            if let first = self.pending.first, first.kind == next.kind, first.tmdbID == next.tmdbID, first.reaction == next.reaction {
                self.pending.removeFirst()
                self.save()
            }
            self.flush(completion: completion)
        }
    }

    private func send(_ change: Pending, completion: @escaping (Int) -> Void) {
        let api = APIService.shared
        switch change.kind {
        case .react:
            guard let id = change.tmdbID, let reaction = change.reaction else { return completion(200) }
            api.sendDiscoverReaction(tmdbID: id, reaction: reaction, source: change.source, completion: completion)
        case .remove:
            guard let id = change.tmdbID else { return completion(200) }
            api.deleteDiscoverReactions(tmdbID: id, completion: completion)
        case .clear:
            api.deleteDiscoverReactions(tmdbID: nil, completion: completion)
        case .clearSkips:
            api.deleteDiscoverReactions(tmdbID: nil, reaction: "skip", completion: completion)
        }
    }

    // MARK: First upload

    /// Uploads the likes and dislikes kept on this device before they were synced, in chunks the server accepts.
    /// Marked done only once every chunk has gone, so a failure tries again next time
    private func migrateIfNeeded(completion: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migratedKey) else { return completion() }
        let formatter = ISO8601DateFormatter()
        var dates: [Int64: Date] = [:]
        for entry in DiscoverReactions.shared.liked + DiscoverReactions.shared.disliked {
            dates[entry.id] = entry.date
        }
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
            guard index < chunks.count else {
                defaults.set(true, forKey: Self.migratedKey)
                return completion()
            }
            APIService.shared.sendDiscoverReactions(chunks[index]) { status in
                if (200...299).contains(status) {
                    upload(index + 1)
                } else {
                    completion()
                }
            }
        }
        upload(0)
    }

    // MARK: Merge

    /// Adds the account's likes and dislikes this device doesn't know about yet, as the oldest ones. Skips aren't
    /// merged, so Show Skipped Again keeps working on this device
    private func merge(_ records: [APIService.DiscoverReactionRecord]) {
        let defaults = UserDefaults.standard
        var liked = defaults.array(forKey: DiscoverViewModel.likedKey) as? [Int] ?? []
        var disliked = defaults.array(forKey: DiscoverViewModel.dislikedKey) as? [Int] ?? []
        let known = Set(liked).union(disliked)
        let waiting = Set(pending.compactMap(\.tmdbID).map(Int.init))
        var newLiked: [Int] = []
        var newDisliked: [Int] = []
        for record in records {
            let id = Int(record.tmdb_id)
            guard !known.contains(id), !waiting.contains(id) else { continue }
            switch record.reaction {
            case "like": newLiked.append(id)
            case "dislike": newDisliked.append(id)
            default: break
            }
        }
        guard !newLiked.isEmpty || !newDisliked.isEmpty else { return }
        liked = Array((newLiked + liked).suffix(DiscoverViewModel.likedLimit))
        disliked = Array((newDisliked + disliked).suffix(DiscoverViewModel.dislikedLimit))
        defaults.set(liked, forKey: DiscoverViewModel.likedKey)
        defaults.set(disliked, forKey: DiscoverViewModel.dislikedKey)
        DiscoverReactions.shared.changed.send()
    }
}
