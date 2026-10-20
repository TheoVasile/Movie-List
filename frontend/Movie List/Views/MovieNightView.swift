//
//  MovieNightView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import SwiftUI
import CoreData

/// Films the user and a friend would both enjoy, each saying why it suits them both, that can be added
/// straight to the user's lists. AI Picks come from Claude reading both people's lists, and are only
/// offered when both of them allow AI; Classic picks come from TMDb's recommendations for both people's
/// favourites, plus films on both their watchlists
struct MovieNightView: View {
    let person: UserSummary
    // Whether both people allow AI features, which AI Picks need
    let canUseAI: Bool

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authViewModel: AuthenticationViewModel

    @State private var usesAI: Bool
    @State private var picks: [Movie] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    // The film waiting for the user to choose lists, and the films already added
    @State private var adding: Movie? = nil
    @State private var added: Set<Int64> = []

    init(person: UserSummary, canUseAI: Bool) {
        self.person = person
        self.canUseAI = canUseAI
        _usesAI = State(initialValue: canUseAI)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourcePicker
            ZStack {
                Theme.background.ignoresSafeArea()
                if isLoading {
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("Finding films you'll both enjoy…")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    }
                } else if let errorMessage {
                    EmptyStateView(icon: "ticket", title: "Couldn't plan a movie night", message: errorMessage,
                                   actionTitle: "Try Again", action: load)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(usesAI
                                 ? "Picked by Claude from your lists and \(person.display_name)'s. None of these are in either of your lists yet."
                                 : "Recommended by TMDb from your favourites and \(person.display_name)'s, plus anything on both your watchlists.")
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                            ForEach(Array(picks.enumerated()), id: \.element.id) { index, movie in
                                pickRow(movie)
                                    .appearAnimation(delay: Double(min(index, 8)) * 0.05)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Movie Night with \(person.display_name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        load()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .sheet(item: $adding) { movie in
                ListPickerSheet(title: movie.title, posterPath: movie.poster_path) { lists in
                    add(movie, to: lists)
                }
                .environmentObject(authViewModel)
                .environment(\.managedObjectContext, context)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            if picks.isEmpty { load() }
        }
    }

    private func pickRow(_ movie: Movie) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(path: movie.poster_path, cornerRadius: 10, size: .small)
                .frame(width: 70, height: 105)
            VStack(alignment: .leading, spacing: 6) {
                Text(movie.title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Text(Theme.year(from: movie.release_date))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                if let reason = movie.reason {
                    Label(reason, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Haptics.tap()
                    adding = movie
                } label: {
                    Label(added.contains(movie.id) ? "Added" : "Add to Lists",
                          systemImage: added.contains(movie.id) ? "checkmark" : "plus")
                        .font(.caption.weight(.bold))
                        .foregroundColor(added.contains(movie.id) ? Theme.textSecondary : Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(added.contains(movie.id) ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(Theme.accentGradient),
                                    in: Capsule())
                }
                .disabled(added.contains(movie.id))
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardStyle(cornerRadius: 18)
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        APIService.shared.movieNight(with: person.handle, usesAI: usesAI && canUseAI) { result in
            isLoading = false
            switch result {
            case .success(let movies):
                picks = movies
                if movies.isEmpty {
                    errorMessage = usesAI
                        ? "The AI didn't find anything new for you both this time."
                        : "Not enough to go on yet. Movie Night works best when you've both ranked a few films."
                }
            case .failure(let error):
                switch (error as NSError).code {
                case 403: errorMessage = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                    ?? "You both need to allow AI features to plan a movie night."
                case 429: errorMessage = "You've used today's AI picks. Try again tomorrow."
                case 503: errorMessage = "AI picks aren't available right now."
                default: errorMessage = "Something went wrong. Check your connection and try again."
                }
            }
        }
    }

    // AI Picks or Classic, like Discover. AI Picks only when both people allow AI
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Recommendations", selection: $usesAI) {
                Text("AI Picks").tag(true)
                Text("Classic").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!canUseAI || isLoading)
            .onChange(of: usesAI) { _ in load() }
            if !canUseAI {
                Text("AI Picks need you and \(person.display_name) to both allow AI features in Settings.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func add(_ movie: Movie, to lists: [CDMovieList]) {
        guard !lists.isEmpty else { return }
        added.insert(movie.id)
        for list in lists {
            list.addMovie(movie, context: context) { saved in
                if saved == nil {
                    added.remove(movie.id)
                }
            }
        }
    }
}
