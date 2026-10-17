//
//  SetRankView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-12.
//

import Foundation
import SwiftUI

struct SetRankView : View {
    @State private var rankText = ""
    @FocusState private var fieldFocused: Bool
    @Binding var movie: CDMovie
    @Binding var showSetRank: Bool
    var movieCount: Int
    var onRankingUpdate: (CDMovie, Int) -> Void
    
    init(movie: Binding<CDMovie>, movieCount: Int, showSetRank: Binding<Bool>, onRankingUpdate: @escaping (CDMovie, Int) -> Void) {
        _movie = movie
        self.onRankingUpdate = onRankingUpdate
        self.movieCount = movieCount
        _showSetRank = showSetRank
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(Theme.spring) { showSetRank = false }
                }
                .transition(.opacity)
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    PosterImage(path: movie.poster_path, cornerRadius: 10, size: .small)
                        .frame(width: 54, height: 81)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SET RANK")
                            .font(.caption.weight(.heavy))
                            .tracking(2)
                            .foregroundStyle(Theme.accentGradient)
                        Text(movie.title ?? "")
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Text("Currently #\(movie.rank)")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("#")
                            .foregroundStyle(Theme.accentGradient)
                        TextField("\(movie.rank)", text: $rankText)
                            .keyboardType(.numberPad)
                            .focused($fieldFocused)
                            .multilineTextAlignment(.center)
                            .fixedSize()
                            .onChange(of: rankText) { text in
                                // Digits only, and never longer than the largest rank
                                let digits = String(text.filter(\.isNumber).prefix(String(maxRank).count))
                                if digits != text { rankText = digits }
                            }
                    }
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .frame(minWidth: 140)
                    .background(Theme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isOutOfRange ? Theme.accentSecondary : Theme.accent.opacity(fieldFocused ? 0.6 : 0), lineWidth: 1.5)
                    )
                    .onTapGesture { fieldFocused = true }
                    Text(isOutOfRange ? "Enter a number from 1 to \(maxRank)" : "Any rank from 1 to \(maxRank)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(isOutOfRange ? Theme.accentSecondary : Theme.textSecondary)
                        .animation(.easeOut(duration: 0.2), value: isOutOfRange)
                }
                HStack(spacing: 12) {
                    Button("Cancel") {
                        withAnimation(Theme.spring) { showSetRank = false }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Set Rank") {
                        guard let enteredRank else { return }
                        Haptics.success()
                        fieldFocused = false
                        onRankingUpdate(movie, enteredRank)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(enteredRank == nil)
                    .opacity(enteredRank == nil ? 0.5 : 1)
                }
            }
            .padding(22)
            .cardStyle(cornerRadius: 28)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.horizontal, 20)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .onAppear {
            // Wait for the card's appear animation so the keyboard doesn't jump in underneath it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fieldFocused = true }
        }
    }

    private var maxRank: Int { max(movieCount, 1) }

    // The typed rank, or nil if the field is empty or outside 1...maxRank
    private var enteredRank: Int? {
        guard let rank = Int(rankText), (1...maxRank).contains(rank) else { return nil }
        return rank
    }

    private var isOutOfRange: Bool {
        !rankText.isEmpty && enteredRank == nil
    }
}

struct SetRankView_Previews: PreviewProvider {
    static var previews: some View {
        SetRankView(movie: .constant(CDMovie.example), movieCount: 5, showSetRank: .constant(true)) { movie, rank in
            print(rank)
        }
    }
}
