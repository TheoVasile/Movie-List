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
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    showSetRank = false
                }
            ZStack{
                Color(.white)
                VStack {
                    Text("Select Rank")
                        .padding()
                    TextField("rank", value: $rank, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .frame(width: 100, height: 25)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .padding(.bottom)
                        .disableAutocorrection(true)
                        .onChange(of: rank) { newValue in
                            rank = min(max(newValue, 1), movieCount)
                                                }
                    Button("Set Rank") {
                        onRankingUpdate(movie, rank)
                    }
                }
            }
            .frame(height: 200)
            .cornerRadius(20)
            .padding()
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
