//
//  TasteComparisonView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI

/// "Your Taste vs Your Friend's": the user's lists next to a friend's (the lists that friend lets them see): how
/// alike their taste is, their stats side by side, genres, the films both have ranked, and top 50 against top 50.
/// Worked out on this device from data the user can already see
struct TasteComparisonView: View {
    let friend: UserSummary
    let friendLists: [FriendLists.List]

    @FetchRequest(fetchRequest: CDMovieList.fetch()) private var movieLists: FetchedResults<CDMovieList>
    @ObservedObject private var social = SocialStore.shared
    // Bumped as TMDb info arrives, so genres and scores fill in
    @State private var infoVersion = 0

    private static let topCount = StatsSummary.topCount

    private var mine: [StatList] {
        movieLists.map { list in
            StatList(films: list.movies.sorted { $0.rank < $1.rank }.map(StatFilm.init), ranked: ListRanking.isRanked(list.id))
        }
    }

    private var theirs: [StatList] { friendLists.map(StatList.init) }

    var body: some View {
        _ = infoVersion
        let comparison = Comparison(mine: mine, theirs: theirs, info: MovieInfoCache.shared.info(for:))
        return ScrollView {
            VStack(spacing: 18) {
                matchCard(comparison)
                    .appearAnimation()
                sideBySide(comparison)
                    .appearAnimation(delay: 0.05)
                if !comparison.genres.isEmpty {
                    genresCard(comparison)
                        .appearAnimation(delay: 0.1)
                }
                if !comparison.bothRanked.isEmpty {
                    bothRankedCard(comparison)
                        .appearAnimation(delay: 0.14)
                }
                topFiftyCard(comparison)
                    .appearAnimation(delay: 0.18)
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Your Taste vs Your Friend's")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadInfo)
    }

    private var friendName: String { "@\(friend.handle)" }

    // MARK: Cards

    private func matchCard(_ comparison: Comparison) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Avatar(name: social.profile?.display_name ?? "You", size: 56, version: social.profile?.avatar_version)
                ZStack {
                    Circle()
                        .stroke(Theme.textPrimary.opacity(0.12), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: comparison.match)
                        .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.8), value: comparison.match)
                    VStack(spacing: 0) {
                        Text("\(Int((comparison.match * 100).rounded()))%")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundColor(Theme.textPrimary)
                            .contentTransition(.numericText())
                        Text("match")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .frame(width: 92, height: 92)
                Avatar(name: friend.display_name, size: 56, handle: friend.handle, version: friend.avatar_version)
            }
            Text(matchLine(comparison))
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .cardStyle(cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }

    private func matchLine(_ comparison: Comparison) -> String {
        let common = comparison.sharedCount
        let films = common == 1 ? "1 film" : "\(common) films"
        switch comparison.match {
        case 0.75...: return "Taste twins. You and \(friendName) have \(films) in common."
        case 0.5..<0.75: return "Plenty in common: \(films) in both your lists, and similar genres."
        case 0.3..<0.5: return "Some overlap: \(films) in both your lists."
        default: return "Different tastes, which makes for good recommendations. \(films.capitalized) in common."
        }
    }

    private func sideBySide(_ comparison: Comparison) -> some View {
        let me = comparison.mySummary, them = comparison.theirSummary
        let score = { (value: Double?) in value.map { String(format: "%.1f", $0) } ?? "—" }
        return VStack(spacing: 0) {
            HStack {
                Text("")
                    .frame(maxWidth: .infinity, alignment: .leading)
                columnHeader("You")
                columnHeader(friendName)
            }
            .padding(.bottom, 8)
            statRow("Films & shows", me.filmCount.formatted(), them.filmCount.formatted())
            statRow("Watched", me.watchedCount.formatted(), them.watchedCount.formatted())
            statRow("Top decade", me.topDecade ?? "—", them.topDecade ?? "—")
            statRow("Top genre", me.topGenre ?? "—", them.topGenre ?? "—")
            statRow("Top language", me.topLanguage ?? "—", them.topLanguage ?? "—")
            statRow("Top \(Self.topCount) on TMDb", score(me.topAverage), score(them.topAverage), last: true)
        }
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.heavy))
            .foregroundStyle(Theme.accentGradient)
            .lineLimit(1)
            .frame(width: 96)
    }

    private func statRow(_ label: String, _ mine: String, _ theirs: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(mine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 96)
                Text(theirs)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 96)
            }
            .padding(.vertical, 9)
            if !last { Divider() }
        }
    }

    private func genresCard(_ comparison: Comparison) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Genres", systemImage: "theatermasks.fill")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                legend("You", style: AnyShapeStyle(Theme.accentGradient))
                legend(friendName, style: AnyShapeStyle(Theme.textSecondary))
            }
            ForEach(comparison.genres, id: \.name) { genre in
                VStack(alignment: .leading, spacing: 5) {
                    Text(genre.name)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    bar(genre.mine, style: AnyShapeStyle(Theme.accentGradient))
                    bar(genre.theirs, style: AnyShapeStyle(Theme.textSecondary))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(genre.name): \(Int(genre.mine * 100))% of yours, \(Int(genre.theirs * 100))% of \(friendName)'s")
            }
        }
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    private func legend(_ title: String, style: AnyShapeStyle) -> some View {
        HStack(spacing: 4) {
            Circle().fill(style).frame(width: 8, height: 8)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    // A share of someone's films, 0...1, with the percentage after it
    private func bar(_ share: Double, style: AnyShapeStyle) -> some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                Capsule()
                    .fill(style)
                    .frame(width: max(proxy.size.width * share, 4))
            }
            .frame(height: 8)
            Text("\(Int((share * 100).rounded()))%")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(Theme.textSecondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func bothRankedCard(_ comparison: Comparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You Both Ranked", systemImage: "person.2.fill")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            ForEach(comparison.bothRanked.prefix(10), id: \.film.tmdbID) { entry in
                HStack(spacing: 12) {
                    PosterImage(path: entry.film.posterPath, cornerRadius: 6, size: .small)
                        .frame(width: 36, height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.film.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Text("#\(entry.myRank) for you · #\(entry.theirRank) for \(friendName)")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    private func topFiftyCard(_ comparison: Comparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Top \(Self.topCount) vs Top \(Self.topCount)", systemImage: "list.number")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            Text("From each of your biggest ranked lists. Films you both have are highlighted.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            HStack(alignment: .top, spacing: 12) {
                topColumn("You", films: comparison.myTop, shared: comparison.sharedIDs)
                topColumn(friendName, films: comparison.theirTop, shared: comparison.sharedIDs)
            }
        }
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    private func topColumn(_ title: String, films: [StatFilm], shared: Set<Int64>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.accentGradient)
                .lineLimit(1)
            if films.isEmpty {
                Text("No ranked list")
                    .font(.caption)
                    .foregroundColor(Theme.textTertiary)
            }
            ForEach(Array(films.enumerated()), id: \.element.tmdbID) { index, film in
                let both = shared.contains(film.tmdbID)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.heavy))
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: 20, alignment: .trailing)
                    Text(film.title)
                        .font(.caption.weight(both ? .bold : .regular))
                        .foregroundStyle(both ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textPrimary))
                        .lineLimit(1)
                }
                .accessibilityLabel("\(index + 1), \(film.title)\(both ? ", in both" : "")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadInfo() {
        let ids = mine.flatMap { $0.films.map(\.tmdbID) } + theirs.flatMap { $0.films.map(\.tmdbID) }
        MovieInfoCache.shared.fetchMissing(ids, onBatch: { infoVersion += 1 }, completion: { infoVersion += 1 })
    }
}

