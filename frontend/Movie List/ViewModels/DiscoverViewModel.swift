//
//  DiscoverViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI
import CoreData

/// Optional details the user can share to personalise AI picks in Discover. Kept on this device and
/// only sent along with AI Discover requests. AI picks are off until the user agrees to them
enum Personalization {
    static let useAIKey = "discover.useAI"
    // Whether the user has been asked about AI picks yet
    static let aiConsentAskedKey = "discover.aiConsentAsked"
    static let under18 = "Under 18"
    static let ageRangeKey = "personalization.ageRange"
    static let pronounsKey = "personalization.pronouns"
    static let notShared = "Prefer not to say"
    static let ageRanges = [notShared, under18, "18–24", "25–34", "35–44", "45–54", "55–64", "65+"]
    static let pronouns = [notShared, "She/Her", "He/Him", "They/Them", "She/They", "He/They", "Xe/Xem", "Ze/Hir", "It/Its"]

    static var useAI: Bool {
        UserDefaults.standard.bool(forKey: useAIKey) && !isUnder18
    }

    /// AI picks are never used for under-18s
    static var isUnder18: Bool {
        UserDefaults.standard.string(forKey: ageRangeKey) == under18
    }

    /// Earlier builds asked for gender as well as pronouns. Carries a saved gender answer over to
    /// pronouns, unless pronouns were already chosen, and forgets the old answer
    static func migrateGenderToPronouns() {
        let defaults = UserDefaults.standard
        let legacyGenderKey = "personalization.gender"
        guard let gender = defaults.string(forKey: legacyGenderKey) else { return }
        let matching = ["Woman": "She/Her", "Man": "He/Him", "Non-binary": "They/Them"]
        if defaults.string(forKey: pronounsKey) == nil, let pronouns = matching[gender] {
            defaults.set(pronouns, forKey: pronounsKey)
        }
        defaults.removeObject(forKey: legacyGenderKey)
    }

    /// The stored answer, or nil when the user hasn't shared one
    static func value(for key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), value != notShared else { return nil }
        return value
    }
}

/// How the user responded to a Discover card
enum DiscoverReaction {
    case liked
    // Swiped left: "not now" or "seen it", which says nothing about their taste
    case skipped
    // Tapped "Not for me"
    case disliked
}

/// What Discover has learned from the user's swipes. Kept on this device only, as TMDb film ids, a
/// score per genre (liking a film raises its genres' scores, marking it "Not for me" lowers them;
/// skipping leaves them alone) and the titles of recent swipes, which AI Discover uses when the
/// user's lists are empty
struct TasteProfile: Codable {
    struct RecentFilm: Codable {
        let title: String
        let year: String
    }

    private(set) var genreScores: [Int: Double] = [:]
    // Most recent first
    private(set) var likedMovieIDs: [Int64] = []
    private(set) var recentLiked: [RecentFilm] = []
    private(set) var recentPassed: [RecentFilm] = []
    private(set) var recentDisliked: [RecentFilm] = []
    private(set) var swipeCount = 0
    private(set) var likeCount = 0

    // Plenty for the AI to learn from: about 10 tokens a film
    private static let recentLimit = 500

    init() {}

