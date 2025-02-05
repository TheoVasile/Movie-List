//
//  CompareMovieView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

struct CompareMovieView: View {
    @EnvironmentObject var network: NetworkService
    
    @State var movies: [CDMovie] = []
    @State private var selection: [CDMovie] = []
    @Binding var movieList: CDMovieList
    @State var i: Int = 2
    
    var body : some View {
        VStack{
            Spacer()
            Text("Select which movie you prefer")
                .fontWeight(.bold)
                .padding(.top, 150)
                .padding(.bottom, 50)
            HStack{
                if selection.count == 2 {
                    MovieCard(movie: selection[0])
                        .onTapGesture {makeHigher(index: 0)}
                    MovieCard(movie: selection[1])
                        .onTapGesture{makeHigher(index: 1)}
                } else{
                    Text("Need at least 2 movies to compare")
                }
            }
            .padding(.bottom, 100)
            .onAppear {
                movies = Array(movieList.movies).shuffled()
                if movies.count >= 2 {
                    selection.append(movies[0])
                    selection.append(movies[1])
                }
            }
        }
    }
    
    private func makeHigher(index: Int) {
        if selection[index].rank < selection[1-index].rank {
            (selection[index].rank, selection[1-index].rank) = (selection[1-index].rank, selection[index].rank)
        }
        for j in 0..<2 {
            if i >= movies.count{
                i = 0
            }
            print(i, movies.count)
            selection[j] = movies[i]
            i += 1
        }
    }
}

struct CompareMovieView_Previews: PreviewProvider{
    static var previews: some View {
        CompareMovieView(movieList: .constant(CDMovieList.example))
            .environmentObject(NetworkService()) // Keep if needed
    }
}

