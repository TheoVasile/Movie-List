//
//  SetRankView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-12.
//

import Foundation
import SwiftUI

struct SetRankView : View {
    @State var rank: Int = 0
    @Binding var movie: CDMovie
    var onRankingUpdate: (CDMovie, Int) -> Void
    
    let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }()
    
    init(movie: Binding<CDMovie>, onRankingUpdate: @escaping (CDMovie, Int) -> Void) {
        _movie = movie
        self.onRankingUpdate = onRankingUpdate
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
                    TextField("rank", value: $rank, formatter: formatter)
                        .frame(width: 100, height: 25)
                        .background(Color.black.opacity(0.1))
                        .cornerRadius(10)
                        .padding(.horizontal)
                        .padding(.bottom)
                        .disableAutocorrection(true)
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
        SetRankView(movie: .constant(CDMovie.example)) { movie, rank in
            print(rank)
        }
    }
}
