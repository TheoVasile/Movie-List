//
//  Milestones.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-28.
//

import Foundation
import CoreData
import FirebaseAuth

/// A celebration for how many different films the user has in their own lists
enum Milestone: Int, CaseIterable, Identifiable {
    case films10 = 10, films50 = 50, films100 = 100, films1000 = 1000, films10000 = 10000

    var id: String { "films_\(rawValue)" }
    var count: Int { rawValue }

    /// "1,000"
    var number: String { count.formatted() }

    var line: String {
        switch self {
        case .films10: return "Your first 10 films — the marquee is lit!"
        case .films50: return "50 films. You're a true regular."
        case .films100: return "100 films! Centurion of cinema."
        case .films1000: return "1,000 films. Legendary."
        case .films10000: return "10,000 films. Are you a projector?"
        }
    }

    init?(id: String) {
        guard let milestone = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = milestone
    }
}

/// Plays each milestone's celebration once per user, ever. The server keeps which ones the user has reached, and
/// only the first device to record one is told it's new (created), so two phones, a reinstall or removing films
/// and adding them back never play it again. A milestone that couldn't be recorded (offline) is tried again on the
/// next check, since the films that reached it are still there.
///
/// Users who were already past some milestones when this arrived have them recorded silently first (the backfill),
/// so they don't get a burst of old celebrations
final class Milestones {
    static let shared = Milestones()

    private var isChecking = false
    private var checkAgain = false

    private init() {}

    private func backfilledKey(_ uid: String) -> String { "milestonesBackfilled.\(uid)" }
    private func reachedKey(_ uid: String) -> String { "milestonesReached.\(uid)" }

    /// The milestones this device knows the user has reached, so they aren't asked about again
    private func reached(_ uid: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: reachedKey(uid)) ?? [])
    }

    private func markReached(_ ids: [String], uid: String) {
        guard !ids.isEmpty else { return }
        UserDefaults.standard.set(Array(reached(uid).union(ids)), forKey: reachedKey(uid))
    }

    /// How many different films (and shows) are in the lists the user owns; a film in two lists counts once.
    /// Lists someone else owns and shared with the user don't count, as on the server
    static func filmCount(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) -> Int {
        let lists = (try? context.fetch(CDMovieList.fetch())) ?? []
        var ids = Set<Int64>()
        for list in lists where !list.isDeleted && ListSharing.shared.isOwner(list.id) {
            for movie in list.movies where !movie.isDeleted {
                ids.insert(movie.id)
            }
        }
        return ids.count
    }

    /// Called after films are added (and after each sync): records any milestone the user's lists have newly
    /// passed and celebrates the highest one the server says is new. Lower ones passed at the same time, like a big
    /// import going from 5 films to 600, are recorded without a celebration
    func check() {
        DispatchQueue.main.async { self.startCheck() }
    }

    private func startCheck() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard !isChecking else {
            checkAgain = true
            return
        }
        isChecking = true
        let finish = {
            self.isChecking = false
            if self.checkAgain {
                self.checkAgain = false
                self.startCheck()
            }
        }
        backfillIfNeeded(uid) { ready in
            guard ready, Auth.auth().currentUser?.uid == uid else { return finish() }
            let count = Self.filmCount()
            let known = self.reached(uid)
            let passed = Milestone.allCases.filter { $0.count <= count && !known.contains($0.id) }
            guard !passed.isEmpty else { return finish() }
            self.record(passed, uid: uid) { created in
                for milestone in created {
                    AppAnalytics.log(.milestoneReached(milestone.id))
                }
                if let highest = created.max(by: { $0.count < $1.count }), Auth.auth().currentUser?.uid == uid {
                    MilestoneCelebration.present(highest)
                }
                finish()
            }
        }
    }

    /// Records milestones one at a time, lowest first, calling back with the ones the server says are new. Stops at
    /// the first that fails: offline, it's tried again next time; refused (the server counts fewer films, e.g. one
    /// still saving), the next check asks again
    private func record(_ milestones: [Milestone], uid: String, created: [Milestone] = [], completion: @escaping ([Milestone]) -> Void) {
        guard let milestone = milestones.first else { return completion(created) }
        APIService.shared.recordMilestone(milestone.id) { result in
            switch result {
            case .success(let isNew):
                self.markReached([milestone.id], uid: uid)
                self.record(Array(milestones.dropFirst()), uid: uid, created: isNew ? created + [milestone] : created, completion: completion)
            case .failure:
                completion(created)
            }
        }
    }

    /// Once per user on each device: learns which milestones the server already has. When it has none yet (the
    /// first launch with this feature), every milestone the user is already past is recorded without a
    /// celebration; the server checks the count, so it doesn't matter whether the lists have synced yet. Calls back
    /// with whether celebrations can go ahead
    private func backfillIfNeeded(_ uid: String, completion: @escaping (Bool) -> Void) {
        guard !UserDefaults.standard.bool(forKey: backfilledKey(uid)) else { return completion(true) }
        APIService.shared.fetchMilestones { result in
            guard case .success(let ids) = result else { return completion(false) }
            self.markReached(ids, uid: uid)
            let done = {
                UserDefaults.standard.set(true, forKey: self.backfilledKey(uid))
                completion(true)
            }
            guard ids.isEmpty else { return done() }
            self.recordSilently(Milestone.allCases, uid: uid) { finished in
                finished ? done() : completion(false)
            }
        }
    }

    /// Records milestones lowest first until the server says the user hasn't reached one. Calls back with false
    /// when a request couldn't be made, so the backfill is tried again later
    private func recordSilently(_ milestones: [Milestone], uid: String, completion: @escaping (Bool) -> Void) {
        guard let milestone = milestones.first else { return completion(true) }
        APIService.shared.recordMilestone(milestone.id) { result in
            switch result {
            case .success:
                self.markReached([milestone.id], uid: uid)
                self.recordSilently(Array(milestones.dropFirst()), uid: uid, completion: completion)
            case .failure(let error):
                // 409: not reached yet, so neither is any higher one
                completion((error as NSError).code == 409)
            }
        }
    }
}
