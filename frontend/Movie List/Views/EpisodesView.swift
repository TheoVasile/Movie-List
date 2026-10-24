//
//  EpisodesView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI

// MARK: - Models

struct TVEpisodeRef: Decodable, Hashable {
    let season: Int
    let episode: Int
    let name: String
    let air_date: String
}

struct TVSeason: Decodable, Identifiable {
    let season: Int
    let name: String
    let episodes: Int
    let air_date: String
    let poster_path: String?
    var id: Int { season }
}

struct TVShow: Decodable {
    let name: String
    let status: String
    let seasons: [TVSeason]
    // The latest episode that has aired, and the next one to air
    let last_episode: TVEpisodeRef?
    let next_episode: TVEpisodeRef?
}

struct TVEpisode: Decodable, Identifiable {
    let episode: Int
    let name: String
    let air_date: String
    let runtime: Int
    let overview: String
    let still_path: String?
    var id: Int { episode }
}

struct TVSeasonDetail: Decodable {
    let season: Int
    let name: String
    let episodes: [TVEpisode]
}

struct EpisodeKey: Codable, Hashable, Comparable {
    let season: Int
    let episode: Int

    static func < (a: EpisodeKey, b: EpisodeKey) -> Bool {
        (a.season, a.episode) < (b.season, b.episode)
    }

    /// "S2 E5"
    var label: String { "S\(season) E\(episode)" }
}

// MARK: - Tracker

/// One show's seasons and which episodes the user has watched. Changes show straight away and are put back if
/// they can't be saved
final class EpisodeTracker: ObservableObject {
    // The show's TMDb id as the app stores it (negative)
    let showID: Int64

    @Published private(set) var show: TVShow? = nil
    @Published private(set) var watched: Set<EpisodeKey> = []
    @Published private(set) var seasons: [Int: TVSeasonDetail] = [:]
    @Published private(set) var loadFailed = false

    init(showID: Int64) {
        self.showID = showID
    }

    func load() {
        APIService.shared.fetchShow(showID) { result in
            switch result {
            case .success(let show):
                self.show = show
                // The next episode's name comes from its season
                if let next = self.nextUp { self.loadSeason(next.season) }
            case .failure:
                self.loadFailed = true
            }
        }
        APIService.shared.fetchWatchedEpisodes(showID) { result in
            if case .success(let keys) = result { self.watched = Set(keys) }
        }
    }

    func loadSeason(_ season: Int) {
        guard seasons[season] == nil else { return }
        APIService.shared.fetchSeason(showID, season: season) { result in
            if case .success(let detail) = result { self.seasons[season] = detail }
        }
    }

    /// How many of a season's episodes have aired
    func airedCount(_ season: TVSeason) -> Int {
        guard let last = show?.last_episode else { return 0 }
        if season.season < last.season { return season.episodes }
        if season.season == last.season { return min(last.episode, season.episodes) }
        return 0
    }

    var airedTotal: Int {
        (show?.seasons ?? []).reduce(0) { $0 + airedCount($1) }
    }

    /// Watched episodes that have aired, so a total never goes over
    var watchedAired: Int {
        (show?.seasons ?? []).reduce(0) { total, season in
            total + watched.filter { $0.season == season.season && $0.episode <= airedCount(season) }.count
        }
    }

    /// The first aired episode the user hasn't watched, in order
    var nextUp: EpisodeKey? {
        for season in show?.seasons ?? [] {
            let aired = airedCount(season)
            guard aired > 0 else { continue }
            for episode in 1...aired where !watched.contains(EpisodeKey(season: season.season, episode: episode)) {
                return EpisodeKey(season: season.season, episode: episode)
            }
        }
        return nil
    }

    func name(of key: EpisodeKey) -> String? {
        seasons[key.season]?.episodes.first { $0.episode == key.episode }?.name
    }

    func isWatched(_ key: EpisodeKey) -> Bool { watched.contains(key) }

    func setWatched(_ keys: [EpisodeKey], _ isWatched: Bool) {
        guard let season = keys.first?.season, !keys.isEmpty else { return }
        let previous = watched
        if isWatched { watched.formUnion(keys) } else { watched.subtract(keys) }
        APIService.shared.setEpisodesWatched(showID, season: season, episodes: keys.map(\.episode), watched: isWatched) { result in
            switch result {
            case .success(let saved): self.watched = Set(saved)
            case .failure: self.watched = previous
            }
        }
    }

    /// Every aired episode of a season, watched or not
    func setSeasonWatched(_ season: TVSeason, _ isWatched: Bool) {
        let aired = airedCount(season)
        guard aired > 0 else { return }
        setWatched((1...aired).map { EpisodeKey(season: season.season, episode: $0) }, isWatched)
    }

    func watchedCount(in season: TVSeason) -> Int {
        watched.filter { $0.season == season.season && $0.episode <= airedCount(season) }.count
    }
}

// MARK: - Card on the show's info screen

