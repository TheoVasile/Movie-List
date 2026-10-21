//
//  MovieNightPoll.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-20.
//

import Foundation
import SwiftUI

/// A group's movie night vote between the films it liked: everyone picks one while it's open, then the winner.
/// Shows how many votes each film has as they come in
struct PollCard: View {
    let groupID: Int64
    @Binding var poll: GroupPoll
    // Adds the winner to the user's lists
    var onAddWinner: (Movie) -> Void = { _ in }
    // Starts a new vote
    var onNewVote: () -> Void = {}

    // The film whose vote is being saved
    @State private var saving: Int64? = nil
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if poll.closed, let winner = poll.winner {
                winnerRow(winner)
            }
            ForEach(poll.options.filter { !poll.closed || $0.tmdb_id != poll.winner_tmdb_id }) { option in
                optionRow(option)
            }
            HStack {
                Text(poll.closed
                     ? "\(poll.voters) of \(poll.people) voted"
                     : "\(poll.voters) of \(poll.people) have voted. It closes once everyone has.")
                    .font(.caption)
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                if poll.closed {
                    Button("New Vote", action: onNewVote)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accentGradient)
                }
            }
        }
        .padding(16)
        .cardStyle(cornerRadius: 20)
        .alert("Couldn't save your vote", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The vote may have closed. Check your connection and try again.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(poll.closed ? "THE VOTE IS IN" : "VOTE", systemImage: poll.closed ? "party.popper.fill" : "checkmark.seal.fill")
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Theme.accentGradient)
            if !poll.closed {
                Text(poll.started_by_me ? "Your vote is open. Pick one too!" : "\(poll.created_by_name ?? "Someone") wants to pick tonight's film. Pick one!")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                if let closesAt = poll.closesAt {
                    Text("Closes \(closesAt, style: .relative) from now")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    private func winnerRow(_ winner: PollOption) -> some View {
        HStack(spacing: 14) {
            PosterImage(path: winner.poster_path, cornerRadius: 10, size: .small)
                .frame(width: 70, height: 105)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tonight's film")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                Text(winner.title)
                    .font(.title3.weight(.bold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                tally(winner)
                Button {
                    Haptics.tap()
                    onAddWinner(winner.movie)
                } label: {
                    Label("Add to Lists", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accentGradient, in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func optionRow(_ option: PollOption) -> some View {
        HStack(spacing: 12) {
            PosterImage(path: option.poster_path, cornerRadius: 8, size: .small)
                .frame(width: 44, height: 66)
            VStack(alignment: .leading, spacing: 4) {
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                if let year = option.release_date.map(Theme.year(from:)), !year.isEmpty {
                    Text(year)
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
                tally(option)
            }
            Spacer(minLength: 0)
            if !poll.closed {
                if saving == option.tmdb_id {
                    ProgressView()
                        .frame(width: 44)
                } else {
                    voteButton(option)
                }
            }
        }
    }

    private func tally(_ option: PollOption) -> some View {
        Label("\(option.up) \(option.up == 1 ? "vote" : "votes")", systemImage: "checkmark.circle")
            .font(.caption.weight(.semibold))
            .foregroundColor(Theme.textTertiary)
    }

    // One vote each: choosing a film moves the user's vote to it, and tapping it again takes it back
    private func voteButton(_ option: PollOption) -> some View {
        let chosen = option.my_vote == 1
        return Button {
            Haptics.select()
            cast(option, chosen ? 0 : 1)
        } label: {
            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                .font(.title2.weight(.semibold))
                .foregroundStyle(chosen ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .accessibilityLabel(chosen ? "Your vote: \(option.title)" : "Vote for \(option.title)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func cast(_ option: PollOption, _ value: Int) {
        saving = option.tmdb_id
        APIService.shared.vote(groupID: groupID, pollID: poll.id, tmdbID: option.tmdb_id, vote: value) { result in
            saving = nil
            switch result {
            case .success(let updated):
                withAnimation(Theme.spring) { poll = updated }
                if updated.closed { Haptics.success() }
            case .failure:
                failed = true
                // Shows the poll as it really is, e.g. closed
                APIService.shared.fetchPoll(groupID: groupID) { result in
                    if case .success(let current?) = result { poll = current }
                }
            }
        }
    }
}

/// How long a vote stays open
enum PollLength: Int, CaseIterable, Identifiable {
    case oneHour = 1, threeHours = 3, twelveHours = 12, day = 24

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneHour: return "1 hour"
        case .threeHours: return "3 hours"
        case .twelveHours: return "12 hours"
        case .day: return "1 day"
        }
    }
}
