//
//  StreamingNowStore.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI

/// The server's answer to "which of these films stream on my services?"
struct StreamingNow: Decodable {
    let region: String
    let services: [StreamingService]
    // TMDb id (as text) -> the ids of the user's services streaming it; only films on at least one
    let films: [String: [Int]]
}

/// "What can I watch tonight?": which films in the user's lists stream on their own services. Checked on the
/// server a list at a time and kept for a few hours, since availability changes slowly
final class StreamingNowStore: ObservableObject {
    static let shared = StreamingNowStore()

    // The user's services, with names and logos; empty when they haven't picked any (or before the first check)
    @Published private(set) var services: [StreamingService] = []
    // Whether the server has said the user has no services picked
    @Published private(set) var hasNoServices = false
    @Published private(set) var isChecking = false
    // Bumped whenever new answers arrive, so lists filtering on them update
    @Published private(set) var version = 0

    // TMDb id -> the user's services streaming it (empty when none), and when that was checked
    private var onServices: [Int64: (services: [Int], checked: Date)] = [:]
    private static let maxAge: TimeInterval = 6 * 60 * 60
    private static let batchSize = 200

    /// The user's services streaming a film, or nil when it hasn't been checked
    func services(for tmdbID: Int64) -> [StreamingService]? {
        guard let entry = onServices[tmdbID] else { return nil }
        return services.filter { entry.services.contains($0.id) }
    }

    func isStreaming(_ tmdbID: Int64) -> Bool {
        !(onServices[tmdbID]?.services.isEmpty ?? true)
    }

    /// Checks the films not checked in the last few hours, a batch at a time, and calls back on the main thread
    /// once they're all in
    func check(_ tmdbIDs: [Int64], completion: @escaping () -> Void = {}) {
        let now = Date()
        let due = Array(Set(tmdbIDs.filter { id in
            guard id != 0 else { return false }
            return onServices[id].map { now.timeIntervalSince($0.checked) > Self.maxAge } ?? true
        }))
        guard !due.isEmpty else {
            completion()
            return
        }
        isChecking = true
        var batches = stride(from: 0, to: due.count, by: Self.batchSize).map { Array(due[$0..<min($0 + Self.batchSize, due.count)]) }
        func next() {
            guard let batch = batches.first else {
                isChecking = false
                completion()
                return
            }
            batches.removeFirst()
            APIService.shared.fetchStreamingNow(tmdbIDs: batch) { result in
                guard case .success(let answer) = result else {
                    // Try again next time rather than remembering a failure as "not streaming"
                    self.isChecking = false
                    completion()
                    return
                }
                self.services = answer.services
                self.hasNoServices = answer.services.isEmpty
                let checked = Date()
                for id in batch {
                    self.onServices[id] = (answer.films[String(id)] ?? [], checked)
                }
                self.version += 1
                // With no services picked, nothing can be streaming on them, so there's no point asking about more
                if answer.services.isEmpty { batches = [] }
                next()
            }
        }
        next()
    }

    /// After the user changes their services, everything is checked again
    func servicesChanged() {
        onServices = [:]
        hasNoServices = false
        version += 1
    }
}
