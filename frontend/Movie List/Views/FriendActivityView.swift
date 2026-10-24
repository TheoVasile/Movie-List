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

/// What the people the user follows have been watching and ranking over the last two weeks, newest first and
/// grouped by day. Tapping one opens the film, where it can be added to lists; tapping a person opens their profile
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

    // Days, newest first, each with its activity
    private var days: [(day: Date, items: [FriendActivity])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: activity) { calendar.startOfDay(for: $0.date ?? .distantPast) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            if activity.isEmpty {
                Text(!hasLoaded ? "Loading…"
                     : failed ? "Couldn't load activity. Pull down to try again."
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
                    ForEach(day.items) { item in
                        row(item)
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
        .sheet(item: $adding) { movie in
            ListPickerSheet(title: movie.title, posterPath: movie.poster_path) { lists in
                for chosen in lists {
                    chosen.addMovie(movie, context: context) { _ in }
                }
                if !lists.isEmpty {
                    Haptics.success()
                    AppAnalytics.log(.filmAdded(.friend))
                }
            }
            .environmentObject(authViewModel)
            .environment(\.managedObjectContext, context)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func row(_ item: FriendActivity) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Haptics.tap()
                openPerson = UserSummary(handle: item.handle, display_name: item.handle, following: true,
                                         list_count: nil, film_count: nil, avatar_version: item.avatar_version)
            } label: {
                Avatar(name: item.handle, size: 38, handle: item.handle, version: item.avatar_version)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("@\(item.handle)'s profile")
            Button {
                Haptics.tap()
                detailsMovie = item.movie
                details = PersistenceController.preview(of: item.movie)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        (Text("@\(item.handle) ").fontWeight(.semibold) + Text(item.action).foregroundColor(Theme.textSecondary))
                            .font(.subheadline)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
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
