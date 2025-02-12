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
    
    @Binding var movies: [CDMovie]
    @Binding var movie: CDMovie
    @State var left: Int = 0
    @State var right: Int = 0
    @State var middle: Int = 0
    var onRankingUpdate: (CDMovie, Int) -> Void
    
    init(movies: Binding<[CDMovie]>, movie: Binding<CDMovie>, onRankingUpdate: @escaping (CDMovie, Int) -> Void) {
            self._movies = movies
            self._movie = movie
            self.onRankingUpdate = onRankingUpdate
        }
    
    var body : some View {
        ZStack{
            Color(.white)
            VStack{
                Spacer()
                Text("Select which movie you prefer")
                    .fontWeight(.bold)
                    .padding(.top, 150)
                    .padding(.bottom, 50)
                HStack{
                    if movies.count > 1 {
                        MovieCard(movie: $movie)
                            .onTapGesture {
                                right = middle - 1
                                if right == movie.rank - 1 {
                                    right -= 1
                                }
                                updateMiddle()
                            }
                        if middle < movies.count {
                            MovieCard(movie: $movies[middle])
                                .onTapGesture {
                                    left = middle + 1
                                    if left == movie.rank - 1 {
                                        left += 1
                                    }
                                    updateMiddle()
                                }
                        }
                    } else{
                        Text("Need at least 2 movies to compare")
                    }
                }
                .padding(.bottom, 100)
            }
            .onAppear {
                right = movies.count - 1
                updateMiddle()
            }
        }
        .cornerRadius(20)
        .padding()
        .background(Color.black.opacity(0.15))
    }
    private func updateMiddle() {
        middle = (left+right)/2
        if left >= right {
            movie.rank = Int32(left+1)
            onRankingUpdate(movie, Int(left+1))
        }
    }
}

struct CompareMovieView_Previews: PreviewProvider{
    static var previews: some View {
        CompareMovieView(movies: .constant(Array(CDMovieList.example.movies)), movie: .constant(Array(CDMovieList.example.movies)[0])) { updatedMovie, rank in
            print(updatedMovie)
            
        }
            .environmentObject(NetworkService()) // Keep if needed
    }
}

