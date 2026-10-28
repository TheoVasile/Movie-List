//
//  DiscoverViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI
import Combine
import CoreData

/// The user's AI settings, and optional details they can share to personalise AI picks in Discover.
/// One setting, "Allow AI features", decides whether anything is sent to the AI; Discover then lets the
/// user choose AI Picks or Classic recommendations, but only while AI is allowed. Everything here stays on
/// this device and is only sent along with AI requests, apart from the allowed setting itself, which the
/// server keeps so a friend's Movie Night can check both people agreed, and the birthday, which is saved
/// with the account so it isn't lost with the app
enum Personalization {
    // Whether the user allows AI features at all
    static let aiAllowedKey = "ai.allowed"
    // Which source Discover uses while AI is allowed: AI Picks (true) or Classic (false)
    static let useAIKey = "discover.useAI"
    // Whether the user has been asked about AI yet
    static let aiConsentAskedKey = "discover.aiConsentAsked"
    static let under18 = "Under 18"
    // Earlier builds asked for an age range. No longer shown, but still used when there's no birthday, so
    // anyone who said they were under 18 keeps AI switched off
    static let ageRangeKey = "personalization.ageRange"
    // The user's birthday, as yyyy-MM-dd so it doesn't shift with time zones. A copy of the one saved with the
    // account, which only the user sees. Never sent to the AI: only the age range worked out from it goes with
    // AI Discover requests
    static let birthdayKey = "personalization.birthday"
    // The youngest anyone can be to use Marquee, per the Terms of Service
    static let minimumAge = 13
    static let pronounsKey = "personalization.pronouns"
    static let notShared = "Prefer not to say"
    // The age ranges the AI is told, each with the youngest age in it
    static let ageRanges: [(range: String, from: Int)] = [
        (under18, 0), ("18–24", 18), ("25–34", 25), ("35–44", 35), ("45–54", 45), ("55–64", 55), ("65+", 65),
    ]
    static let pronouns = [notShared, "She/Her", "He/Him", "They/Them", "She/They", "He/They", "Xe/Xem", "Ze/Hir", "It/Its"]

    /// Whether AI features may be used. Never for under-18s
    static var aiAllowed: Bool {
        UserDefaults.standard.bool(forKey: aiAllowedKey) && !isUnder18
    }

    /// Whether Discover uses AI Picks right now
    static var useAI: Bool {
        aiAllowed && UserDefaults.standard.bool(forKey: useAIKey)
    }

    /// Earlier builds had one switch, "AI Picks in Discover", that was both the user's agreement to AI and
    /// Discover's source. Anyone who turned it on had agreed, so AI stays allowed for them
    static func migrateAIConsent() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: aiAllowedKey) == nil, defaults.bool(forKey: useAIKey) {
            defaults.set(true, forKey: aiAllowedKey)
        }
    }

    /// Tells the server whether the user allows AI, so friends' Movie Nights can check it
    /// Under-18s have AI switched off, so turning 18 lets them turn it on but never turns it on by itself
    static func syncAIAllowed() {
        if isUnder18 {
            UserDefaults.standard.set(false, forKey: aiAllowedKey)
        }
        APIService.shared.setAIAllowed(aiAllowed) { _ in }
    }

    /// AI picks are never used for under-18s
    static var isUnder18: Bool {
        ageRange == under18
    }

    /// The age range sent with AI Discover requests: worked out from the birthday when there is one,
    /// otherwise the range chosen in earlier builds, otherwise not shared
    static var ageRange: String {
        let defaults = UserDefaults.standard
        return ageRange(birthday: defaults.string(forKey: birthdayKey) ?? "",
                        legacy: defaults.string(forKey: ageRangeKey) ?? notShared)
    }

    /// The same, from the stored values, so views watching them with @AppStorage update when they change
    static func ageRange(birthday: String, legacy: String, today: Date = Date()) -> String {
        guard let date = birthdayDate(birthday) else { return legacy }
        let years = age(on: today, bornOn: date)
        return ageRanges.last { years >= $0.from }?.range ?? under18
    }

    /// Whole years old on a day. Someone born on 29 February turns a year older on 1 March in other years
    static func age(on today: Date, bornOn birthday: Date) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let born = calendar.dateComponents([.year, .month, .day], from: birthday)
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let bornYear = born.year, let year = now.year else { return 0 }
        let hadBirthday = (now.month ?? 1, now.day ?? 1) >= (born.month ?? 1, born.day ?? 1)
        return year - bornYear - (hadBirthday ? 0 : 1)
    }

    private static let birthdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The stored birthday as a date, or nil when there isn't one
    static func birthdayDate(_ stored: String) -> Date? {
        stored.isEmpty ? nil : birthdayFormatter.date(from: stored)
    }

    /// A birthday as it's stored
    static func birthdayString(_ date: Date) -> String {
        birthdayFormatter.string(from: date)
    }

    /// Keeps the birthday on this iPhone the same as the one saved with the account, so it comes back after
    /// reinstalling. A birthday added before it was saved with the account goes up to the account instead
    static func mirrorBirthday(from profile: UserProfile) {
        let defaults = UserDefaults.standard
        let local = defaults.string(forKey: birthdayKey) ?? ""
        if let saved = profile.birthday, birthdayDate(saved) != nil {
            guard saved != local else { return }
            defaults.set(saved, forKey: birthdayKey)
            // A birthday replaces an age range chosen in earlier builds
            defaults.removeObject(forKey: ageRangeKey)
        } else if !local.isEmpty {
            APIService.shared.setBirthday(local) { _ in }
        }
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

/// What Discover is limited to, beyond genres: films in some languages, streaming on some services, or
/// recommended from one list only. Kept on this device
/// What Discover deals: films, TV shows or both
enum DiscoverKind: String, CaseIterable, Identifiable {
    case all, movie, tv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Movies & TV"
        case .movie: return "Movies"
        case .tv: return "TV Shows"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "rectangle.stack"
        case .movie: return "film"
        case .tv: return "tv"
        }
    }
}

