//
//  MovieRow.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-05-04.
//

import Foundation
import SwiftUI

struct MovieRow: View {
    @ObservedObject var movie: CDMovie
    @Binding var showCompareMovieView: Bool
    @Binding var selectedMovie: CDMovie?
    @Binding var showSetRank: Bool
    var info: MovieInfo? = nil
    // Placed by the AI rather than by hand, shown as a faint mark on the rank
    var aiPlaced = false
    // On shared lists, who added it when it wasn't the user
    var addedBy: String? = nil
    // Unranked lists show no rank and offer no ranking actions
    var ranked = true
    var onAddToLists: (() -> Void)? = nil
    var onToggleWatched: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 14) {
            PosterImage(path: movie.poster_path, cornerRadius: 10, size: .small)
                .frame(width: 58, height: 87)
                .shadow(color: Theme.shadow.opacity(0.4), radius: 6, y: 3)
                // Rank sits on the poster's top-left corner, overhanging it slightly
                .overlay(alignment: .topLeading) { if ranked { rankBadge.offset(x: -8, y: -8) } }
                .overlay(alignment: .bottomTrailing) {
                    if aiPlaced {
                        // A quiet reminder, not a badge: the spot was suggested, not chosen
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .padding(3)
                            .background(Theme.surface.opacity(0.85), in: Circle())
                            .offset(x: 4, y: 4)
                            .accessibilityLabel("Placed by AI")
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(movie.title ?? "No title")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if movie.isTV {
                        TVBadge()
                    }
                    Text(Theme.year(from: movie.release_date))
                        .fixedSize()
                    if !movie.original_language.isNilOrEmpty {
                        Text("·")
                        Text((movie.original_language ?? "").uppercased())
                    }
                    if let info, !info.certification.isEmpty {
                        CertificationBadge(certification: info.certification)
                    }
                }
                .lineLimit(1)
                .font(.caption.weight(.medium))
                .foregroundColor(Theme.textSecondary)
                if let addedBy {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                        Text("Added by \(addedBy)")
                    }
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
                if movie.watched {
                    WatchedTag()
                        .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
            }
            Spacer(minLength: 0)
            if let info, info.voteCount > 0 {
                UserScoreLabel(score: info.voteAverage)
                    .font(.subheadline.weight(.bold))
            }
            Menu {
                if ranked {
                    Button {
                        present { showSetRank = true }
                    } label: {
                        Label("Set Rank", systemImage: "number")
                    }
                    Button {
                        present { showCompareMovieView = true }
                    } label: {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                    }
                }
                if let onAddToLists {
                    Button {
                        Haptics.tap()
                        onAddToLists()
                    } label: {
                        Label("Add to Other Lists", systemImage: "text.badge.plus")
                    }
                }
                if let onToggleWatched {
                    Button {
                        Haptics.tap()
                        onToggleWatched()
                    } label: {
                        Label(movie.watched ? "Mark as Unwatched" : "Mark as Watched",
                              systemImage: movie.watched ? "eye.slash" : "eye")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .rotationEffect(.degrees(90)) // Makes it vertical like ⋮
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(12)
        .background(
            ZStack {
                Theme.surface
                if ranked && movie.rank == 1 {
                    Theme.accentGradient.opacity(0.12)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(movie.rank == 1 ? Theme.accent.opacity(0.35) : Theme.stroke, lineWidth: 1)
        )
    }

    private var rankBadge: some View {
        Text("\(movie.rank)")
            .font(.system(size: 12, weight: .black, design: .rounded))
            .monospacedDigit()
            .foregroundColor(movie.rank <= 3 ? Theme.onAccent : Theme.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
            .animation(Theme.spring, value: movie.rank)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                Capsule().fill(movie.rank <= 3 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface))
            )
            .overlay(Capsule().stroke(movie.rank <= 3 ? Color.clear : Theme.stroke, lineWidth: 1))
            .shadow(color: Theme.shadow.opacity(0.4), radius: 4, y: 2)
            .accessibilityLabel("Ranked \(movie.rank)")
    }

    private func present(_ change: () -> Void) {
        Haptics.tap()
        selectedMovie = movie
        withAnimation(Theme.spring, change)
    }
}

/// Small "Watched" badge shown under a film's details
struct WatchedTag: View {
    var body: some View {
        Label("Watched", systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.bold))
            .foregroundColor(Theme.onAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accentGradient)
            .clipShape(Capsule())
            .accessibilityLabel("Watched")
    }
}

/// A film's US age rating ("PG-13", "R", ...), outlined like the rating box on a poster
struct CertificationBadge: View {
    let certification: String

    var body: some View {
        Text(certification)
            .font(.caption2.weight(.heavy))
            .foregroundColor(Theme.textPrimary.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Theme.textPrimary.opacity(0.5), lineWidth: 1)
            )
            .fixedSize()
            .accessibilityLabel("Rated \(certification)")
    }
}

/// TMDb's average user score out of 10, e.g. "★ 7.4"
struct UserScoreLabel: View {
    let score: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .imageScale(.small)
            Text(String(format: "%.1f", score))
                .monospacedDigit()
        }
        .foregroundColor(Theme.accent)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TMDb user score \(String(format: "%.1f", score)) out of 10")
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

#Preview {
    MovieRow(movie: CDMovie.example, showCompareMovieView: .constant(false), selectedMovie: .constant(nil), showSetRank: .constant(false))
}
