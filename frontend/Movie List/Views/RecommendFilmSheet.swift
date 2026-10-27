//
//  RecommendFilmSheet.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI

/// A film someone sent the user, with who sent it and their note
struct FilmRecommendation: Decodable, Identifiable, Equatable {
    let id: Int64
    let tmdb_id: Int64
    let title: String
    let poster_path: String?
    let release_date: String?
    let overview: String?
    let original_language: String?
    let popularity: Double?
    let note: String?
    let seen: Bool
    // ISO 8601, e.g. "2026-10-23T18:04:11Z"
    let sent_at: String
    let sender_handle: String
    let sender_name: String
    let sender_avatar_version: Double?

    var movie: Movie {
        Movie(id: tmdb_id, title: title, release_date: release_date ?? "", overview: overview ?? "", poster_path: poster_path,
              original_language: original_language ?? "", popularity: popularity ?? 0)
    }

    var sentDate: Date? {
        ISO8601DateFormatter().date(from: sent_at)
    }
}

extension Movie {
    /// The film behind one of the user's saved films, for sending it to friends
    init(_ saved: CDMovie) {
        let date = saved.release_date.map { Self.dayFormatter.string(from: $0) } ?? ""
        self.init(id: Int64(saved.tmdb_id), title: saved.title ?? "", release_date: date, overview: saved.overview ?? "",
                  poster_path: saved.poster_path, original_language: saved.original_language ?? "", popularity: saved.popularity)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Picks friends to send a film to, with an optional note. Anyone the user follows or who follows them
struct RecommendFilmSheet: View {
    let movie: Movie

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var social = SocialStore.shared
    @State private var followers: [UserSummary] = []
    @State private var loadingFollowers = true
    @State private var chosen: Set<String> = []
    @State private var note = ""
    @State private var query = ""
    @State private var sending = false
    @State private var failure: String? = nil
    // Sent, but moderation is holding the note for review, so the sheet stays open to say so
    @State private var noteHeld = false

    private static let noteLimit = 300

    // People the user follows first, then followers they don't follow back
    private var people: [UserSummary] {
        var seen = Set<String>()
        return (social.following + followers).filter { seen.insert($0.handle).inserted }
    }

    private var shown: [UserSummary] {
        let typed = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        guard !typed.isEmpty else { return people }
        return people.filter { $0.handle.contains(typed) || $0.display_name.lowercased().contains(typed) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        PosterImage(path: movie.poster_path, cornerRadius: 6, size: .small)
                            .frame(width: 44, height: 66)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(movie.title)
                                .font(.headline)
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(2)
                            Text(Theme.year(from: movie.release_date))
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: note) { typed in
                            if typed.count > Self.noteLimit { note = String(typed.prefix(Self.noteLimit)) }
                        }
                } footer: {
                    if noteHeld {
                        Label("Sent. Your note is under review, so they'll see the film without it for now.", systemImage: "eye.slash")
                            .foregroundColor(Theme.accentSecondary)
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    if people.isEmpty {
                        Text(loadingFollowers ? "Loading…" : "Follow people to send them films. You can send films to anyone you follow or who follows you.")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    }
                    ForEach(shown) { person in
                        Button {
                            Haptics.select()
                            if chosen.contains(person.handle) { chosen.remove(person.handle) } else { chosen.insert(person.handle) }
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(name: person.display_name, size: 36, handle: person.handle, version: person.avatar_version)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("@\(person.handle)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(Theme.textPrimary)
                                    Text(person.display_name)
                                        .font(.caption)
                                        .foregroundColor(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: chosen.contains(person.handle) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(chosen.contains(person.handle) ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen.contains(person.handle) ? .isSelected : [])
                    }
                } header: {
                    Text("Send To")
                } footer: {
                    if let failure {
                        Text(failure).foregroundColor(Theme.accentSecondary)
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .disabled(sending || noteHeld)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search people")
            .navigationTitle("Recommend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !noteHeld {
                        Button("Cancel") { dismiss() }
                            .disabled(sending)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else if noteHeld {
                        Button("Done") { dismiss() }
                            .bold()
                    } else {
                        Button(chosen.count > 1 ? "Send to \(chosen.count)" : "Send", action: send)
                            .bold()
                            .disabled(chosen.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .onAppear {
            APIService.shared.fetchConnections(handle: nil, followers: true) { result in
                loadingFollowers = false
                if case .success(let loaded) = result { followers = loaded }
            }
        }
    }

    private func send() {
        sending = true
        failure = nil
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        APIService.shared.sendRecommendation(movie, to: Array(chosen), note: trimmed.isEmpty ? nil : trimmed) { result in
            sending = false
            switch result {
            case .success(let sent) where !sent.sentTo.isEmpty:
                Haptics.success()
                AppAnalytics.log(.recommendationSent(recipients: sent.sentTo.count))
                if sent.noteUnderReview {
                    noteHeld = true
                } else {
                    dismiss()
                }
            case .failure(let error):
                failure = error.serverMessage ?? "Couldn't send it. Check your connection and try again."
            default:
                failure = "Couldn't send it. Check your connection and try again."
            }
        }
    }
}

/// Films friends sent the user, newest first. Opening the screen marks them all as seen. Tapping one shows its
/// info, where it can be added to lists; its ⋮ removes or reports it
struct RecommendationsView: View {
    @ObservedObject private var store = RecommendationsStore.shared
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @State private var details: CDMovie? = nil
    @State private var detailsMovie: Movie? = nil
    @State private var adding: Movie? = nil
    @State private var reporting: ReportTarget? = nil

    var body: some View {
        List {
            if store.received.isEmpty {
                Text(store.hasLoaded ? "When friends send you films they think you should see, they'll show up here." : "Loading…")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(store.received) { recommendation in
                // Swiping and touching and holding are shortcuts for the row's ⋮
                row(recommendation)
                    .swipeActions(edge: .trailing) {
                        removeButton(recommendation)
                    }
                    .contextMenu {
                        reportButton(recommendation)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Recommended to You")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { store.load() }
        // Everything here counts as seen once it has loaded
        .onAppear { store.load(thenMarkSeen: true) }
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
        .addToListFlow(movie: $adding, source: .recommendation)
    }

    private func removeButton(_ recommendation: FilmRecommendation) -> some View {
        Button(role: .destructive) {
            Haptics.tap()
            store.remove(recommendation)
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private func reportButton(_ recommendation: FilmRecommendation) -> some View {
        Button {
            reporting = ReportTarget(handle: recommendation.sender_handle, kind: .recommendation,
                                     contentID: String(recommendation.id))
        } label: {
            Label("Report @\(recommendation.sender_handle)", systemImage: "flag")
        }
    }

    private func row(_ recommendation: FilmRecommendation) -> some View {
        HStack(alignment: .top, spacing: 0) {
            filmButton(recommendation)
            Menu {
                removeButton(recommendation)
                reportButton(recommendation)
            } label: {
                MoreActionsLabel()
            }
            .accessibilityLabel("\(recommendation.title) Options")
        }
        .listRowBackground(Color.clear)
    }

    private func filmButton(_ recommendation: FilmRecommendation) -> some View {
        Button {
            Haptics.tap()
            detailsMovie = recommendation.movie
            details = PersistenceController.preview(of: recommendation.movie)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                PosterImage(path: recommendation.poster_path, cornerRadius: 8, size: .small)
                    .frame(width: 56, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        // Not looked at before this visit
                        if !recommendation.seen {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("New")
                        }
                        Avatar(name: recommendation.sender_name, size: 20, handle: recommendation.sender_handle,
                               version: recommendation.sender_avatar_version)
                        Text("@\(recommendation.sender_handle)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.textSecondary)
                        if let date = recommendation.sentDate {
                            Text("· \(date.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    Text(recommendation.title)
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if recommendation.tmdb_id < 0 {
                            TVBadge()
                        }
                        Text(Theme.year(from: recommendation.release_date ?? ""))
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let note = recommendation.note {
                        Text("“\(note)”")
                            .font(.subheadline)
                            .italic()
                            .foregroundColor(Theme.textPrimary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        // Borderless, so tapping the ⋮ beside it doesn't also open the film
        .buttonStyle(.borderless)
    }
}

/// The films friends sent the user, shared by Profile (for its count) and the Recommended to You screen
final class RecommendationsStore: ObservableObject {
    static let shared = RecommendationsStore()
    @Published private(set) var received: [FilmRecommendation] = []
    @Published private(set) var hasLoaded = false

    var unseenCount: Int { received.filter { !$0.seen }.count }

    func load(thenMarkSeen: Bool = false) {
        APIService.shared.fetchRecommendations { result in
            if case .success(let loaded) = result { self.received = loaded }
            self.hasLoaded = true
            if thenMarkSeen { self.markSeen() }
        }
    }

    // The badges clear; the films keep their "new" look until the screen is opened again
    private func markSeen() {
        guard received.contains(where: { !$0.seen }) else { return }
        APIService.shared.markRecommendationsSeen { saved in
            if saved { SocialStore.shared.load() }
        }
    }

    func remove(_ recommendation: FilmRecommendation) {
        let previous = received
        withAnimation(Theme.spring) { received.removeAll { $0.id == recommendation.id } }
        APIService.shared.removeRecommendation(recommendation.id) { removed in
            if !removed { withAnimation(Theme.spring) { self.received = previous } }
        }
    }
}