struct DiscoverFilters: Codable, Equatable {
    var languages: [String] = []
    var services: [StreamingService] = []
    // The lists Discover is based on, with their names for the summary; empty means all of them
    var listIDs: [Int64] = []
    var listNames: [String] = []

    var isEmpty: Bool { languages.isEmpty && services.isEmpty && listIDs.isEmpty }

    init() {}

    // Filters saved before several lists could be picked had a single listID and listName
    private enum CodingKeys: String, CodingKey { case languages, services, listIDs, listNames, listID, listName }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? []
        services = try container.decodeIfPresent([StreamingService].self, forKey: .services) ?? []
        listIDs = try container.decodeIfPresent([Int64].self, forKey: .listIDs)
            ?? (try container.decodeIfPresent(Int64.self, forKey: .listID)).map { [$0] } ?? []
        listNames = try container.decodeIfPresent([String].self, forKey: .listNames)
            ?? (try container.decodeIfPresent(String.self, forKey: .listName)).map { [$0] } ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(languages, forKey: .languages)
        try container.encode(services, forKey: .services)
        try container.encode(listIDs, forKey: .listIDs)
        try container.encode(listNames, forKey: .listNames)
    }

    /// Languages people most often filter by, as TMDb's original-language codes
    static let commonLanguages = ["en", "fr", "es", "it", "de", "ja", "ko", "zh", "hi", "pt", "sv", "da", "no", "ru", "fa", "tr", "pl", "th", "ta", "te"]

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

/// How the user responded to a Discover card
enum DiscoverReaction {
    // Added it to a list from Discover: swiped right, or tapped Add. Likes from earlier builds, which had a
    // like button, are kept as likes too
    case liked
    // Swiped left or tapped Skip: "haven't seen it" or "not sure", which says nothing about their taste
    case skipped
    // Tapped Not for Me
    case disliked
}

/// Discover's Quick Add: swiping right (or Add) sends the film straight to one chosen list, instead of asking which
/// lists each time. Asked about the first time Discover opens. Settings belong to the account
enum QuickAdd {
    static let onKey = "discoverQuickAdd"
    static let listIDKey = "discoverQuickAddListID"
    static let placementKey = "discoverQuickAddPlacement"
    // Whether the user has chosen between Quick Add and asking each time. Builds that removed Quick Add cleared
    // its settings, so everyone who used it then is asked again
    static let askedKey = "discoverQuickAddAsked"

    /// Where a Quick Added film goes in a ranked list. Unranked lists just put it at the end
    enum Placement: String, CaseIterable, Identifiable {
        case bottom, ai, compare

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bottom: return "At the Bottom"
            case .ai: return "Where AI Places It"
            case .compare: return "Compare to Place It"
            }
        }

        var explanation: String {
            switch self {
            case .bottom: return "Fastest. Rank it later from the list"
            case .ai: return "AI picks its spot from the films around it"
            case .compare: return "A few quick head-to-heads after each add"
            }
        }

        var icon: String {
            switch self {
            case .bottom: return "arrow.down.to.line"
            case .ai: return "sparkles"
            case .compare: return "arrow.left.arrow.right"
            }
        }
    }

    /// The list to suggest the first time: one that looks like a watchlist, if there is one
    static func suggestedList(in lists: [CDMovieList]) -> CDMovieList? {
        let names = ["watchlist", "watch list", "to watch", "to-watch", "want to watch"]
        return lists.first { list in names.contains { (list.name ?? "").localizedCaseInsensitiveContains($0) } }
    }
}

