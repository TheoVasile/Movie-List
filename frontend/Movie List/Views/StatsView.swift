//
//  StatsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import SwiftUI
import Charts

/// Numbers about the user's taste, worked out from the films in their lists and the TMDb info the app
/// already keeps for each film. Nothing new is sent anywhere
struct StatsSummary {
    struct Count: Identifiable {
        let label: String
        let count: Int
        var id: String { label }
    }

    struct Pick {
        let title: String
        let year: String
        let posterPath: String?
        let rank: Int
        let voteAverage: Double
    }

    let filmCount: Int
    let watchedCount: Int
    let listCount: Int
    let decades: [Count]
    let genres: [Count]
    let languages: [Count]
    // Average TMDb score of the user's top 50 against all their films
    let topAverage: Double?
    let overallAverage: Double?
    // A film the user ranks highly that TMDb's users rate low
    let underrated: Pick?
    // The highest-ranked film with the fewest TMDb ratings: the user's deepest cut
    let deepCut: Pick?

    private static let topCount = 50

    init(lists: [CDMovieList], info: @escaping (Int64) -> MovieInfo?) {
        // A film in several lists counts once
        var films: [Int64: CDMovie] = [:]
        for list in lists {
            for movie in list.movies where films[Int64(movie.tmdb_id)] == nil {
                films[Int64(movie.tmdb_id)] = movie
            }
        }
        let all = Array(films.values)
        filmCount = all.count
        watchedCount = all.filter(\.watched).count
        listCount = lists.count

        let decadeCounts = Dictionary(grouping: all.compactMap { movie -> Int? in
            guard let date = movie.release_date else { return nil }
            return Calendar.current.component(.year, from: date) / 10 * 10
        }, by: { $0 }).mapValues(\.count)
        decades = decadeCounts.sorted { $0.key < $1.key }.map { Count(label: "\($0.key)s", count: $0.value) }

        var genreCounts: [Int: Int] = [:]
        for movie in all {
            for genre in info(Int64(movie.tmdb_id))?.genres ?? [] {
                genreCounts[genre, default: 0] += 1
            }
        }
        genres = genreCounts.sorted { $0.value > $1.value }.prefix(8)
            .compactMap { id, count in TasteProfile.genreNames[id].map { Count(label: $0, count: count) } }

        let languageCounts = Dictionary(grouping: all.compactMap { $0.original_language }, by: { $0 }).mapValues(\.count)
        languages = languageCounts.sorted { $0.value > $1.value }.prefix(6).map { code, count in
            Count(label: Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased(), count: count)
        }

        // Ranks only mean something within one list, so taste is judged on the biggest one
        let ranked = (lists.max { $0.movies.count < $1.movies.count }?.movies ?? [])
            .sorted { $0.rank < $1.rank }
        let scored = { (movies: [CDMovie]) -> [Double] in
            movies.compactMap { movie in
                info(Int64(movie.tmdb_id)).flatMap { $0.voteCount >= 20 ? $0.voteAverage : nil }
            }
        }
        let average = { (scores: [Double]) -> Double? in scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count) }
        topAverage = average(scored(Array(ranked.prefix(Self.topCount))))
        overallAverage = average(scored(all))

        let pick = { (movie: CDMovie, info: MovieInfo) in
            Pick(title: movie.title ?? "", year: Theme.year(from: movie.release_date), posterPath: movie.poster_path,
                 rank: Int(movie.rank), voteAverage: info.voteAverage)
        }
        let topHundred = ranked.prefix(100).compactMap { movie in info(Int64(movie.tmdb_id)).map { (movie, $0) } }
        underrated = topHundred.first { $0.1.voteCount >= 50 && $0.1.voteAverage < 6.45 }.map(pick)
        deepCut = topHundred.filter { $0.1.voteCount > 0 }.min { $0.1.voteCount < $1.1.voteCount }.map(pick)
    }

    var topDecade: String? { decades.max { $0.count < $1.count }?.label }
    var topGenre: String? { genres.first?.label }
    var topLanguage: String? { languages.first?.label }
}