    // Profiles saved before recent swipes were kept don't have them
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        genreScores = try container.decode([Int: Double].self, forKey: .genreScores)
        likedMovieIDs = try container.decode([Int64].self, forKey: .likedMovieIDs)
        recentLiked = try container.decodeIfPresent([RecentFilm].self, forKey: .recentLiked) ?? []
        recentPassed = try container.decodeIfPresent([RecentFilm].self, forKey: .recentPassed) ?? []
        recentDisliked = try container.decodeIfPresent([RecentFilm].self, forKey: .recentDisliked) ?? []
        swipeCount = try container.decode(Int.self, forKey: .swipeCount)
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
    }

    static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary",
        18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Science Fiction", 10770: "TV Movie", 53: "Thriller",
        10752: "War", 37: "Western",
    ]

    mutating func record(_ movie: Movie, _ reaction: DiscoverReaction) {
        let film = RecentFilm(title: movie.title, year: Theme.year(from: movie.release_date))
        swipeCount += 1

        switch reaction {
        case .skipped:
            // Remembered only so the AI doesn't suggest it again; genre scores are untouched
            recentPassed = Array(([film] + recentPassed).prefix(Self.recentLimit))
            return
        case .liked:
            likeCount += 1
            likedMovieIDs.removeAll { $0 == movie.id }
            likedMovieIDs = Array(([movie.id] + likedMovieIDs).prefix(20))
            recentLiked = Array(([film] + recentLiked).prefix(Self.recentLimit))
        case .disliked:
            recentDisliked = Array(([film] + recentDisliked).prefix(Self.recentLimit))
        }

        // Every like or dislike makes older ones count a little less, so the profile follows changing taste
        for genre in genreScores.keys {
            genreScores[genre]! *= 0.97
        }
        for genre in movie.genre_ids ?? [] {
            genreScores[genre, default: 0] += reaction == .liked ? 1 : -1
        }
    }

    var favoriteGenres: [Int] {
        genreScores.filter { $0.value >= 1.5 }.sorted { $0.value > $1.value }.prefix(3).map(\.key)
    }

    var avoidedGenres: [Int] {
        genreScores.filter { $0.value <= -1.5 }.sorted { $0.value < $1.value }.prefix(3).map(\.key)
    }

    /// Every genre with a clear lean either way, strongest first, for the AI
    var genreLeanings: (towards: [Int], awayFrom: [Int]) {
        let sorted = genreScores.sorted { $0.value > $1.value }
        return (sorted.filter { $0.value >= 1 }.map(\.key), sorted.reversed().filter { $0.value <= -1 }.map(\.key))
    }

    /// How well a film's genres match the profile; 0 when nothing is known yet
    func affinity(for movie: Movie) -> Double {
        let genres = movie.genre_ids ?? []
        guard !genres.isEmpty else { return 0 }
        // Divided by √count so a film isn't favoured just for listing many genres
        return genres.reduce(0) { $0 + (genreScores[$1] ?? 0) } / Double(genres.count).squareRoot()
    }
}

