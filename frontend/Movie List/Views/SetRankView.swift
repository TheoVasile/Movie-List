//
//  SetRankView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-12.
//

import Foundation
import SwiftUI

struct SetRankView : View {
    @State var rank: Int = 1
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
                    PosterImage(path: movie.poster_path, cornerRadius: 10)
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
                Picker("Rank", selection: $rank) {
                    ForEach(1...max(movieCount, 1), id: \.self) { value in
                        Text("#\(value)")
                            .font(.title3.weight(.bold))
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 140)
                .onChange(of: rank) { _ in Haptics.tap() }
                HStack(spacing: 12) {
                    Button("Cancel") {
                        withAnimation(Theme.spring) { showSetRank = false }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Set Rank") {
                        Haptics.success()
                        onRankingUpdate(movie, rank)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(22)
            .cardStyle(cornerRadius: 28)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.horizontal, 20)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .onAppear {
            rank = min(max(Int(movie.rank), 1), max(movieCount, 1))
        }
    }
}

struct SetRankView_Previews: PreviewProvider {
    static var previews: some View {
        SetRankView(movie: .constant(CDMovie.example), movieCount: 5, showSetRank: .constant(true)) { movie, rank in
            print(rank)
        }
    }
}
