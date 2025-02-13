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
    var movieCount: Int
    var onRankingUpdate: (CDMovie, Int) -> Void
    
    init(movie: Binding<CDMovie>, movieCount: Int, onRankingUpdate: @escaping (CDMovie, Int) -> Void) {
        _movie = movie
        self.onRankingUpdate = onRankingUpdate
        self.movieCount = movieCount
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
            ZStack{
                Color(.white)
                VStack {
                    Text("Select Rank")
                        .padding()
                    TextField("rank", value: $rank, formatter: NumberFormatter())
                        .keyboardType(.numberPad)
                        .frame(width: 100, height: 25)
                        .background(Color.black.opacity(0.1))
                        .cornerRadius(10)
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
        SetRankView(movie: .constant(CDMovie.example), movieCount: 5) { movie, rank in
            print(rank)
        }
    }
}