class DiscoverViewModel: ObservableObject {
    /// Cards still to swipe, top card first
    @Published private(set) var deck: [Movie] = [] {
        // Saved so Discover opens with cards straight away next time
        didSet { saveDeck() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var isExhausted = false
    @Published private(set) var profile: TasteProfile

    private var page = 1
    // Every film in the user's lists, weighted by how highly it's ranked
    private var seedPool: [(id: Int64, weight: Double)] = []
    // Films already used as seeds, so each batch draws on different ones
    private var usedSeeds: Set<Int64> = []
    // TMDb ids of every film already in one of the user's lists
    private var listedIDs: Set<Int64> = []
    // Films swiped left, remembered across launches so they don't come back until "Show Skipped Films"
    private var passedIDs: Set<Int64>
    // Films marked "Not for me", which stay hidden even when skipped films are shown again
    private var dislikedIDs: Set<Int64>
    // Whether to ask the AI for the next batch. Turned off for the session if the server says AI isn't
    // set up, the daily limit is reached, a request fails, or it keeps suggesting films already seen
    @Published private(set) var aiAvailable = true
    private var aiEmptyBatches = 0
    // Titles the AI has suggested this session, so it doesn't suggest them again
    private var aiSuggestedTitles: [String] = []
    // Every film dealt this session
    private var shownIDs: Set<Int64> = []
    // Genres the user chose to see; empty means automatic, tuned to their taste. Kept across launches
    @Published private(set) var genreFilter: Set<Int>

    private static let passedKey = "discover.passedMovieIDs"
    private static let dislikedKey = "discover.dislikedMovieIDs"
    private static let genreFilterKey = "discover.genreFilter"
    private static let profileKey = "discover.tasteProfile"
    private static let maxPages = 30
    private static let deckKey = "discover.savedDeck"
    private static let savedDeckLimit = 30
    // Bumped whenever the deck starts over, so films from a load started before then are ignored
    private var loadGeneration = 0

    init() {
        let stored = UserDefaults.standard.array(forKey: Self.passedKey) as? [Int] ?? []
        passedIDs = Set(stored.map(Int64.init))
        dislikedIDs = Set((UserDefaults.standard.array(forKey: Self.dislikedKey) as? [Int] ?? []).map(Int64.init))
        genreFilter = Set(UserDefaults.standard.array(forKey: Self.genreFilterKey) as? [Int] ?? [])
        profile = UserDefaults.standard.data(forKey: Self.profileKey)
            .flatMap { try? JSONDecoder().decode(TasteProfile.self, from: $0) } ?? TasteProfile()
        // The cards left last time, minus any since skipped or disliked; ones added to a list go once the lists sync
        let saved = UserDefaults.standard.data(forKey: Self.deckKey)
            .flatMap { try? JSONDecoder().decode([Movie].self, from: $0) } ?? []
        deck = saved.filter { !passedIDs.contains($0.id) && !dislikedIDs.contains($0.id) }
        shownIDs = Set(deck.map(\.id))
    }

    private static let seedsPerBatch = 6
    private static let likedSeedsPerBatch = 2

    /// Picks the films to base the next batch on: up to two recently liked films, plus a rank-weighted
    /// sample from the whole collection. Favourites are likelier, but any film can be picked, and no film
    /// is used again until the rest have been, so one film can't steer the whole deck
    private func nextSeeds() -> [Int64] {
        let liked = Array(profile.likedMovieIDs.filter { !usedSeeds.contains($0) }.prefix(Self.likedSeedsPerBatch))
        var available = seedPool.filter { !usedSeeds.contains($0.id) && !liked.contains($0.id) }
        if available.count < Self.seedsPerBatch {
            // Every film has had a turn, so start over
            usedSeeds = []
            available = seedPool.filter { !liked.contains($0.id) }
        }
        // Weighted sampling without replacement: each film draws random^(1/weight), and the highest draws win
        let sampled = available
            .map { (id: $0.id, key: pow(Double.random(in: Double.leastNonzeroMagnitude...1), 1 / $0.weight)) }
            .sorted { $0.key > $1.key }
            .prefix(Self.seedsPerBatch)
            .map(\.id)
        let seeds = liked + sampled
        usedSeeds.formUnion(seeds)
        return seeds
    }

    var topMovie: Movie? { deck.first }

    /// Call whenever the user's lists change, so cards for films they've since added disappear
    func update(listedIDs: Set<Int64>, seedPool: [(id: Int64, weight: Double)]) {
        self.listedIDs = listedIDs
        self.seedPool = seedPool
        deck.removeAll { listedIDs.contains($0.id) }
        refillIfNeeded()
    }

    func pass(_ movie: Movie) {
        deck.removeAll { $0.id == movie.id }
        passedIDs.insert(movie.id)
        UserDefaults.standard.set(passedIDs.map { Int($0) }, forKey: Self.passedKey)
        learn(from: movie, .skipped)
        refillIfNeeded()
    }

    func dislike(_ movie: Movie) {
        deck.removeAll { $0.id == movie.id }
        dislikedIDs.insert(movie.id)
        UserDefaults.standard.set(dislikedIDs.map { Int($0) }, forKey: Self.dislikedKey)
        learn(from: movie, .disliked)
        refillIfNeeded()
    }

    /// Removes the card straight away; if saving fails, the card comes back on top
    func add(_ movie: Movie, to list: CDMovieList, context: NSManagedObjectContext, completion: @escaping (CDMovie?) -> Void) {
        deck.removeAll { $0.id == movie.id }
        listedIDs.insert(movie.id)
        learn(from: movie, .liked)
        refillIfNeeded()
        list.addMovie(movie, context: context) { newMovie in
            if newMovie == nil {
                withAnimation(Theme.spring) {
                    self.listedIDs.remove(movie.id)
                    self.deck.insert(movie, at: 0)
                }
            }
            completion(newMovie)
        }
    }

    /// AI picks take a few seconds to start arriving, so the next batch is fetched while plenty of cards remain
    private var refillThreshold: Int {
        Personalization.useAI && aiAvailable ? 12 : 5
    }

    private func saveDeck() {
        if let data = try? JSONEncoder().encode(Array(deck.prefix(Self.savedDeckLimit))) {
            UserDefaults.standard.set(data, forKey: Self.deckKey)
        }
    }

    func showSkippedAgain() {
        usedSeeds = []
        resetAI()
        passedIDs = []
        UserDefaults.standard.removeObject(forKey: Self.passedKey)
        page = 1
        isExhausted = false
        deck = []
        loadMore()
    }

    /// Shows only films in these genres (any of them), or goes back to automatic when empty. Starts the deck over
    func setGenreFilter(_ genres: Set<Int>) {
        guard genres != genreFilter else { return }
        genreFilter = genres
        UserDefaults.standard.set(Array(genres), forKey: Self.genreFilterKey)
        sourceChanged()
    }

    /// Starts the deck over after switching between AI picks and TMDb recommendations
    func sourceChanged() {
        usedSeeds = []
        resetAI()
        page = 1
        isExhausted = false
        loadFailed = false
        deck = []
        loadMore()
    }

    /// Forgets everything learned from swipes and starts the deck over
    func resetProfile() {
        usedSeeds = []
        resetAI()
        profile = TasteProfile()
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        dislikedIDs = []
        UserDefaults.standard.removeObject(forKey: Self.dislikedKey)
        page = 1
        isExhausted = false
        deck = []
        loadMore()
    }

    private func learn(from movie: Movie, _ reaction: DiscoverReaction) {
        profile.record(movie, reaction)
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
    }

    func retry() {
        loadFailed = false
        loadMore()
    }

    private func resetAI() {
        loadGeneration += 1
        // Any load still in flight belongs to the old deck and will be ignored
        isLoading = false
        aiAvailable = true
        aiEmptyBatches = 0
        aiSuggestedTitles = []
        shownIDs = []
    }

    // Puts the films that best match the profile first, while spreading out similar ones: each genre a
    // film shares with the two cards before it counts against it. The server's order still counts a little
    private func orderedByTaste(_ movies: [Movie]) -> [Movie] {
        var remaining = movies.enumerated().map {
            (movie: $0.element, score: profile.affinity(for: $0.element) - Double($0.offset) * 0.05)
        }
        var ordered: [Movie] = []
        var recentGenres: [Set<Int>] = []
        while !remaining.isEmpty {
            let recent = recentGenres.suffix(2).reduce(into: Set<Int>()) { $0.formUnion($1) }
            func adjusted(_ candidate: (movie: Movie, score: Double)) -> Double {
                candidate.score - 0.6 * Double(recent.intersection(candidate.movie.genre_ids ?? []).count)
            }
            let best = remaining.indices.max { adjusted(remaining[$0]) < adjusted(remaining[$1]) }!
            let pick = remaining.remove(at: best)
            ordered.append(pick.movie)
            recentGenres.append(Set(pick.movie.genre_ids ?? []))
        }
        return ordered
    }

    private func refillIfNeeded() {
        if deck.count < refillThreshold {
            loadMore()
        }
    }

    private func loadMore() {
        guard !isLoading, !isExhausted, !loadFailed else { return }
        if Personalization.useAI && aiAvailable {
            loadFromAI()
        } else {
            loadFromTMDb()
        }
    }

    private func isFresh(_ movie: Movie) -> Bool {
        !listedIDs.contains(movie.id) && !passedIDs.contains(movie.id) && !dislikedIDs.contains(movie.id) && !shownIDs.contains(movie.id)
            && !deck.contains { $0.id == movie.id }
            // The server and the AI are asked for these genres too; this catches any that slip through
            && (genreFilter.isEmpty || !genreFilter.isDisjoint(with: movie.genre_ids ?? []))
    }

    private func deal(_ movies: [Movie]) {
        shownIDs.formUnion(movies.map(\.id))
        withAnimation(Theme.spring) {
            deck.append(contentsOf: movies)
        }
    }

    private func loadFromAI() {
        isLoading = true
        let film = { (recent: TasteProfile.RecentFilm) in AIDiscoverRequest.Film(title: recent.title, year: recent.year) }
        let genreName = { (id: Int) in TasteProfile.genreNames[id] }
        let leanings = profile.genreLeanings
        let request = AIDiscoverRequest(
            liked: profile.recentLiked.map(film),
            passed: profile.recentPassed.map(film),
            disliked: profile.recentDisliked.map(film),
            favorite_genres: leanings.towards.compactMap(genreName),
            avoided_genres: leanings.awayFrom.compactMap(genreName),
            required_genres: genreFilter.sorted().compactMap(genreName),
            swipe_count: profile.swipeCount,
            like_count: profile.likeCount,
            region: Locale.current.region?.identifier,
            language: Locale.current.language.languageCode?.identifier,
            age_range: Personalization.value(for: Personalization.ageRangeKey),
            pronouns: Personalization.value(for: Personalization.pronounsKey),
            already_suggested: Array(aiSuggestedTitles.suffix(400)),
            exclude_ids: Array(dislikedIDs.union(passedIDs).union(shownIDs).prefix(5000)),
            count: 20
        )
        let generation = loadGeneration
        var freshCount = 0
        // Films arrive one at a time and are dealt straight away, in the AI's order (it balances close
        // matches with adventurous picks)
        APIService.shared.aiDiscoverStream(request, onMovie: { movie in
            guard generation == self.loadGeneration else { return }
            self.aiSuggestedTitles.append(movie.title)
            if self.isFresh(movie) {
                freshCount += 1
                self.deal([movie])
            }
        }) { result in
            guard generation == self.loadGeneration else { return }
            self.isLoading = false
            switch result {
            case .success:
                self.aiEmptyBatches = freshCount == 0 ? self.aiEmptyBatches + 1 : 0
                if self.aiEmptyBatches >= 2 {
                    self.aiAvailable = false
                }
            case .failure(let error):
                print("AI discover unavailable, using TMDb recommendations:", error.localizedDescription)
                self.aiAvailable = false
            }
            self.refillIfNeeded()
        }
    }

    private func loadFromTMDb() {
        isLoading = true
        // A chosen genre beats a learned dislike of it
        let chosen = !genreFilter.isEmpty
        APIService.shared.discoverMovies(
            seeds: nextSeeds(),
            genres: chosen ? genreFilter.sorted() : profile.favoriteGenres,
            avoidGenres: profile.avoidedGenres.filter { !genreFilter.contains($0) },
            onlyGenres: chosen,
            page: page
        ) { [generation = loadGeneration] result in
            guard generation == self.loadGeneration else { return }
            self.isLoading = false
            switch result {
            case .success(let movies):
                self.page += 1
                self.deal(self.orderedByTaste(movies.filter(self.isFresh)))
                if movies.isEmpty || self.page > Self.maxPages {
                    self.isExhausted = true
                } else {
                    // Most of a page can be filtered out, so keep going until there's a few cards ready
                    self.refillIfNeeded()
                }
            case .failure(let error):
                print("Discover error:", error.localizedDescription)
                self.loadFailed = true
            }
        }
    }
}