/// What Discover has learned from the user's likes (films added from Discover) and dislikes (Not for Me). Kept
/// on this device, as TMDb film ids (the likes, dislikes and skips themselves are also kept with the account, see
/// DiscoverReactionSync), a score per genre (liking a film raises its genres' scores, disliking it
/// lowers them; skips are never recorded) and the titles of recent likes and dislikes, which AI Discover uses when the user's lists are empty
struct TasteProfile: Codable {
    struct RecentFilm: Codable, Equatable {
        let title: String
        let year: String
    }

    private(set) var genreScores: [Int: Double] = [:]
    // Most recent first
    private(set) var likedMovieIDs: [Int64] = []
    private(set) var recentLiked: [RecentFilm] = []
    private(set) var recentDisliked: [RecentFilm] = []
    private(set) var swipeCount = 0
    private(set) var likeCount = 0

    // Plenty for the AI to learn from: about 10 tokens a film
    private static let recentLimit = 500

    init() {}

    // Profiles saved before recent swipes were kept don't have them. Ones from before skips stopped counting
    // also have the skipped films, which are no longer read and are dropped the next time the profile is saved
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        genreScores = try container.decode([Int: Double].self, forKey: .genreScores)
        likedMovieIDs = try container.decode([Int64].self, forKey: .likedMovieIDs)
        recentLiked = try container.decodeIfPresent([RecentFilm].self, forKey: .recentLiked) ?? []
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