/// Progress through a show and the next episode to watch, with one tap to mark it watched and a link to every
/// episode
struct EpisodesCard: View {
    @StateObject private var tracker: EpisodeTracker
    @State private var showingEpisodes = false

    init(showID: Int64) {
        _tracker = StateObject(wrappedValue: EpisodeTracker(showID: showID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Episodes", systemImage: "play.rectangle.on.rectangle.fill")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if tracker.show != nil {
                    Text("\(tracker.watchedAired) of \(tracker.airedTotal) watched")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            if let show = tracker.show {
                ProgressView(value: Double(tracker.watchedAired), total: Double(max(tracker.airedTotal, 1)))
                    .tint(Theme.accent)
                if let next = tracker.nextUp {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NEXT UP")
                                .font(.caption2.weight(.heavy))
                                .tracking(1)
                                .foregroundStyle(Theme.accentGradient)
                            Text(tracker.name(of: next).map { "\(next.label) · \($0)" } ?? next.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            Haptics.success()
                            withAnimation(Theme.spring) { tracker.setWatched([next], true) }
                        } label: {
                            Label("Watched", systemImage: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundColor(Theme.onAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.accentGradient, in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Mark \(next.label) watched")
                    }
                } else {
                    Text(caughtUpLine(show))
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
                Button {
                    Haptics.tap()
                    showingEpisodes = true
                } label: {
                    HStack {
                        Text("All Episodes")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.accent)
                }
                .buttonStyle(.borderless)
            } else if tracker.loadFailed {
                Text("Couldn't load episodes.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .cardStyle()
        .onAppear { if tracker.show == nil { tracker.load() } }
        .onChange(of: tracker.nextUp) { next in
            if let next { tracker.loadSeason(next.season) }
        }
        .sheet(isPresented: $showingEpisodes) {
            NavigationStack {
                EpisodesView(tracker: tracker)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingEpisodes = false }
                        }
                    }
            }
        }
    }

    private func caughtUpLine(_ show: TVShow) -> String {
        if let next = show.next_episode, let date = Self.date(next.air_date) {
            return "You're caught up. \(next.label) airs \(date.formatted(date: .abbreviated, time: .omitted))."
        }
        if tracker.airedTotal == 0 { return "No episodes have aired yet." }
        return show.status == "Ended" || show.status == "Canceled" ? "You've watched every episode." : "You're caught up."
    }

    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

private extension TVEpisodeRef {
    var label: String { "S\(season) E\(episode)" }
}

// MARK: - Every episode

/// A show's seasons, each opening to its episodes with a check to mark them watched. Episodes that haven't aired
/// yet show their air date instead
struct EpisodesView: View {
    @ObservedObject var tracker: EpisodeTracker
    @State private var expanded: Set<Int> = []

    var body: some View {
        List {
            ForEach(tracker.show?.seasons ?? []) { season in
                Section {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(season.season) },
                        set: { open in
                            if open {
                                expanded.insert(season.season)
                                tracker.loadSeason(season.season)
                            } else {
                                expanded.remove(season.season)
                            }
                        }
                    )) {
                        if let detail = tracker.seasons[season.season] {
                            ForEach(detail.episodes) { episode in
                                episodeRow(episode, season: season)
                            }
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        }
                    } label: {
                        seasonLabel(season)
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(tracker.show?.name ?? "Episodes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Opens on the season with the next episode to watch
            if let next = tracker.nextUp, expanded.isEmpty {
                expanded.insert(next.season)
                tracker.loadSeason(next.season)
            }
        }
    }

    private func seasonLabel(_ season: TVSeason) -> some View {
        let aired = tracker.airedCount(season)
        let watched = tracker.watchedCount(in: season)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(season.name)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text(aired == 0 ? "Not out yet" : "\(watched) of \(aired) watched")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            if aired > 0 {
                let done = watched >= aired
                Button {
                    Haptics.tap()
                    withAnimation(Theme.spring) { tracker.setSeasonWatched(season, !done) }
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(done ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(done ? "Mark \(season.name) unwatched" : "Mark all of \(season.name) watched")
            }
        }
    }

    private func episodeRow(_ episode: TVEpisode, season: TVSeason) -> some View {
        let key = EpisodeKey(season: season.season, episode: episode.episode)
        let aired = episode.episode <= tracker.airedCount(season)
        let watched = tracker.isWatched(key)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(episode.episode). \(episode.name)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(aired ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let date = EpisodesCard.date(episode.air_date) {
                        Text(aired ? date.formatted(date: .abbreviated, time: .omitted)
                                   : "Airs \(date.formatted(date: .abbreviated, time: .omitted))")
                    }
                    if episode.runtime > 0 {
                        Text("· \(episode.runtime)m")
                    }
                }
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            if aired {
                Button {
                    Haptics.select()
                    withAnimation(Theme.spring) { tracker.setWatched([key], !watched) }
                } label: {
                    Image(systemName: watched ? "eye.fill" : "eye")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(watched ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(watched ? "Mark \(key.label) unwatched" : "Mark \(key.label) watched")
            }
        }
        .padding(.vertical, 2)
    }
}