/// The numbers behind Your Taste vs Your Friend's
private struct Comparison {
    struct Genre {
        let name: String
        // Each person's share of their films in this genre, 0...1
        let mine: Double
        let theirs: Double
    }

    let mySummary: StatsSummary
    let theirSummary: StatsSummary
    let myTop: [StatFilm]
    let theirTop: [StatFilm]
    let sharedIDs: Set<Int64>
    let sharedCount: Int
    // Films in both people's main ranking, the ones both rank highest first
    let bothRanked: [(film: StatFilm, myRank: Int, theirRank: Int)]
    let genres: [Genre]
    // How alike their taste is, 0...1
    let match: Double

    init(mine: [StatList], theirs: [StatList], info: @escaping (Int64) -> MovieInfo?) {
        mySummary = StatsSummary(lists: mine, info: info)
        theirSummary = StatsSummary(lists: theirs, info: info)
        let myRanking = StatsSummary.mainRanking(mine)
        let theirRanking = StatsSummary.mainRanking(theirs)
        myTop = Array(myRanking.prefix(StatsSummary.topCount))
        theirTop = Array(theirRanking.prefix(StatsSummary.topCount))

        let myFilms = Self.unique(mine), theirFilms = Self.unique(theirs)
        let shared = Set(myFilms.keys).intersection(theirFilms.keys)
        sharedIDs = shared
        sharedCount = shared.count

        let theirPlaces = Dictionary(theirRanking.enumerated().map { ($1.tmdbID, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        bothRanked = myRanking.enumerated().compactMap { index, film in
            theirPlaces[film.tmdbID].map { (film: film, myRank: index + 1, theirRank: $0) }
        }
        .sorted { $0.myRank + $0.theirRank < $1.myRank + $1.theirRank }

        let myGenres = Self.genreCounts(Array(myFilms.values), info: info)
        let theirGenres = Self.genreCounts(Array(theirFilms.values), info: info)
        let myTotal = max(Double(myFilms.count), 1), theirTotal = max(Double(theirFilms.count), 1)
        var shares: [Genre] = []
        for id in Set(myGenres.keys).union(theirGenres.keys) {
            guard let name = TasteProfile.genreNames[id] else { continue }
            let mine: Double = Double(myGenres[id] ?? 0) / myTotal
            let theirs: Double = Double(theirGenres[id] ?? 0) / theirTotal
            shares.append(Genre(name: name, mine: mine, theirs: theirs))
        }
        // The genres that matter most to the two of them together
        genres = Array(shares.sorted { $0.mine + $0.theirs > $1.mine + $1.theirs }.prefix(6))

        // Mostly how alike the mix of genres is, then eras, plus a boost for films both have
        let decade = { (films: [StatFilm]) in Dictionary(grouping: films.compactMap(\.decade), by: { $0 }).mapValues(\.count) }
        let genreSimilarity = Self.cosine(myGenres, theirGenres)
        let decadeSimilarity = Self.cosine(decade(Array(myFilms.values)), decade(Array(theirFilms.values)))
        let overlap = min(Double(shared.count) / max(Double(min(myFilms.count, theirFilms.count)), 1) * 2, 1)
        let hasGenres = !myGenres.isEmpty && !theirGenres.isEmpty
        match = hasGenres
            ? 0.5 * genreSimilarity + 0.25 * decadeSimilarity + 0.25 * overlap
            : 0.5 * decadeSimilarity + 0.5 * overlap
    }

    private static func unique(_ lists: [StatList]) -> [Int64: StatFilm] {
        var films: [Int64: StatFilm] = [:]
        for list in lists {
            for film in list.films where films[film.tmdbID] == nil { films[film.tmdbID] = film }
        }
        return films
    }

    private static func genreCounts(_ films: [StatFilm], info: (Int64) -> MovieInfo?) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for film in films {
            for genre in info(film.tmdbID)?.genres ?? [] { counts[genre, default: 0] += 1 }
        }
        return counts
    }

    // 1 when two people's counts are in the same proportions, 0 when they share nothing
    private static func cosine<Key: Hashable>(_ a: [Key: Int], _ b: [Key: Int]) -> Double {
        let dot = a.reduce(0.0) { $0 + Double($1.value * (b[$1.key] ?? 0)) }
        let length = { (v: [Key: Int]) in sqrt(v.values.reduce(0.0) { $0 + Double($1 * $1) }) }
        let lengths = length(a) * length(b)
        return lengths > 0 ? dot / lengths : 0
    }
}
