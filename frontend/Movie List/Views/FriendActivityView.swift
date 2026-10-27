//
//  FriendActivityView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI

/// Something someone the user follows did: watched, rewatched or added a film to one of their lists
struct FriendActivity: Decodable, Identifiable {
    // "watched", "rewatched" or "ranked" (added to a list; rank is nil for unranked lists)
    let kind: String
    let rank: Int?
    let list_name: String?
    // ISO 8601
    let at: String
    let handle: String
    let avatar_version: Double?
    let tmdb_id: Int64
    let title: String
    let release_date: String
    let poster_path: String?
    let overview: String
    let original_language: String
    let popularity: Double
    // The user's own list with this film in it, if any
    let my_list: String?

    var id: String { "\(handle)-\(kind)-\(tmdb_id)-\(at)" }

    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: at) ?? ISO8601DateFormatter().date(from: at)
    }

    var movie: Movie {
        Movie(id: tmdb_id, title: title, release_date: release_date, overview: overview, poster_path: poster_path,
              original_language: original_language, popularity: popularity)
    }

    /// "ranked #2 in Favourites", "watched", ...
    var action: String {
        switch kind {
        case "watched": return "watched"
        case "rewatched": return "rewatched"
        default:
            let list = list_name.map { " in \($0)" } ?? ""
            return rank.map { "ranked #\($0)\(list)" } ?? "added to \(list_name ?? "a list")"
        }
    }

    var icon: String {
        switch kind {
        case "watched": return "eye.fill"
        case "rewatched": return "arrow.counterclockwise"
        default: return rank == nil ? "plus" : "list.number"
        }
    }
}

/// One person's run of the same thing on one day, e.g. everything @alex added to Watchlist today, newest first.
/// Keeps one busy friend from filling the feed; a run of one shows as a normal row
struct FriendActivityGroup: Identifiable {
    let id: String
    let items: [FriendActivity]

    var latest: FriendActivity { items[0] }

    /// "added 12 films to Watchlist", "ranked 3 films in Favourites", "watched 5 films"
    var action: String {
        let films = "\(items.count) films"
        switch latest.kind {
        case "watched": return "watched \(films)"
        case "rewatched": return "rewatched \(films)"
        default:
            let list = latest.list_name ?? "a list"
            return items.allSatisfy({ $0.rank != nil }) ? "ranked \(films) in \(list)" : "added \(films) to \(list)"
        }
    }
}