struct StatsView: View {
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var movieLists: FetchedResults<CDMovieList>
    @Environment(\.colorScheme) private var colorScheme
    // Bumped as TMDb info arrives, so the charts fill in
    @State private var infoVersion = 0
    @State private var loadingInfo = false
    @State private var shareItem: ShareItem? = nil
    @State private var showYearInReview = false

    private var summary: StatsSummary {
        _ = infoVersion
        return StatsSummary(lists: Array(movieLists), info: MovieInfoCache.shared.info(for:))
    }

    var body: some View {
        let summary = summary
        ZStack {
            Theme.background.ignoresSafeArea()
            if summary.filmCount == 0 {
                EmptyStateView(icon: "chart.bar.fill", title: "No stats yet",
                               message: "Add films to your lists and your stats will show up here.")
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        yearInReviewCard
                            .appearAnimation()
                        totals(summary)
                            .appearAnimation()
                        if let top = summary.topAverage, let all = summary.overallAverage {
                            tasteCard(top: top, all: all)
                                .appearAnimation(delay: 0.06)
                        }
                        picks(summary)
                            .appearAnimation(delay: 0.1)
                        chartCard("Decades", icon: "calendar", counts: summary.decades, vertical: true)
                            .appearAnimation(delay: 0.14)
                        if !summary.genres.isEmpty || loadingInfo {
                            chartCard("Top Genres", icon: "theatermasks.fill", counts: summary.genres, vertical: false)
                                .appearAnimation(delay: 0.18)
                        }
                        chartCard("Languages", icon: "globe", counts: summary.languages, vertical: false)
                            .appearAnimation(delay: 0.22)
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Your Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    share(summary)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(summary.filmCount == 0)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.medium, .large])
        }
        .onAppear(perform: loadInfo)
        .fullScreenCover(isPresented: $showYearInReview) {
            NavigationStack { YearInReviewView() }
        }
    }

    // Opens this year's Year in Review
    private var yearInReviewCard: some View {
        Button {
            Haptics.tap()
            showYearInReview = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title)
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your \(String(Calendar.current.component(.year, from: Date()))) in Review")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text("What you watched, your new favourites and your taste twin")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(cornerRadius: 20)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
    }

    private func loadInfo() {
        let ids = movieLists.flatMap { $0.movies.map { Int64($0.tmdb_id) } }
        loadingInfo = true
        MovieInfoCache.shared.fetchMissing(ids, onBatch: { infoVersion += 1 }, completion: {
            infoVersion += 1
            loadingInfo = false
        })
    }

    private func share(_ summary: StatsSummary) {
        Haptics.tap()
        Task { @MainActor in
            var poster: UIImage? = nil
            if let path = summary.underrated?.posterPath, let url = Theme.posterURL(path, size: .small) {
                poster = await PosterLoader.shared.image(for: url)
            }
            let renderer = ImageRenderer(content: StatsShareCard(summary: summary, underratedPoster: poster)
                .environment(\.colorScheme, colorScheme))
            renderer.scale = 3
            if let image = renderer.uiImage {
                shareItem = ShareItem(items: [image])
            }
        }
    }

    private func totals(_ summary: StatsSummary) -> some View {
        HStack(spacing: 12) {
            totalTile("\(summary.filmCount)", label: "Films", icon: "film")
            totalTile("\(summary.watchedCount)", label: "Watched", icon: "eye.fill")
            totalTile(summary.topDecade ?? "—", label: "Top Decade", icon: "calendar")
        }
    }

    private func totalTile(_ value: String, label: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Theme.accentGradient)
            Text(value)
                .font(.title3.weight(.heavy))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .cardStyle(cornerRadius: 18)
    }

    private func tasteCard(top: Double, all: Double) -> some View {
        let difference = top - all
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Your Taste vs TMDb", icon: "person.2.fill")
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                score(top, label: "Your top 50")
                score(all, label: "All your films")
            }
            Text(abs(difference) < 0.15
                 ? "Your favourites score about the same on TMDb as the rest of your films."
                 : difference > 0
                 ? "Your favourites score \(String(format: "%.1f", difference)) higher on TMDb than the rest: you agree with the crowd."
                 : "Your favourites score \(String(format: "%.1f", -difference)) lower on TMDb than the rest: you know what you like.")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    private func score(_ value: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.1f", value))
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.accentGradient)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func picks(_ summary: StatsSummary) -> some View {
        if summary.underrated != nil || summary.deepCut != nil {
            VStack(spacing: 12) {
                if let pick = summary.underrated {
                    pickRow(pick, title: "Most Underrated Pick",
                            detail: "You rank it #\(pick.rank); TMDb gives it \(String(format: "%.1f", pick.voteAverage)).")
                }
                if let pick = summary.deepCut, pick.title != summary.underrated?.title {
                    pickRow(pick, title: "Deepest Cut",
                            detail: "Your #\(pick.rank), and one of the least-rated films on TMDb in your top 100.")
                }
            }
        }
    }

    private func pickRow(_ pick: StatsSummary.Pick, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            PosterImage(path: pick.posterPath, cornerRadius: 8, size: .small)
                .frame(width: 52, height: 78)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.accentGradient)
                Text(pick.year.isEmpty ? pick.title : "\(pick.title) (\(pick.year))")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardStyle(cornerRadius: 18)
    }

    private func chartCard(_ title: String, icon: String, counts: [StatsSummary.Count], vertical: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, icon: icon)
            if counts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading from TMDb…")
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                }
            } else if vertical {
                Chart(counts) { item in
                    BarMark(x: .value("Decade", item.label), y: .value("Films", item.count))
                        .foregroundStyle(Theme.accentGradient)
                        .cornerRadius(4)
                }
                .chartYAxis(.hidden)
                .frame(height: 160)
            } else {
                Chart(counts) { item in
                    BarMark(x: .value("Films", item.count), y: .value(title, item.label))
                        .foregroundStyle(Theme.accentGradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing) {
                            Text("\(item.count)")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(counts.count) * 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundColor(Theme.textPrimary)
    }
}

/// The image shared from Stats: the headline numbers and the most underrated pick
struct StatsShareCard: View {
    let summary: StatsSummary
    let underratedPoster: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MY FILM STATS")
                    .font(.caption.weight(.heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.accentGradient)
                Text("\(summary.filmCount) films ranked")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
            }
            VStack(alignment: .leading, spacing: 12) {
                fact("Favourite decade", summary.topDecade)
                fact("Top genre", summary.topGenre)
                fact("Top language", summary.topLanguage)
                if let top = summary.topAverage {
                    fact("TMDb score of my top 50", String(format: "%.1f", top))
                }
            }
            if let pick = summary.underrated {
                HStack(spacing: 14) {
                    if let underratedPoster {
                        Image(uiImage: underratedPoster)
                            .resizable()
                            .aspectRatio(2/3, contentMode: .fill)
                            .frame(width: 56, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MOST UNDERRATED PICK")
                            .font(.caption2.weight(.heavy))
                            .tracking(1)
                            .foregroundStyle(Theme.accentGradient)
                        Text(pick.title)
                            .font(.headline)
                            .foregroundColor(Theme.textPrimary)
                        Text("My #\(pick.rank) · TMDb \(String(format: "%.1f", pick.voteAverage))")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            HStack {
                Spacer()
                Label("Movie List", systemImage: "film.stack")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(28)
        .frame(width: 390)
        .background(Theme.background)
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack {
                Text(label)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(value)
                    .fontWeight(.bold)
                    .foregroundColor(Theme.textPrimary)
            }
            .font(.subheadline)
        }
    }
}