        switch reaction {
        case .skipped:
            // A skip teaches nothing, so it isn't even counted as a swipe
            return
        case .liked:
            swipeCount += 1
            likeCount += 1
            likedMovieIDs.removeAll { $0 == movie.id }
            likedMovieIDs = Array(([movie.id] + likedMovieIDs).prefix(20))
            recentLiked = Array(([film] + recentLiked).prefix(Self.recentLimit))
        case .disliked:
            swipeCount += 1
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

    /// Undoes what one like or "not for me" taught the profile, when the user takes it back later
    mutating func forget(_ movie: Movie, liked: Bool) {
        let film = RecentFilm(title: movie.title, year: Theme.year(from: movie.release_date))
        if liked {
            likedMovieIDs.removeAll { $0 == movie.id }
            if let index = recentLiked.firstIndex(of: film) {
                recentLiked.remove(at: index)
                likeCount = max(likeCount - 1, 0)
            }
        } else if let index = recentDisliked.firstIndex(of: film) {
            recentDisliked.remove(at: index)
        }
        for genre in movie.genre_ids ?? [] {
            genreScores[genre, default: 0] -= liked ? 1 : -1
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

/// Film ids kept on this device, oldest first, up to a limit: past it, the oldest are forgotten so what
/// Discover keeps doesn't grow forever
struct RecentIDs {
    private(set) var order: [Int64]
    private(set) var set: Set<Int64>
    let limit: Int

    init(_ stored: [Int], limit: Int) {
        self.limit = limit
        order = Array(stored.map(Int64.init).suffix(limit))
        set = Set(order)
    }

    func contains(_ id: Int64) -> Bool { set.contains(id) }

    mutating func insert(_ id: Int64) {
        if set.contains(id) { order.removeAll { $0 == id } }
        order.append(id)
        set.insert(id)
        if order.count > limit {
            let dropped = order.prefix(order.count - limit)
            order.removeFirst(dropped.count)
            set.subtract(dropped)
        }
    }

    mutating func remove(_ id: Int64) {
        guard set.remove(id) != nil else { return }
        order.removeAll { $0 == id }
    }

    var stored: [Int] { order.map(Int.init) }
}

class DiscoverViewModel: ObservableObject {
    /// Cards still to swipe, top card first
    @Published private(set) var deck: [Movie] = [] {
        // Saved so Discover opens with cards straight away next time
        didSet {
            saveDeck()
            logImpressionIfNeeded()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var isExhausted = false
    @Published private(set) var profile: TasteProfile

    private var page = 1
    // Films in the user's ranked lists, weighted by how highly they're ranked (and watched films from unranked
    // lists, lightly)
    private var seedPool: [(id: Int64, weight: Double)] = []
    // Films already used as seeds, so each batch draws on different ones
    private var usedSeeds: Set<Int64> = []
    // TMDb ids of every film already in one of the user's lists
    private var listedIDs: Set<Int64> = []
    // Films skipped, remembered across launches so they don't come back until "Show Skipped Films".
    // Only used to keep them out of the deck, never as a taste signal
    private var passedIDs: RecentIDs
    // Films disliked, which stay hidden even when skipped films are shown again
    private var dislikedIDs: RecentIDs
    // Films liked or added from Discover, which aren't shown again
    private var likedIDs: RecentIDs
    private var reactionsChanged: AnyCancellable? = nil
    // Whether to ask the AI for the next batch. Turned off for the session if the server says AI isn't
    // set up, the daily limit is reached, a request fails, or it keeps suggesting films already seen
    @Published private(set) var aiAvailable = true
    private var aiEmptyBatches = 0
    // Titles the AI has suggested this session, so it doesn't suggest them again
    private var aiSuggestedTitles: [String] = []
    // Every film dealt this session
    private var shownIDs: Set<Int64> = []
    // Where each card was dealt this session, first card 0, for analytics
    private var positions: [Int64: Int] = [:]
    private var dealtCount = 0
    // The last card logged as seen on top, so each is logged once each time it gets there
    private var impressionID: Int64? = nil
    // Genres the user chose to see; empty means automatic, tuned to their taste. Kept across launches
    @Published private(set) var genreFilter: Set<Int>
    @Published private(set) var filters: DiscoverFilters
    @Published private(set) var kind: DiscoverKind
    // The genres the lists Discover is based on have most of, top first. Used as Automatic's genres until the
    // swipes have taught it some
    @Published private(set) var listGenres: [Int] = []
    /// One card added, disliked or skipped, with what's needed to take it back
    struct UndoStep {
        let id = UUID()
        let movie: Movie
        let reaction: DiscoverReaction
        // The taste profile from before, put back on undo
        let profile: TasteProfile
        // For an add: whether the film was already liked, so undo leaves that older like alone, and the copy it
        // got in each list, which undo takes back out
        var wasLiked = false
        var added: [(list: CDMovieList, movie: CDMovie)] = []
    }

    // Recent adds, dislikes and skips, newest last, so they can be undone
    @Published private(set) var undoHistory: [UndoStep] = []
    // Adds still waiting on the server. Undo waits for them, so it never takes back a film that hasn't landed yet
    @Published private(set) var addsInFlight = 0
    private static let undoLimit = 20
    // How many skipped, disliked and liked films are remembered, most recent kept
    static let passedLimit = 2000
    static let dislikedLimit = 2000
    static let likedLimit = 1000

    private static let passedKey = "discover.passedMovieIDs"
    static let dislikedKey = "discover.dislikedMovieIDs"
    static let likedKey = "discover.likedMovieIDs"
    private static let genreFilterKey = "discover.genreFilter"
    private static let filtersKey = "discover.filters"
    private static let kindKey = "discover.kind"
    // With AI Picks and Movies & TV, whether the next batch is TV shows from TMDb
    private var tvTurn = false
    static let profileKey = "discover.tasteProfile"
    private static let maxPages = 30
    private static let deckKey = "discover.savedDeck"
    private static let savedDeckLimit = 30
    // Bumped whenever the deck starts over, so films from a load started before then are ignored
    private var loadGeneration = 0

    init() {
        passedIDs = RecentIDs(UserDefaults.standard.array(forKey: Self.passedKey) as? [Int] ?? [], limit: Self.passedLimit)
        dislikedIDs = RecentIDs(UserDefaults.standard.array(forKey: Self.dislikedKey) as? [Int] ?? [], limit: Self.dislikedLimit)
        likedIDs = RecentIDs(UserDefaults.standard.array(forKey: Self.likedKey) as? [Int] ?? [], limit: Self.likedLimit)
        genreFilter = Set(UserDefaults.standard.array(forKey: Self.genreFilterKey) as? [Int] ?? [])
        filters = UserDefaults.standard.data(forKey: Self.filtersKey)
            .flatMap { try? JSONDecoder().decode(DiscoverFilters.self, from: $0) } ?? DiscoverFilters()
        kind = UserDefaults.standard.string(forKey: Self.kindKey).flatMap(DiscoverKind.init) ?? .all
        profile = UserDefaults.standard.data(forKey: Self.profileKey)
            .flatMap { try? JSONDecoder().decode(TasteProfile.self, from: $0) } ?? TasteProfile()
        // The cards left last time, minus any since skipped or disliked; ones added to a list go once the lists sync
        let saved = UserDefaults.standard.data(forKey: Self.deckKey)
            .flatMap { try? JSONDecoder().decode([Movie].self, from: $0) } ?? []
        deck = saved.filter { !passedIDs.contains($0.id) && !dislikedIDs.contains($0.id) && !likedIDs.contains($0.id) }
        shownIDs = Set(deck.map(\.id))
        for movie in deck { notePosition(movie) }
        // A like or dislike taken back from the Liked & Not for Me screen
        reactionsChanged = DiscoverReactions.shared.changed.sink { [weak self] in self?.reloadReactions() }
    }

    private func reloadReactions() {
        dislikedIDs = RecentIDs(UserDefaults.standard.array(forKey: Self.dislikedKey) as? [Int] ?? [], limit: Self.dislikedLimit)
        likedIDs = RecentIDs(UserDefaults.standard.array(forKey: Self.likedKey) as? [Int] ?? [], limit: Self.likedLimit)
        profile = UserDefaults.standard.data(forKey: Self.profileKey)
            .flatMap { try? JSONDecoder().decode(TasteProfile.self, from: $0) } ?? TasteProfile()
        // Dislikes merged from the account, e.g. after a reinstall, take their cards out
        let hidden = deck.filter { dislikedIDs.contains($0.id) }
        if !hidden.isEmpty { deck.removeAll { dislikedIDs.contains($0.id) } }
    }

    private static let seedsPerBatch = 6
    private static let likedSeedsPerBatch = 2
    // A film just liked in Discover says most about what the user wants right now
    private static let likedSeedWeight = 1.5

    /// Picks the films to base the next batch on, each with how much it should count: up to two recently liked
    /// films, plus a rank-weighted sample from the ranked lists. Favourites are likelier, but any film can be
    /// picked, and no film is used again until the rest have been, so one film can't steer the whole deck
    private func nextSeeds() -> [(id: Int64, weight: Double)] {
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
        let weights = Dictionary(seedPool.map { ($0.id, $0.weight) }, uniquingKeysWith: max)
        let seeds = liked.map { (id: $0, weight: Self.likedSeedWeight) } + sampled.map { (id: $0, weight: weights[$0] ?? 1) }
        usedSeeds.formUnion(seeds.map(\.id))
        return seeds
    }

    var topMovie: Movie? { deck.first }

    /// What Automatic picks: genres learned from swipes, or the lists' own top genres until there are some
    var automaticGenres: [Int] {
        profile.favoriteGenres.isEmpty ? listGenres : profile.favoriteGenres
    }

    /// The genres most common in the films Discover is based on, from the TMDb info kept for list films
    func updateListGenres(for tmdbIDs: [Int64]) {
        var counts: [Int: Int] = [:]
        for id in tmdbIDs {
            for genre in MovieInfoCache.shared.info(for: id)?.genres ?? [] where genre != 10770 {
                counts[genre, default: 0] += 1
            }
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        if top != listGenres { listGenres = top }
    }

    /// Call whenever the user's lists change, so cards for films they've since added disappear
    func update(listedIDs: Set<Int64>, seedPool: [(id: Int64, weight: Double)]) {
        self.listedIDs = listedIDs
        self.seedPool = seedPool
        deck.removeAll { listedIDs.contains($0.id) }
        refillIfNeeded()
    }

    /// Skip: "haven't seen it" or "not sure". Only moves on: the film is kept out of the deck, but nothing is
    /// learned from it and it's never sent to the AI as a taste signal
    func skip(_ movie: Movie) {
        remember(movie, .skipped)
        deck.removeAll { $0.id == movie.id }
        passedIDs.insert(movie.id)
        UserDefaults.standard.set(passedIDs.stored, forKey: Self.passedKey)
        DiscoverReactionSync.shared.record(movie, .skipped)
        logSwipe(movie, .skipped)
        refillIfNeeded()
    }

    /// Not for Me: Classic avoids the film's genres once they add up, and the AI steers away from films like it
    func dislike(_ movie: Movie) {
        remember(movie, .disliked)
        deck.removeAll { $0.id == movie.id }
        dislikedIDs.insert(movie.id)
        UserDefaults.standard.set(dislikedIDs.stored, forKey: Self.dislikedKey)
        learn(from: movie, .disliked)
        DiscoverReactions.shared.add(movie, liked: false)
        DiscoverReactionSync.shared.record(movie, .disliked)
        logSwipe(movie, .disliked)
        refillIfNeeded()
    }

    // Adding a film from Discover is how the user likes it: the AI gets it as a liked film, and Classic leans
    // towards its genres and bases its next batches on it
    private func markLiked(_ movie: Movie) {
        likedIDs.insert(movie.id)
        UserDefaults.standard.set(likedIDs.stored, forKey: Self.likedKey)
        learn(from: movie, .liked)
        DiscoverReactions.shared.add(movie, liked: true)
        DiscoverReactionSync.shared.record(movie, .liked)
    }

    private func logSwipe(_ movie: Movie, _ reaction: DiscoverReaction) {
        AppAnalytics.log(.discoverSwipe(reaction, ai: usesAI, tmdbID: movie.id, source: analyticsSource(movie), position: position(of: movie)))
    }

    // MARK: Analytics

    // Why the card was picked, as the server said, or "ai" for an AI Pick
    private func analyticsSource(_ movie: Movie) -> String {
        movie.source ?? (movie.ai == true ? "ai" : "unknown")
    }

    private func notePosition(_ movie: Movie) {
        guard positions[movie.id] == nil else { return }
        positions[movie.id] = dealtCount
        dealtCount += 1
    }

    private func position(of movie: Movie) -> Int {
        positions[movie.id] ?? 0
    }

    /// Logs the top card once each time a new one gets there. Also called when Discover appears, for the card
    /// left on top last time
    func logImpressionIfNeeded() {
        guard let top = deck.first else {
            impressionID = nil
            return
        }
        guard top.id != impressionID else { return }
        impressionID = top.id
        AppAnalytics.log(.discoverImpression(tmdbID: top.id, source: analyticsSource(top), position: position(of: top), ai: usesAI))
    }

    /// Adds the film to every chosen list at once, however it was added from Discover: a swipe right, Add, or Add
    /// to Lists on its full details. It counts as one like, however many lists it goes in, and none if it was
    /// already liked. Removes the card straight away and calls back with the lists it was added to and the new copy
    /// in each, in the order given; if every add fails, the card and the like are taken back
    func add(_ movie: Movie, to lists: [CDMovieList], context: NSManagedObjectContext, completion: @escaping ([(list: CDMovieList, movie: CDMovie)]) -> Void) {
        deck.removeAll { $0.id == movie.id }
        listedIDs.insert(movie.id)
        let alreadyLiked = likedIDs.contains(movie.id)
        let profileBefore = profile
        var step = UndoStep(movie: movie, reaction: .liked, profile: profileBefore, wasLiked: alreadyLiked)
        undoHistory.append(step)
        if undoHistory.count > Self.undoLimit { undoHistory.removeFirst() }
        addsInFlight += 1
        if !alreadyLiked { markLiked(movie) }
        refillIfNeeded()
        // Lists the film was already in keep it on undo; only the copies made here are taken back out
        let alreadyIn = Set(lists.filter { list in list.movies.contains { Int64($0.tmdb_id) == movie.id } }.map(\.id))

        var added: [Int: CDMovie] = [:]
        let group = DispatchGroup()
        for (index, list) in lists.enumerated() {
            group.enter()
            list.addMovie(tmdbID: movie.id, context: context) { newMovie in
                added[index] = newMovie
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.addsInFlight -= 1
            let done = lists.indices.compactMap { index in added[index].map { (list: lists[index], movie: $0) } }
            if done.isEmpty {
                self.undoHistory.removeAll { $0.id == step.id }
                withAnimation(Theme.spring) {
                    self.listedIDs.remove(movie.id)
                    self.deck.insert(movie, at: 0)
                }
                if !alreadyLiked { self.forgetLike(movie, profile: profileBefore) }
            } else {
                if let index = self.undoHistory.firstIndex(where: { $0.id == step.id }) {
                    step.added = done.filter { !alreadyIn.contains($0.list.id) }
                    self.undoHistory[index] = step
                }
                AppAnalytics.log(.filmAdded(.discover))
                self.logSwipe(movie, .liked)
            }
            completion(done)
        }
    }

    /// AI picks take a few seconds to start arriving, so the next batch is fetched while plenty of cards remain
    private var refillThreshold: Int {
        usesAI ? 12 : 5
    }

    private func saveDeck() {
        if let data = try? JSONEncoder().encode(Array(deck.prefix(Self.savedDeckLimit))) {
            UserDefaults.standard.set(data, forKey: Self.deckKey)
        }
    }

    // Takes back a like that was only recorded for an add that failed
    private func forgetLike(_ movie: Movie, profile before: TasteProfile) {
        likedIDs.remove(movie.id)
        UserDefaults.standard.set(likedIDs.stored, forKey: Self.likedKey)
        DiscoverReactions.shared.remove(movie.id)
        DiscoverReactionSync.shared.remove(movie.id)
        profile = before
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
    }

    func showSkippedAgain() {
        usedSeeds = []
        resetAI()
        passedIDs = RecentIDs([], limit: Self.passedLimit)
        UserDefaults.standard.removeObject(forKey: Self.passedKey)
        page = 1
        isExhausted = false
        deck = []
        // The server keeps skips out of Discover too, so they're cleared there first. If that can't be sent now
        // it's queued and the batch is asked for anyway
        isLoading = true
        DiscoverReactionSync.shared.clearSkips { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.loadMore()
        }
    }

    /// Shows only films in these genres (any of them), or goes back to automatic when empty. Starts the deck over
    func setGenreFilter(_ genres: Set<Int>) {
        guard genres != genreFilter else { return }
        genreFilter = genres
        UserDefaults.standard.set(Array(genres), forKey: Self.genreFilterKey)
        sourceChanged()
    }

    private func remember(_ movie: Movie, _ reaction: DiscoverReaction) {
        undoHistory.append(UndoStep(movie: movie, reaction: reaction, profile: profile))
        if undoHistory.count > Self.undoLimit { undoHistory.removeFirst() }
    }

    var canUndo: Bool { !undoHistory.isEmpty && addsInFlight == 0 }

    /// Brings back the last added, disliked or skipped card, on top, as if it was never swiped. An add is also
    /// taken back out of the lists it went into; calls back with the names of any lists that couldn't let it go
    func undo(couldNotRemove: @escaping ([String]) -> Void = { _ in }) {
        guard addsInFlight == 0, let last = undoHistory.popLast() else { return }
        passedIDs.remove(last.movie.id)
        dislikedIDs.remove(last.movie.id)
        // Adding a film liked before leaves that older like in place
        let keepsLike = last.reaction == .liked && last.wasLiked
        if !keepsLike { likedIDs.remove(last.movie.id) }
        UserDefaults.standard.set(passedIDs.stored, forKey: Self.passedKey)
        UserDefaults.standard.set(dislikedIDs.stored, forKey: Self.dislikedKey)
        UserDefaults.standard.set(likedIDs.stored, forKey: Self.likedKey)
        if last.reaction != .skipped && !keepsLike { DiscoverReactions.shared.remove(last.movie.id) }
        // The account forgets it too; a like from before this add stays
        if !keepsLike { DiscoverReactionSync.shared.remove(last.movie.id) }
        if last.reaction == .liked {
            listedIDs.remove(last.movie.id)
            removeCopies(last.added, couldNotRemove: couldNotRemove)
        }
        profile = last.profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
        deck.removeAll { $0.id == last.movie.id }
        deck.insert(last.movie, at: 0)
    }

    // Takes an undone add back out of each list it went into. The lists sync once it's gone, which leaves the card
    // in place, since the film is no longer listed
    private func removeCopies(_ copies: [(list: CDMovieList, movie: CDMovie)], couldNotRemove: @escaping ([String]) -> Void) {
        var failed: [String] = []
        let group = DispatchGroup()
        for copy in copies {
            guard let context = copy.list.managedObjectContext, !copy.movie.isDeleted else { continue }
            group.enter()
            ListViewModel(movieList: copy.list, context: context).removeMovie(copy.movie) { removed in
                if !removed { failed.append(copy.list.name ?? "your list") }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !failed.isEmpty { couldNotRemove(failed) }
        }
    }

    /// Limits Discover by language, streaming service or list (empty to show everything). Starts the deck over
    func setFilters(_ newFilters: DiscoverFilters) {
        guard newFilters != filters else { return }
        filters = newFilters
        if let data = try? JSONEncoder().encode(newFilters) {
            UserDefaults.standard.set(data, forKey: Self.filtersKey)
        }
        sourceChanged()
    }

    /// Switches between films, TV shows or both. Starts the deck over
    func setKind(_ newKind: DiscoverKind) {
        guard newKind != kind else { return }
        kind = newKind
        UserDefaults.standard.set(newKind.rawValue, forKey: Self.kindKey)
        sourceChanged()
    }

    /// AI Picks are films only, so TV Shows always come from TMDb
    var usesAI: Bool {
        Personalization.useAI && aiAvailable && kind != .tv
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

    /// Forgets everything learned from likes and dislikes and starts the deck over
    func resetProfile() {
        usedSeeds = []
        resetAI()
        profile = TasteProfile()
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        dislikedIDs = RecentIDs([], limit: Self.dislikedLimit)
        UserDefaults.standard.removeObject(forKey: Self.dislikedKey)
        likedIDs = RecentIDs([], limit: Self.likedLimit)
        UserDefaults.standard.removeObject(forKey: Self.likedKey)
        DiscoverReactions.shared.clear()
        DiscoverReactionSync.shared.clearAll()
        page = 1
        isExhausted = false
        deck = []
        // The server keeps skips out of Discover too, so they're cleared there first. If that can't be sent now
        // it's queued and the batch is asked for anyway
        isLoading = true
        DiscoverReactionSync.shared.clearSkips { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.loadMore()
        }
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
        positions = [:]
        dealtCount = 0
        impressionID = nil
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

    /// The server's ranked feed is kept in its order, only spread out so two cards in a row don't share a main
    /// genre: when the next card would, the closest one after it that doesn't comes forward instead
    private func spreadOut(_ movies: [Movie]) -> [Movie] {
        var remaining = movies
        var ordered: [Movie] = []
        // How far ahead to look for a card to bring forward, so the server's order mostly holds
        let lookahead = 4
        while !remaining.isEmpty {
            let previous = (ordered.last ?? deck.last)?.genre_ids?.first
            let index = remaining.prefix(lookahead).firstIndex { previous == nil || $0.genre_ids?.first != previous } ?? 0
            ordered.append(remaining.remove(at: index))
        }
        return ordered
    }

    /// Whether the server ranked these itself (newer servers send a score or source with each film)
    private func serverRanked(_ movies: [Movie]) -> Bool {
        movies.contains { $0.score != nil || $0.source != nil }
    }

    private func refillIfNeeded() {
        if deck.count < refillThreshold {
            loadMore()
        }
    }

    private func loadMore() {
        guard !isLoading, !isExhausted, !loadFailed else { return }
        if usesAI {
            // AI Picks are films, so with Movies & TV every other batch is shows from TMDb
            if kind == .all && tvTurn {
                tvTurn = false
                loadFromTMDb(kind: .tv)
            } else {
                tvTurn = kind == .all
                loadFromAI()
            }
        } else {
            loadFromTMDb(kind: kind)
        }
    }

    private func isFresh(_ movie: Movie) -> Bool {
        !listedIDs.contains(movie.id) && !passedIDs.contains(movie.id) && !dislikedIDs.contains(movie.id) && !likedIDs.contains(movie.id)
            && !shownIDs.contains(movie.id)
            && !deck.contains { $0.id == movie.id }
            // A deck saved before switching to films or shows
            && (kind == .all || movie.isTV == (kind == .tv))
            // The server and the AI are asked for these genres and languages too; this catches any that slip through
            && (genreFilter.isEmpty || !genreFilter.isDisjoint(with: movie.genre_ids ?? []))
            && (filters.languages.isEmpty || filters.languages.contains(movie.original_language))
    }

    private func deal(_ movies: [Movie]) {
        shownIDs.formUnion(movies.map(\.id))
        movies.forEach(notePosition)
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
            // Most recent first. Skips aren't a taste signal, so they only go in exclude_ids, as ids
            liked: profile.recentLiked.map(film),
            disliked: profile.recentDisliked.map(film),
            favorite_genres: (leanings.towards.isEmpty ? listGenres : leanings.towards).compactMap(genreName),
            avoided_genres: leanings.awayFrom.compactMap(genreName),
            required_genres: genreFilter.sorted().compactMap(genreName),
            swipe_count: profile.swipeCount,
            like_count: profile.likeCount,
            region: Locale.current.region?.identifier,
            language: Locale.current.language.languageCode?.identifier,
            // Only the range, never the birthday it comes from
            age_range: Personalization.ageRange == Personalization.notShared ? nil : Personalization.ageRange,
            pronouns: Personalization.value(for: Personalization.pronounsKey),
            already_suggested: Array(aiSuggestedTitles.suffix(400)),
            exclude_ids: Array(dislikedIDs.set.union(likedIDs.set).union(passedIDs.set).union(shownIDs).prefix(5000)),
            count: 20,
            languages: filters.languages,
            providers: filters.services.map(\.id),
            provider_names: filters.services.map(\.name),
            list_ids: filters.listIDs
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
                AppAnalytics.log(.aiPickUsed(.discover))
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

    private func loadFromTMDb(kind: DiscoverKind) {
        isLoading = true
        // A chosen genre beats a learned dislike of it
        let chosen = !genreFilter.isEmpty
        APIService.shared.discoverMovies(
            seeds: nextSeeds(),
            kind: kind,
            genres: chosen ? genreFilter.sorted() : automaticGenres,
            avoidGenres: profile.avoidedGenres.filter { !genreFilter.contains($0) },
            onlyGenres: chosen,
            languages: filters.languages,
            providers: filters.services.map(\.id),
            page: page
        ) { [generation = loadGeneration] result in
            guard generation == self.loadGeneration else { return }
            self.isLoading = false
            switch result {
            case .success(let movies):
                self.page += 1
                let fresh = movies.filter(self.isFresh)
                // Older servers send TMDb's order, which is put in taste order here instead
                self.deal(self.serverRanked(movies) ? self.spreadOut(fresh) : self.orderedByTaste(fresh))
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
