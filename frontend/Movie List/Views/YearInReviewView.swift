//
//  YearInReviewView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-20.
//

import Foundation
import SwiftUI
import CoreData

/// The user's year in film as a story: swipe or tap through slides, each of which can be shared as an image.
/// Counts, months, favourites and the closest friend come from the server's diary; genres and TMDb scores from
/// the info this phone already keeps for every film
struct YearInReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FetchRequest(fetchRequest: CDMovieList.fetch()) private var movieLists: FetchedResults<CDMovieList>

    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var review: YearReview? = nil
    @State private var isLoading = true
    @State private var failed = false
    @State private var page = 0
    // Bumped as TMDb info arrives, so the genres and underrated pick fill in
    @State private var infoVersion = 0
    @State private var shareItem: ShareItem? = nil

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(Theme.accent)
            } else if failed {
                EmptyStateView(icon: "wifi.slash", title: "Couldn't load your year", message: "Check your connection and try again.",
                               actionTitle: "Try Again", action: load)
            } else if let review, review.total_watches == 0 {
                EmptyStateView(icon: "calendar.badge.clock", title: "Nothing logged in \(String(year)) yet",
                               message: "Mark films as watched, or log rewatches from a film's page, and your year will build up here.")
            } else if let review {
                let slides = slides(for: review)
                VStack(spacing: 14) {
                    progress(count: slides.count)
                    TabView(selection: $page) {
                        ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                            YearSlideView(slide: slide, review: review)
                                .padding(.horizontal, 16)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    Button {
                        share(slides[min(page, slides.count - 1)], review: review)
                    } label: {
                        Label("Share This", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(Theme.onAccent)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.95))
                    .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle("\(String(year)) in Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") { dismiss() }
            }
            if let years = review?.years, years.count > 1 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Year", selection: $year) {
                            ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                        }
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Choose Year")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.medium, .large])
        }
        .onAppear { if review == nil { load() } }
        .onChange(of: year) { _ in load() }
    }

    // Story-style bars along the top, one per slide
    private func progress(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= page ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceRaised))
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.2), value: page)
    }

    private func load() {
        isLoading = true
        failed = false
        page = 0
        APIService.shared.fetchYearReview(year: year) { result in
            isLoading = false
            switch result {
            case .success(let loaded):
                review = loaded
                MovieInfoCache.shared.fetchMissing(loaded.films.map(\.tmdb_id), onBatch: { infoVersion += 1 }, completion: { infoVersion += 1 })
            case .failure:
                failed = true
            }
        }
    }

    // MARK: Slides

    private func slides(for review: YearReview) -> [YearSlide] {
        _ = infoVersion
        var slides: [YearSlide] = [.intro]
        if review.months.filter({ $0 > 0 }).count > 1 { slides.append(.months) }
        let genres = topGenres(review)
        if !genres.isEmpty { slides.append(.genres(genres)) }
        if let favourite = review.new_favourite { slides.append(.favourite(favourite)) }
        if let rewatched = review.most_rewatched { slides.append(.rewatched(rewatched)) }
        if let pick = underrated(review) { slides.append(.underrated(pick.film, score: pick.score)) }
        if let friend = review.closest_friend { slides.append(.friend(friend)) }
        slides.append(.outro)
        return slides
    }

    // The year's three most-watched genres, with how many films each
    private func topGenres(_ review: YearReview) -> [(name: String, count: Int)] {
        var counts: [Int: Int] = [:]
        for film in review.films {
            for genre in MovieInfoCache.shared.info(for: film.tmdb_id)?.genres ?? [] where genre != 10770 {
                counts[genre, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(3)
            .compactMap { entry in TasteProfile.genreNames[entry.key].map { ($0, entry.value) } }
    }

    // A film from the year that the user ranks in the top half of a list but TMDb's users score below 6.5
    private func underrated(_ review: YearReview) -> (film: YearReview.Film, score: Double)? {
        var bestShare: [Int32: Double] = [:]
        for list in movieLists {
            let count = Double(list.movies.count)
            guard count >= 4 else { continue }
            for movie in list.movies {
                let share = Double(movie.rank) / count
                bestShare[movie.tmdb_id] = min(bestShare[movie.tmdb_id] ?? 1, share)
            }
        }
        return review.films
            .compactMap { film -> (YearReview.Film, Double)? in
                guard let info = MovieInfoCache.shared.info(for: film.tmdb_id), info.voteCount >= 50, info.voteAverage < 6.5,
                      (bestShare[Int32(film.tmdb_id)] ?? 1) <= 0.5 else { return nil }
                return (film, info.voteAverage)
            }
            .min { $0.1 < $1.1 }
    }

    // MARK: Sharing

    /// Renders the slide as an image, with its posters downloaded first since an image can't wait for them
    private func share(_ slide: YearSlide, review: YearReview) {
        Haptics.tap()
        Task { @MainActor in
            var posters: [String: UIImage] = [:]
            for path in slide.posterPaths(review) {
                if let url = Theme.posterURL(path, size: .medium), let image = await PosterLoader.shared.image(for: url) {
                    posters[path] = image
                }
            }
            let card = YearSlideView(slide: slide, review: review, posters: posters, forSharing: true)
                .frame(width: 390, height: 640)
                .padding(20)
                .background(Theme.background)
                .environment(\.colorScheme, colorScheme)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3
            if let image = renderer.uiImage {
                shareItem = ShareItem(items: [image])
            }
        }
    }
}

enum YearSlide {
    case intro
    case months
    case genres([(name: String, count: Int)])
    case favourite(YearReview.Film)
    case rewatched(YearReview.Film)
    case underrated(YearReview.Film, score: Double)
    case friend(YearReview.Friend)
    case outro

    /// The posters the slide shows, so they can be downloaded before it's shared
    func posterPaths(_ review: YearReview) -> [String] {
        switch self {
        case .intro: return review.films.prefix(5).compactMap(\.poster_path)
        case .favourite(let film), .rewatched(let film), .underrated(let film, _): return [film.poster_path].compactMap { $0 }
        case .outro: return [review.first_film?.poster_path, review.latest_film?.poster_path].compactMap { $0 }
        case .months, .genres, .friend: return []
        }
    }
}

/// One slide of the story. posters holds downloaded images when it's drawn for sharing
struct YearSlideView: View {
    let slide: YearSlide
    let review: YearReview
    var posters: [String: UIImage] = [:]
    var forSharing = false

    private var yearText: String { String(review.year) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
            Spacer(minLength: 0)
            HStack {
                Text("MY \(yearText) IN FILM")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.2)
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Label("Marquee", systemImage: "film.stack")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                Theme.surface
                LinearGradient(colors: [Theme.accent.opacity(0.28), .clear], startPoint: .topLeading, endPoint: .center)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch slide {
        case .intro:
            eyebrow("YOUR \(yearText) IN FILM")
            bigNumber(review.films_watched, label: review.films_watched == 1 ? "film watched" : "films watched")
            if review.rewatches > 0 {
                Text("plus \(review.rewatches) \(review.rewatches == 1 ? "rewatch" : "rewatches")")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            posterFan(review.films.prefix(5).map(\.poster_path))
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
        case .months:
            eyebrow("MONTH BY MONTH")
            if let busiest = review.busiest_month {
                headline("\(Calendar.current.monthSymbols[busiest - 1]) was your biggest month")
                Text("\(review.months[busiest - 1]) \(review.months[busiest - 1] == 1 ? "watch" : "watches")")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            monthChart
                .padding(.top, 12)
        case .genres(let genres):
            eyebrow("WHAT YOU WATCHED")
            headline("Mostly \(genres[0].name.lowercased())")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(genres.enumerated()), id: \.offset) { index, genre in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(Theme.accentGradient)
                            .frame(width: 34)
                        Text(genre.name)
                            .font(.title2.weight(.bold))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text("\(genre.count) \(genre.count == 1 ? "film" : "films")")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .padding(.top, 14)
        case .favourite(let film):
            eyebrow("NEW FAVOURITE")
            filmFeature(film, detail: film.rank.map { rank in "Ranked #\(rank)\(film.list_name.map { " in \($0)" } ?? "")" })
        case .rewatched(let film):
            eyebrow("ON REPEAT")
            filmFeature(film, detail: "Watched \(film.times ?? 2) times this year")
        case .underrated(let film, let score):
            eyebrow("YOUR HOT TAKE")
            filmFeature(film, detail: "You rank it highly. TMDb's users give it \(String(format: "%.1f", score)).")
        case .friend(let friend):
            eyebrow("TASTE TWIN")
            HStack {
                Spacer()
                Avatar(name: friend.display_name, size: 120, handle: forSharing ? nil : friend.handle, version: forSharing ? nil : friend.avatar_version)
                Spacer()
            }
            .padding(.vertical, 12)
            headline("@\(friend.handle) has the closest taste to yours")
            Text("\(friend.shared) films in common\(friend.example_title.map { ", including \($0)" } ?? "").")
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
        case .outro:
            eyebrow("THAT'S A WRAP")
            headline("\(review.total_watches) \(review.total_watches == 1 ? "watch" : "watches") in \(yearText)")
            if let first = review.first_film {
                bookend("First film", first)
            }
            if let latest = review.latest_film, latest.tmdb_id != review.first_film?.tmdb_id {
                bookend("Latest", latest)
            }
        }
    }

    // MARK: Pieces

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .tracking(1.5)
            .foregroundStyle(Theme.accentGradient)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundColor(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bigNumber(_ value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.system(size: 96, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.accentGradient)
            Text(label)
                .font(.title.weight(.bold))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private var monthChart: some View {
        let highest = max(review.months.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<12, id: \.self) { month in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(month + 1 == review.busiest_month ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceRaised))
                        .frame(height: max(4, 180 * CGFloat(review.months[month]) / CGFloat(highest)))
                    Text(String(Calendar.current.veryShortMonthSymbols[month]))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 210, alignment: .bottom)
    }

    private func poster(_ path: String?, width: CGFloat) -> some View {
        Group {
            if let path, let image = posters[path] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fill)
            } else {
                PosterImage(path: path, cornerRadius: 0, size: .medium)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width / 10, style: .continuous))
        .shadow(color: Theme.shadow.opacity(0.5), radius: 10, y: 6)
    }

    private func posterFan(_ paths: [String?]) -> some View {
        ZStack {
            ForEach(Array(paths.enumerated().reversed()), id: \.offset) { index, path in
                let side: CGFloat = index.isMultiple(of: 2) ? 1 : -1
                poster(path, width: 110)
                    .rotationEffect(.degrees(Double(index == 0 ? 0 : side * Double((index + 1) / 2) * 8)))
                    .offset(x: index == 0 ? 0 : side * CGFloat((index + 1) / 2) * 46, y: CGFloat((index + 1) / 2) * 8)
                    .scaleEffect(1 - CGFloat((index + 1) / 2) * 0.08)
            }
        }
        .frame(height: 190)
    }

    private func filmFeature(_ film: YearReview.Film, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                poster(film.poster_path, width: 170)
                Spacer()
            }
            .padding(.top, 8)
            headline(film.title)
            if let detail {
                Text(detail)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bookend(_ label: String, _ film: YearReview.Film) -> some View {
        HStack(spacing: 14) {
            poster(film.poster_path, width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(1)
                    .foregroundColor(Theme.textSecondary)
                Text(film.title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }
        }
        .padding(.top, 10)
    }
}