/// What the people the user follows have been watching and ranking over the last two weeks, newest first and
/// grouped by day. Within a day, each person's films with the same action (and list) collapse into one row that
/// can be expanded, ordered by their most recent. Tapping one opens the film, where it can be added to lists; tapping a person opens their profile
struct FriendActivityView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @State private var activity: [FriendActivity] = []
    @State private var hasLoaded = false
    @State private var failed = false
    @State private var details: CDMovie? = nil
    @State private var detailsMovie: Movie? = nil
    @State private var adding: Movie? = nil
    @State private var openPerson: UserSummary? = nil
    @State private var reporting: ReportTarget? = nil
    // Groups the user opened with "Show all"
    @State private var expanded: Set<String> = []

    // How many posters a collapsed group previews
    private let previewCount = 5

    // Days, newest first, each with its activity grouped by person, action and list, the most recent group first
    private var days: [(day: Date, groups: [FriendActivityGroup])] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: activity) { calendar.startOfDay(for: $0.date ?? .distantPast) }
        return byDay.keys.sorted(by: >).map { day in
            let items = (byDay[day] ?? []).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            var order: [String] = []
            var runs: [String: [FriendActivity]] = [:]
            for item in items {
                let key = "\(Int(day.timeIntervalSince1970))|\(item.handle)|\(item.kind)|\(item.list_name ?? "")"
                if runs[key] == nil { order.append(key) }
                runs[key, default: []].append(item)
            }
            return (day, order.map { FriendActivityGroup(id: $0, items: runs[$0] ?? []) })
        }
    }

    var body: some View {
        List {
            if !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if activity.isEmpty {
                Text(failed ? "Couldn't load activity. Pull down to try again."
                     : "Nothing from the people you follow in the last two weeks. When they watch or rank films, it'll show up here.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.groups) { group in
                        if group.items.count == 1 {
                            row(group.latest)
                        } else {
                            groupRow(group)
                            if expanded.contains(group.id) {
                                ForEach(group.items) { item in
                                    row(item, nested: true)
                                }
                            }
                        }
                    }
                } header: {
                    Text(dayTitle(day.day))
                        .font(.caption.weight(.heavy))
                        .tracking(1)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Friend Activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .navigationDestination(isPresented: Binding(get: { openPerson != nil }, set: { if !$0 { openPerson = nil } })) {
            if let openPerson {
                FriendProfileView(person: openPerson)
            }
        }
        .task { await load() }
        .sheet(item: $reporting) { target in
            ReportSheet(target: target)
        }
        .sheet(item: $details) { preview in
            // Add to Lists closes the info screen and asks which lists
            MovieDetailView(movie: preview, onAddToLists: {
                let movie = detailsMovie
                details = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { adding = movie }
            })
        }
        // The same list picker and Compare as adding anywhere else
        .addToListFlow(movie: $adding, source: .friend)
    }

    private func avatarButton(_ item: FriendActivity) -> some View {
        Button {
            Haptics.tap()
            openPerson = UserSummary(handle: item.handle, display_name: item.handle, following: true,
                                     list_count: nil, film_count: nil, avatar_version: item.avatar_version)
        } label: {
            Avatar(name: item.handle, size: 38, handle: item.handle, version: item.avatar_version)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("@\(item.handle)'s profile")
    }

    private func openFilm(_ item: FriendActivity) {
        Haptics.tap()
        detailsMovie = item.movie
        details = PersistenceController.preview(of: item.movie)
    }

    /// A person's run of films collapsed into one row: what they did, a strip of posters (each opens its film) and
    /// a Show all / Show less toggle that lists every film underneath
    private func groupRow(_ group: FriendActivityGroup) -> some View {
        let item = group.latest
        let isExpanded = expanded.contains(group.id)
        return HStack(alignment: .top, spacing: 12) {
            avatarButton(item)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.icon)
                        .foregroundStyle(Theme.accentGradient)
                        .accessibilityHidden(true)
                    (Text("@\(item.handle) ").fontWeight(.semibold) + Text(group.action).foregroundColor(Theme.textSecondary))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .font(.subheadline)
                if !isExpanded {
                    HStack(spacing: 6) {
                        ForEach(group.items.prefix(previewCount)) { film in
                            Button {
                                openFilm(film)
                            } label: {
                                PosterImage(path: film.poster_path, cornerRadius: 5, size: .small)
                                    .frame(width: 38, height: 57)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(film.title)
                        }
                        if group.items.count > previewCount {
                            Text("+\(group.items.count - previewCount)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                                .padding(.leading, 2)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Button {
                        Haptics.tap()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isExpanded { expanded.remove(group.id) } else { expanded.insert(group.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Show less" : "Show all \(group.items.count)")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accentGradient)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "Show fewer of @\(item.handle)'s films" : "Show all \(group.items.count) of @\(item.handle)'s films")
                    if let date = item.date {
                        Text("· \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                reportButton(item)
            } label: {
                MoreActionsLabel()
            }
            .accessibilityLabel("Options for @\(item.handle)'s activity")
        }
        .listRowBackground(Color.clear)
        .contextMenu {
            reportButton(item)
        }
    }

    /// One film. Nested rows sit under their expanded group, indented past the avatar
    private func row(_ item: FriendActivity, nested: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if nested {
                Color.clear.frame(width: 38, height: 1)
            } else {
                avatarButton(item)
            }
            Button {
                openFilm(item)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !nested {
                            (Text("@\(item.handle) ").fontWeight(.semibold) + Text(item.action).foregroundColor(Theme.textSecondary))
                                .font(.subheadline)
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: item.icon)
                                .foregroundStyle(Theme.accentGradient)
                                .accessibilityHidden(true)
                            Text(Theme.year(from: item.release_date).isEmpty ? item.title : "\(item.title) (\(Theme.year(from: item.release_date)))")
                                .fontWeight(.semibold)
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.subheadline)
                        HStack(spacing: 4) {
                            // Under a group the rank is the only part of the action that differs per film
                            if nested, let rank = item.rank {
                                Text("#\(rank) ·")
                            }
                            if let date = item.date {
                                Text(date.formatted(date: .omitted, time: .shortened))
                            }
                            // Whether the user has it too, which is what makes a friend's pick interesting
                            if item.my_list != nil {
                                Text("· You have it")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    PosterImage(path: item.poster_path, cornerRadius: 6, size: .small)
                        .frame(width: 44, height: 66)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Menu {
                reportButton(item)
            } label: {
                MoreActionsLabel()
            }
            .accessibilityLabel("Options for @\(item.handle)'s activity")
        }
        .listRowBackground(Color.clear)
        // A shortcut for the ⋮
        .contextMenu {
            reportButton(item)
        }
    }

    private func reportButton(_ item: FriendActivity) -> some View {
        Button {
            reporting = ReportTarget(handle: item.handle, kind: .activity, contentID: "\(item.kind)-\(item.tmdb_id)")
        } label: {
            Label("Report @\(item.handle)", systemImage: "flag")
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
    }

    private func load() async {
        await withCheckedContinuation { continuation in
            APIService.shared.fetchFriendActivity { result in
                hasLoaded = true
                switch result {
                case .success(let loaded):
                    failed = false
                    activity = loaded
                case .failure:
                    failed = true
                }
                continuation.resume()
            }
        }
    }
}
