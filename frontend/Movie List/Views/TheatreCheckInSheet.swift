//
//  TheatreCheckInSheet.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI
import CoreData

/// "What did you see?", opened from the notification sent after the user leaves a movie theatre. Lists the films
/// in theatres now, most popular first, so the one they just saw can be added to their lists and logged as watched
/// today. Anything not showing (an older film at a repertory screening, say) can be searched for instead
struct TheatreCheckInSheet: View {
    // The theatre the user just left, as named by the notification
    let theatre: String

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @FetchRequest(fetchRequest: CDMovieList.fetch()) private var movieLists: FetchedResults<CDMovieList>

    @State private var nowPlaying: [Movie] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    // The search box narrows the films showing, and also searches every film for one that isn't
    @State private var query = ""
    @State private var searchResults: [Movie] = []
    @State private var searching = false
    // The film waiting for the user to choose lists, and the films added from here
    @State private var adding: Movie? = nil
    @State private var added: Set<Int64> = []
    // Films logged as watched today from here, and those still saving
    @State private var logged: Set<Int64> = []
    @State private var logging: Set<Int64> = []
    @State private var logFailed = false
    // The film whose info screen is open, as a temporary copy that isn't saved anywhere
    @State private var details: CDMovie? = nil

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Films showing whose title has what's typed
    private var showingMatches: [Movie] {
        guard !trimmedQuery.isEmpty else { return nowPlaying }
        return nowPlaying.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    // Search results that aren't already listed among the films showing
    private var otherMatches: [Movie] {
        let showing = Set(showingMatches.map(\.id))
        return searchResults.filter { !showing.contains($0.id) }
    }

    // A copy of each film already in the user's lists, by TMDb id, which a watch is logged against
    private var listedCopies: [Int64: CDMovie] {
        var copies: [Int64: CDMovie] = [:]
        for list in movieLists {
            for movie in list.movies where copies[Int64(movie.tmdb_id)] == nil {
                copies[Int64(movie.tmdb_id)] = movie
            }
        }
        return copies
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        content(listed: listedCopies)
                    }
                    .padding(16)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for the film you saw")
            .onSubmit(of: .search, search)
            // Searches shortly after typing stops
            .task(id: trimmedQuery) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled { search() }
            }
            .navigationTitle("Theatre Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't log the watch", isPresented: $logFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
            }
            .sheet(item: $adding) { movie in
                ListPickerSheet(title: movie.title, posterPath: movie.poster_path,
                                isAlreadyIn: { list in list.movies.contains { Int64($0.tmdb_id) == movie.id } }) { lists in
                    add(movie, to: lists)
                }
                .environmentObject(authViewModel)
                .environment(\.managedObjectContext, context)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $details) { preview in
                // Add to Lists closes the info screen and asks which lists
                MovieDetailView(movie: preview, onAddToLists: {
                    let film = (nowPlaying + searchResults).first { $0.id == Int64(preview.tmdb_id) }
                    details = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { adding = film }
                })
            }
        }
        .onAppear {
            if nowPlaying.isEmpty {
                AppAnalytics.log(.theatreCheckInOpened)
                load()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What did you see?")
                .font(.title2.weight(.bold))
                .foregroundColor(Theme.textPrimary)
            Label("At \(theatre)", systemImage: "ticket")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentGradient)
                .lineLimit(2)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func content(listed: [Int64: CDMovie]) -> some View {
        if trimmedQuery.isEmpty {
            if isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.accent)
                    Text("Finding what's in theatres…")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if loadFailed {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load what's showing",
                               message: "Check your connection and try again, or search for the film you saw.",
                               actionTitle: "Try Again", action: load)
                    .padding(.top, 20)
            } else if nowPlaying.isEmpty {
                EmptyStateView(icon: "popcorn", title: "Nothing listed right now",
                               message: "Search for the film you saw to add it to a list.")
                    .padding(.top, 20)
            } else {
                Text("In theatres now. Not listed? Search for it above.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                rows(nowPlaying, listed: listed)
            }
        } else {
            if !showingMatches.isEmpty {
                sectionTitle("IN THEATRES")
                rows(showingMatches, listed: listed)
            }
            if !otherMatches.isEmpty {
                sectionTitle(showingMatches.isEmpty ? "FILMS" : "OTHER FILMS")
                    .padding(.top, showingMatches.isEmpty ? 0 : 8)
                rows(otherMatches, listed: listed)
            }
            if searching && otherMatches.isEmpty {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if showingMatches.isEmpty && otherMatches.isEmpty {
                Text("No films found.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.heavy))
            .tracking(2)
            .foregroundStyle(Theme.accentGradient)
    }

    private func rows(_ movies: [Movie], listed: [Int64: CDMovie]) -> some View {
        ForEach(Array(movies.enumerated()), id: \.element.id) { index, movie in
            row(movie, listedCopy: listed[movie.id])
                .appearAnimation(delay: Double(min(index, 8)) * 0.04)
        }
    }

    private func row(_ movie: Movie, listedCopy: CDMovie?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(path: movie.poster_path, cornerRadius: 10, size: .small)
                .frame(width: 58, height: 87)
            VStack(alignment: .leading, spacing: 6) {
                Text(movie.title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if movie.isTV {
                        TVBadge()
                    }
                    Text(Theme.year(from: movie.release_date))
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
                HStack(spacing: 8) {
                    AddToListsButton(added: added.contains(movie.id)) { adding = movie }
                    // A watch is logged against the copy in the user's lists, so this shows once the film is in one
                    if let listedCopy {
                        watchedButton(movie, copy: listedCopy)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardStyle(cornerRadius: 18)
        // Tapping anywhere but the buttons opens the film's info
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            details = PersistenceController.preview(of: movie)
        }
        .accessibilityAction(named: "Show Details") { details = PersistenceController.preview(of: movie) }
    }

    private func watchedButton(_ movie: Movie, copy: CDMovie) -> some View {
        let done = logged.contains(movie.id)
        let saving = logging.contains(movie.id)
        return Button {
            Haptics.tap()
            logWatch(movie, copy: copy)
        } label: {
            HStack(spacing: 6) {
                if saving {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.onAccent)
                } else {
                    Image(systemName: done ? "checkmark" : "eye")
                }
                // A film already watched gets a rewatch logged, which is what seeing it again is
                Text(done ? "Logged Today" : copy.watched ? "Log Rewatch" : "Mark as Watched")
            }
            .font(.caption.weight(.bold))
            .foregroundColor(done ? Theme.textSecondary : Theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(done ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(Theme.accentGradient), in: Capsule())
        }
        .buttonStyle(.borderless)
        .disabled(done || saving)
    }

    private func load() {
        isLoading = true
        loadFailed = false
        APIService.shared.fetchNowPlaying(region: Locale.current.region?.identifier ?? "US") { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let movies):
                    withAnimation(Theme.spring) { nowPlaying = movies }
                case .failure(let error):
                    print("Error loading films in theatres:", error.localizedDescription)
                    loadFailed = true
                }
            }
        }
    }

    private func search() {
        let typed = trimmedQuery
        guard !typed.isEmpty else {
            searchResults = []
            searching = false
            return
        }
        searching = true
        APIService.shared.searchMovies(name: typed) { result in
            DispatchQueue.main.async {
                guard typed == trimmedQuery else { return }
                searching = false
                if case .success(let found) = result {
                    searchResults = found
                }
            }
        }
    }

    // Shows as added straight away; if every list fails to save it, the button comes back
    private func add(_ movie: Movie, to lists: [CDMovieList]) {
        guard !lists.isEmpty else { return }
        added.insert(movie.id)
        AppAnalytics.log(.filmAdded(.checkIn))
        var saved = 0
        let group = DispatchGroup()
        for list in lists {
            group.enter()
            list.addMovie(movie, context: context) { copy in
                if copy != nil { saved += 1 }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if saved == 0 {
                added.remove(movie.id)
            }
        }
    }

    /// Logs a watch today, which puts it in the diary. The first watch marks the film watched in every list
    /// it's in, as the diary does
    private func logWatch(_ movie: Movie, copy: CDMovie) {
        logging.insert(movie.id)
        let movieID = copy.id
        APIService.shared.logWatch(movieID: movieID, on: Date()) { result in
            logging.remove(movie.id)
            switch result {
            case .success:
                Haptics.success()
                AppAnalytics.log(.filmWatched(.checkIn))
                logged.insert(movie.id)
                let request = CDMovie.fetchRequest()
                request.predicate = NSPredicate(format: "id == %lld", movieID)
                let copies = (try? context.fetch(request)) ?? [copy]
                copies.forEach { $0.watched = true }
                do {
                    try context.save()
                } catch {
                    print("Error saving watched status:", error)
                }
            case .failure(let error):
                print("Error logging watch:", error.localizedDescription)
                logFailed = true
            }
        }
    }
}
